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

local fixed = require("wibox.layout.fixed")
local gtable = require("gears.table")

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

--- wibox.layout.flex: every child grows along the direction, with
-- `max_widget_size` as the ceiling, and across. Each is offered an equal
-- share of the box less the gaps, the engine's `space_per_item`. Clay grows
-- the smallest children first until they are all equal and then all together
-- (third_party/clay.h:2357-2391), so children of one size get the same share;
-- a child whose content is wider than its share keeps that width and takes
-- it from the others.
local function describe_flex(w)
    local node, along = fixed.describe_linear(w)

    local p = w._private

    node.share = along
    for i, child in ipairs(p.widgets) do
        node.specs[i] = { widget = child, w = "grow", h = "grow",
            [along .. "max"] = p.max_widget_size }
    end
    return node
end

-- Fixed's constructor builds flex, so widget_name names fixed.
flex._clay = { describe = describe_flex, name = "wibox.layout.flex" }

return flex

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
