---------------------------------------------------------------------------
-- Split the space equally between multiple widgets.
--
--
-- A `flex` layout may be initialized with any number of child widgets, and
-- during runtime widgets may be added and removed dynamically.
--
-- On the main axis, the layout will divide the available space evenly between
-- all child widgets, without any regard to how much space these widgets might
-- be asking for.
--
-- Just like @{wibox.layout.fixed}, `flex` allows adding spacing between the
-- widgets, either as an ofset via @{spacing} or with a
-- @{spacing_widget}.
--
-- On its secondary axis, the layout's size is determined by the largest child
-- widget. Smaller child widgets are then placed with the same size.
-- Therefore, child widgets may ignore their `forced_width` or `forced_height`
-- properties for vertical and horizontal layouts respectively.
--
--@DOC_wibox_layout_defaults_flex_EXAMPLE@
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @layoutmod wibox.layout.flex
-- @supermodule wibox.layout.fixed
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local fixed = require("wibox.layout.fixed")
local pairs = pairs
local gtable = require("gears.table")
local layout = require("somewm.layout")

local flex = {}

-- {{{ Override inherited properties we want to hide

--- From `wibox.layout.fixed`.
-- @property fill_space
-- @tparam[opt=true] boolean fill_space
-- @propemits true false
-- @hidden

-- }}}

--- Add some widgets to the given fixed layout.
--
-- @tparam widget ... Widgets that should be added (must at least be one).
-- @method add
-- @noreturn
-- @interface layout

--- Remove a widget from the layout.
--
-- @tparam number index The widget index to remove.
-- @treturn boolean index If the operation is successful.
-- @method remove
-- @interface layout

--- Remove one or more widgets from the layout.
--
-- The last parameter can be a boolean, forcing a recursive seach of the
-- widget(s) to remove.
--
-- @tparam widget ... Widgets that should be removed (must at least be one).
-- @treturn boolean If the operation is successful.
-- @method remove_widgets
-- @interface layout

--- Insert a new widget in the layout at position `index`.
--
-- @tparam number index The position
-- @tparam widget widget The widget
-- @treturn boolean If the operation is successful
-- @method insert
-- @emits widget::inserted
-- @emitstparam widget::inserted widget self The layout.
-- @emitstparam widget::inserted widget widget The inserted widget.
-- @emitstparam widget::inserted number count The widget count.
-- @interface layout

--- A widget to insert as a separator between child widgets.
--
-- If this property is a valid widget and @{spacing} is greater than `0`, a
-- copy of this widget is inserted between each child widget, with its size in
-- the layout's main direction determined by @{spacing}.
--
-- By default no widget is used and any @{spacing} is applied as an empty offset.
--
--@DOC_wibox_layout_flex_spacing_widget_EXAMPLE@
--
-- @property spacing_widget
-- @tparam[opt=nil] widget|nil spacing_widget
-- @propemits true false
-- @interface layout

--- The amount of space inserted between the child widgets.
--
-- If a @{spacing_widget} is defined, this value is used for its size.
--
--@DOC_wibox_layout_flex_spacing_EXAMPLE@
--
-- @property spacing
-- @tparam[opt=0] number spacing Spacing between widgets.
-- @propertyunit pixel
-- @negativeallowed true
-- @propemits true false
-- @interface layout

local function build_tree(self, width, height)
    local is_y          = self._private.dir == "y"
    local spacing       = math.abs(self._private.spacing or 0)
    local max_size      = self._private.max_widget_size
    local spacing_widget = self._private.spacing_widget
    local widgets       = self._private.widgets

    local props = max_size
        and { grow = true, grow_max = max_size }
        or  { grow = true }

    local outer = is_y and layout.column or layout.row

    -- spacing_widget: interleave a fixed-size spacer leaf between every
    -- pair of children so the spacer renders inside the gap. Container
    -- gap stays 0 because the spacer IS the gap. Without spacing_widget
    -- the simpler `gap = spacing` path runs; Clay distributes the gap
    -- with no extra leaves.
    local children
    if spacing_widget and spacing > 0 then
        children = {}
        local spacer_props = is_y and { height = spacing } or { width = spacing }
        for i, w in ipairs(widgets) do
            if i > 1 then
                children[#children + 1] = layout.widget(spacing_widget, spacer_props)
            end
            children[#children + 1] = layout.widget(w, props)
        end
        return base.place_rects(layout.solve {
            source = "wibox",
            width = width, height = height,
            root = outer { children },
        }.placements)
    end

    return base.place_rects(layout.solve {
        source = "wibox",
        width = width, height = height,
        root = outer {
            gap = spacing,
            layout.widgets(widgets, props),
        },
    }.placements)
end

function flex:layout(_, width, height)
    return build_tree(self, width, height)
end

-- Fit the flex layout into the given space.
-- @param context The context in which we are fit.
-- @param orig_width The available width.
-- @param orig_height The available height.
function flex:fit(context, orig_width, orig_height)
    local used_in_dir = 0
    local used_in_other = 0

    -- Figure out the maximum size we can give out to sub-widgets
    local sub_height = self._private.dir == "x" and orig_height or orig_height / #self._private.widgets
    local sub_width  = self._private.dir == "y" and orig_width  or orig_width / #self._private.widgets

    for _, v in pairs(self._private.widgets) do
        local w, h = base.fit_widget(self, context, v, sub_width, sub_height)

        local max = self._private.dir == "y" and w or h
        if max > used_in_other then
            used_in_other = max
        end

        used_in_dir = used_in_dir + (self._private.dir == "y" and h or w)
    end

    if self._private.max_widget_size then
        used_in_dir = math.min(used_in_dir,
            #self._private.widgets * self._private.max_widget_size)
    end

    local spacing = self._private.spacing * (#self._private.widgets-1)

    if self._private.dir == "y" then
        return used_in_other, used_in_dir + spacing
    end
    return used_in_dir + spacing, used_in_other
end

--- Set the maximum size the widgets in this layout will take.
--
--That is, maximum width for horizontal and maximum height for vertical.
--
-- @property max_widget_size
-- @tparam[opt=nil] number|nil max_widget_size
-- @propertytype nil No size limit.
-- @negativeallowed false
-- @propemits true false

function flex:set_max_widget_size(val)
    if self._private.max_widget_size ~= val then
        self._private.max_widget_size = val
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::max_widget_size", val)
    end
end

local function get_layout(dir, widget1, ...)
    local ret = fixed[dir](widget1, ...)

    gtable.crush(ret, flex, true)

    ret._private.fill_space = nil

    return ret
end

--- Creates and returns a new horizontal flex layout.
--
-- @tparam widget ... Widgets that should be added to the layout.
-- @constructorfct wibox.layout.flex.horizontal
function flex.horizontal(...)
    return get_layout("horizontal", ...)
end

--- Creates and returns a new vertical flex layout.
--
-- @tparam widget ... Widgets that should be added to the layout.
-- @constructorfct wibox.layout.flex.vertical
function flex.vertical(...)
    return get_layout("vertical", ...)
end

--@DOC_fixed_COMMON@

return flex

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
