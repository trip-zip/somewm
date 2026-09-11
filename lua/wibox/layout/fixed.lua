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

local clay = require("wibox.clay")
local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)
local base  = require("wibox.widget.base")
local table = table
local gtable = require("gears.table")

local fixed = {}


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

--- What wibox.layout.fixed and flex share: a layout direction and a child
-- gap in whole pixels (third_party/clay.h:344). A spacing widget, a widget
-- placed between the children rather than a gap, is not drawn.
-- Returns the node and the axis names along and across the direction.
local function describe_linear(w)
    local p = w._private
    local spacing = clay.pixels(w, "spacing", p.spacing)

    if spacing ~= 0 and p.spacing_widget then
        clay.ignore(w, "spacing_widget", "is not drawn")
    end
    if p.dir == "y" then
        return { dir = "y", gap = spacing, specs = {} }, "h", "w"
    end
    return { dir = "x", gap = spacing, specs = {} }, "w", "h"
end

--- wibox.layout.fixed: every child at its content size along the direction,
-- which is the `:fit` the engine asked it for, and the whole size across.
-- The last child grows along too when `fill_space` is set.
--
-- Clay's childGap is added between every pair of children whatever their
-- size (clay.h:3080-3082), where the engine skipped the spacing of a child
-- whose `:fit` was zero.
local function describe_fixed(w)
    local node, along, across = describe_linear(w)

    local p = w._private

    for i, child in ipairs(p.widgets) do
        local spec = { widget = child, [across] = "grow" }

        if i == #p.widgets and p.fill_space then
            spec[along] = "grow"
        end
        node.specs[i] = spec
    end
    return node
end

fixed.describe_linear = describe_linear

fixed._clay = { describe = describe_fixed }

return fixed

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
