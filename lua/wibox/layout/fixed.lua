---------------------------------------------------------------------------
-- Place many widgets in a column or row, until the available space is used up.
--
-- A `fixed` layout may be initialized with any number of child widgets, and
-- during runtime widgets may be added and removed dynamically.
--
-- On the main axis, child widgets are given a fixed size of exactly as much
-- space as they ask for. The layout will then resize according to the sum of
-- all child widgets. If the space available to the layout is not enough to
-- include all child widgets, the excessive ones are not drawn at all.
--
-- Additionally, the layout allows adding empty spacing or even placing a custom
-- spacing widget between the child widget.
--
-- On its secondary axis, the layout's size is determined by the largest child
-- widget. Smaller child widgets are then placed with the same size.
-- Therefore, child widgets may ignore their `forced_width` or `forced_height`
-- properties for vertical and horizontal layouts respectively.
--
--@DOC_wibox_layout_defaults_fixed_EXAMPLE@
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @layoutmod wibox.layout.fixed
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)
local base  = require("wibox.widget.base")
local table = table
local pairs = pairs
local gtable = require("gears.table")
local layout = require("somewm.layout")

local fixed = {}

local function layout_clay(self, context, width, height)
    local is_y           = self._private.dir == "y"
    local spacing        = self._private.spacing or 0
    local abspace        = math.abs(spacing)
    local widgets        = self._private.widgets
    local fill_space     = self._private.fill_space
    local spacing_widget = self._private.spacing_widget
    local size_key       = is_y and "height" or "width"
    local main_size      = is_y and height or width

    -- Build an explicit child list so spacers can be interleaved between
    -- consecutive children. fill_space gives the last child grow=true so
    -- it absorbs leftover space.
    local children = {}
    local visible  = {}
    for _, widget in pairs(widgets) do
        if not (widget._private and widget._private.visible == false) then
            visible[#visible + 1] = widget
        end
    end

    local interleave = spacing_widget and abspace > 0
    local container_gap = interleave and 0 or abspace
    local spacer_props
    if interleave then
        spacer_props = {}
        spacer_props[size_key] = abspace
    end

    -- Track cumulative main-axis position so each fit_widget call sees
    -- only the remaining space. fit_widget clamps the widget's reported
    -- size to the available area, so widgets that overflow the container
    -- get truncated as they're placed (matching wibox.layout.fixed's
    -- documented overflow semantics). When interleaving spacers, add the
    -- spacer only after confirming the upcoming widget gets non-zero
    -- main-axis size; otherwise the spacer would sit past the container
    -- boundary with a zero-sized widget after it.
    local pos = 0
    for i, widget in ipairs(visible) do
        if fill_space and i == #visible then
            if interleave and i > 1 then
                children[#children + 1] = layout.widget(spacing_widget, spacer_props)
                pos = pos + abspace
            end
            children[#children + 1] = layout.widget(widget, { grow = true })
        else
            local pre_spacer = interleave and i > 1
            local pos_after_spacer = pre_spacer and (pos + abspace) or pos
            local remaining = math.max(0, main_size - pos_after_spacer)
            local fw = is_y and width or remaining
            local fh = is_y and remaining or height
            local w, h = base.fit_widget(self, context, widget, fw, fh)
            local main = is_y and h or w
            if pre_spacer and main > 0 then
                children[#children + 1] = layout.widget(spacing_widget, spacer_props)
                pos = pos + abspace
            end
            children[#children + 1] = layout.widget(widget,
                is_y and { height = main } or { width = main })
            pos = pos + main + (interleave and 0 or container_gap)
        end
    end

    local outer = is_y and layout.column or layout.row
    return base.place_rects(layout.solve {
        source = "wibox",
        width = width, height = height,
        root = outer {
            gap = container_gap,
            children,
        },
    }.placements)
end

-- Build absolute-positioned rects when negative spacing combines with a
-- spacing_widget: the spacer overlaps adjacent widgets, which linear
-- flow can't express. Routes through `place_rects_via_stack` so the
-- result still goes through Clay (just in stack mode).
local function layout_via_absolute(self, context, width, height)
    local rects = {}
    local spacing = self._private.spacing or 0
    local is_y = self._private.dir == "y"
    local is_x = not is_y
    local abspace = math.abs(spacing)
    local spoffset = spacing < 0 and 0 or spacing
    local widgets = self._private.widgets
    local widgets_nr = #widgets
    local fill_space = self._private.fill_space
    local spacing_widget = spacing ~= 0 and self._private.spacing_widget or nil
    local x, y = 0, 0

    for index, widget in pairs(widgets) do
        local w, h = width - x, height - y
        local zero = false

        if is_y then
            if index ~= widgets_nr or not fill_space then
                h = select(2, base.fit_widget(self, context, widget, w, h))
                zero = h == 0
            end
            if y - spacing >= height then
                if spacing_widget then
                    table.remove(rects)
                    y = y - spacing
                end
                if not zero then break end
            end
        else
            if index ~= widgets_nr or not fill_space then
                w = select(1, base.fit_widget(self, context, widget, w, h))
                zero = w == 0
            end
            if x - spacing >= width then
                if spacing_widget then
                    table.remove(rects)
                    x = x - spacing
                end
                if not zero then break end
            end
        end

        local local_spacing = zero and 0 or spacing

        rects[#rects + 1] = {
            widget = widget, x = x, y = y, width = w, height = h,
        }

        x = is_x and x + w + local_spacing or x
        y = is_y and y + h + local_spacing or y

        if index < widgets_nr and spacing_widget then
            rects[#rects + 1] = {
                widget = spacing_widget,
                x = is_x and (x - spoffset) or x,
                y = is_y and (y - spoffset) or y,
                width  = is_x and abspace or w,
                height = is_y and abspace or h,
            }
        end
    end

    return base.place_rects_via_stack(rects, width, height)
end

function fixed:layout(context, width, height)
    -- Negative spacing combined with spacing_widget overlaps adjacent
    -- widgets; linear-flow Clay can't express the overlap, so route via
    -- absolute positioning. All other cases use linear flow.
    if self._private.spacing and self._private.spacing < 0
        and self._private.spacing_widget then
        return layout_via_absolute(self, context, width, height)
    end
    return layout_clay(self, context, width, height)
end

--- Add some widgets to the given layout.
--
-- @method add
-- @tparam widget ... Widgets that should be added (must at least be one).
-- @noreturn
-- @interface layout
function fixed:add(...)
    -- No table.pack in Lua 5.1 :-(
    local args = { n=select('#', ...), ... }
    assert(args.n > 0, "need at least one widget to add")
    for i=1, args.n do
        local w = base.make_widget_from_value(args[i])
        base.check_widget(w)
        table.insert(self._private.widgets, w)
    end
    self:emit_signal("widget::layout_changed")
end


--- Remove a widget from the layout.
--
-- @method remove
-- @tparam number index The widget index to remove
-- @treturn boolean index If the operation is successful
-- @interface layout
function fixed:remove(index)
    if not index or index < 1 or index > #self._private.widgets then return false end

    table.remove(self._private.widgets, index)

    self:emit_signal("widget::layout_changed")

    return true
end

--- Remove one or more widgets from the layout.
--
-- The last parameter can be a boolean, forcing a recursive seach of the
-- widget(s) to remove.
-- @method remove_widgets
-- @tparam widget ... Widgets that should be removed (must at least be one)
-- @treturn boolean If the operation is successful
-- @interface layout
function fixed:remove_widgets(...)
    local args = { ... }

    local recursive = type(args[#args]) == "boolean" and args[#args]

    local ret = true
    for k, rem_widget in ipairs(args) do
        if recursive and k == #args then break end

        local idx, l = self:index(rem_widget, recursive)

        if idx and l and l.remove then
            l:remove(idx, false)
        else
            ret = false
        end

    end

    return #args > (recursive and 1 or 0) and ret
end

function fixed:get_children()
    return self._private.widgets
end

function fixed:set_children(children)
    self:reset()
    if #children > 0 then
        self:add(unpack(children))
    end
end

--- Replace the first instance of `widget` in the layout with `widget2`.
-- @method replace_widget
-- @tparam widget widget The widget to replace
-- @tparam widget widget2 The widget to replace `widget` with
-- @tparam[opt=false] boolean recursive Digg in all compatible layouts to find the widget.
-- @treturn boolean If the operation is successful
-- @interface layout
function fixed:replace_widget(widget, widget2, recursive)
    local idx, l = self:index(widget, recursive)

    if idx and l then
        l:set(idx, widget2)
        return true
    end

    return false
end

function fixed:swap(index1, index2)
    if not index1 or not index2 or index1 > #self._private.widgets
        or index2 > #self._private.widgets then
        return false
    end

    local widget1, widget2 = self._private.widgets[index1], self._private.widgets[index2]

    self:set(index1, widget2)
    self:set(index2, widget1)

    self:emit_signal("widget::swapped", widget1, widget2, index2, index1)

    return true
end

function fixed:swap_widgets(widget1, widget2, recursive)
    base.check_widget(widget1)
    base.check_widget(widget2)

    local idx1, l1 = self:index(widget1, recursive)
    local idx2, l2 = self:index(widget2, recursive)

    if idx1 and l1 and idx2 and l2 and (l1.set or l1.set_widget) and (l2.set or l2.set_widget) then
        if l1.set then
            l1:set(idx1, widget2)
            if l1 == self then
                self:emit_signal("widget::swapped", widget1, widget2, idx2, idx1)
            end
        elseif l1.set_widget then
            l1:set_widget(widget2)
        end
        if l2.set then
            l2:set(idx2, widget1)
            if l2 == self then
                self:emit_signal("widget::swapped", widget1, widget2, idx2, idx1)
            end
        elseif l2.set_widget then
            l2:set_widget(widget1)
        end

        return true
    end

    return false
end

function fixed:set(index, widget2)
    if (not widget2) or (not self._private.widgets[index]) then return false end

    base.check_widget(widget2)

    local w = self._private.widgets[index]

    self._private.widgets[index] = widget2

    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::replaced", widget2, w, index)

    return true
end

--- A widget to insert as a separator between child widgets.
--
-- If this property is a valid widget and `spacing` is greater than `0`, a
-- copy of this widget is inserted between each child widget, with its size in
-- the layout's main direction determined by `spacing`.
--
-- By default no widget is used and any `spacing` is applied as an empty offset.
--
--@DOC_wibox_layout_fixed_spacing_widget_EXAMPLE@
--
-- @property spacing_widget
-- @tparam[opt=nil] widget|nil spacing_widget
-- @propemits true false
-- @interface layout

function fixed:set_spacing_widget(wdg)
    self._private.spacing_widget = base.make_widget_from_value(wdg)
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::spacing_widget", wdg)
end

--- Insert a new widget in the layout at position `index`.
--
-- @method insert
-- @tparam number index The position.
-- @tparam widget widget The widget.
-- @treturn boolean If the operation is successful.
-- @emits widget::inserted
-- @emitstparam widget::inserted widget self The fixed layout.
-- @emitstparam widget::inserted widget widget index The inserted widget.
-- @emitstparam widget::inserted number count The widget count.
-- @interface layout
function fixed:insert(index, widget)
    if not index or index < 1 or index > #self._private.widgets + 1 then return false end

    base.check_widget(widget)
    table.insert(self._private.widgets, index, widget)
    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::inserted", widget, #self._private.widgets)

    return true
end

-- Fit the fixed layout into the given space.
-- @param context The context in which we are fit.
-- @param orig_width The available width.
-- @param orig_height The available height.
function fixed:fit(context, orig_width, orig_height)
    local width_left, height_left = orig_width, orig_height
    local spacing = self._private.spacing or 0
    local widgets_nr = #self._private.widgets
    local is_y = self._private.dir == "y"
    local used_max = 0

    -- when no widgets exist the function can be called with orig_width or
    -- orig_height equal to nil. Exit early in this case.
    if widgets_nr == 0 then
        return 0, 0
    end

    for k, v in pairs(self._private.widgets) do
        local w, h = base.fit_widget(self, context, v, width_left, height_left)
        local max

        if is_y then
            max = w
            height_left = height_left - h
        else
            max = h
            width_left = width_left - w
        end

        if max > used_max then
            used_max = max
        end

        if k < widgets_nr then
            if is_y then
                height_left = height_left - spacing
            else
                width_left = width_left - spacing
            end
        end

        if width_left <= 0 or height_left <= 0 then
            -- this complicated two lines determine whether we're out-of-space
            -- because of spacing, or if the last widget doesn't fit in
            if is_y then
                 height_left = k < widgets_nr and height_left + spacing or height_left
                 height_left = height_left < 0 and 0 or height_left
            else
                 width_left = k < widgets_nr and width_left + spacing or width_left
                 width_left = width_left < 0 and 0 or width_left
            end
            break
        end
    end

    if is_y then
        return used_max, orig_height - height_left
    end

    return orig_width - width_left, used_max
end

function fixed:reset()
    self._private.widgets = {}
    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::reseted")
    self:emit_signal("widget::reset")
end

--- Set the layout's fill_space property. If this property is true, the last
-- widget will get all the space that is left. If this is false, the last widget
-- won't be handled specially and there can be space left unused.
-- @property fill_space
-- @tparam[opt=false] boolean fill_space
-- @propemits true false

function fixed:fill_space(val)
    if self._private.fill_space ~= val then
        self._private.fill_space = not not val
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::fill_space", val)
    end
end

local function get_layout(dir, widget1, ...)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, fixed, true)

    ret._private.dir = dir
    ret._private.widgets = {}
    ret:set_spacing(0)
    ret:fill_space(false)

    if widget1 then
        ret:add(widget1, ...)
    end

    return ret
end

--- Creates and returns a new horizontal fixed layout.
--
-- @tparam widget ... Widgets that should be added to the layout.
-- @constructorfct wibox.layout.fixed.horizontal
function fixed.horizontal(...)
    return get_layout("x", ...)
end

--- Creates and returns a new vertical fixed layout.
--
-- @tparam widget ... Widgets that should be added to the layout.
-- @constructorfct wibox.layout.fixed.vertical
function fixed.vertical(...)
    return get_layout("y", ...)
end

--- The amount of space inserted between the child widgets.
--
-- If a `spacing_widget` is defined, this value is used for its size.
--
--@DOC_wibox_layout_fixed_spacing_EXAMPLE@
--
-- @property spacing
-- @tparam[opt=0] number spacing Spacing between widgets.
-- @negativeallowed true
-- @propemits true false
-- @interface layout

function fixed:set_spacing(spacing)
    if self._private.spacing ~= spacing then
        self._private.spacing = spacing
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::spacing", spacing)
    end
end

function fixed:get_spacing()
    return self._private.spacing or 0
end

--@DOC_fixed_COMMON@

return fixed

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
