---------------------------------------------------------------------------
-- Place multiple widgets on top of each other.
--
-- This layout display widgets on top of each other. It can be used to overlay
-- a `wibox.widget.textbox` on top of a `awful.widget.progressbar` or manage
-- "pages" where only one is visible at any given moment.
--
-- The indices are going from 1 (the bottom of the stack) up to the top of
-- the stack. The order can be changed either using `:swap` or `:raise`.
--
--@DOC_wibox_layout_defaults_stack_EXAMPLE@
-- @author Emmanuel Lepage Vallee
-- @copyright 2016 Emmanuel Lepage Vallee
-- @layoutmod wibox.layout.stack
-- @supermodule wibox.layout.fixed
---------------------------------------------------------------------------

local clay = require("wibox.clay")
local fixed = require("wibox.layout.fixed")
local table = table
local gtable  = require("gears.table")

local stack = {mt={}}

--- Add some widgets to the given stack layout.
--
-- @tparam widget ... Widgets that should be added (must at least be one)
-- @noreturn
-- @method add
-- @interface layout

--- Remove a widget from the layout.
--
-- @tparam number index The widget index to remove
-- @treturn boolean index If the operation is successful
-- @method remove
-- @interface layout

--- Insert a new widget in the layout at position `index`.
--
-- @tparam number index The position
-- @tparam widget widget The widget
-- @treturn boolean If the operation is successful
-- @method insert
-- @emits widget::inserted
-- @emitstparam widget::inserted widget self The fixed layout.
-- @emitstparam widget::inserted widget widget index The inserted widget.
-- @emitstparam widget::inserted number count The widget count.
-- @interface layout

--- Remove one or more widgets from the layout.
--
-- The last parameter can be a boolean, forcing a recursive seach of the
-- widget(s) to remove.
--
-- @tparam widget widget ... Widgets that should be removed (must at least be one)
-- @treturn boolean If the operation is successful
-- @method remove_widgets
-- @interface layout

--- Add spacing around the widget, similar to the margin container.
--
--@DOC_wibox_layout_stack_spacing_EXAMPLE@
-- @property spacing
-- @tparam[opt=0] number spacing Spacing between widgets.
-- @negativeallowed false
-- @propertyunit pixel
-- @propemits true false
-- @interface layout


--- If only the first stack widget is drawn.
--
-- @property top_only
-- @tparam[opt=false] boolean top_only
-- @propemits true false

function stack:get_top_only()
    return self._private.top_only
end

function stack:set_top_only(top_only)
    self._private.top_only = top_only
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::top_only", top_only)
end

--- Raise a widget at `index` to the top of the stack.
--
-- @method raise
-- @tparam number index The widget index to raise
-- @noreturn
function stack:raise(index)
    if (not index) or (not self._private.widgets[index]) then return end

    local w = self._private.widgets[index]
    table.remove(self._private.widgets, index)
    table.insert(self._private.widgets, 1, w)

    self:emit_signal("widget::layout_changed")
end

--- Raise the first instance of `widget`.
--
-- @method raise_widget
-- @tparam widget widget The widget to raise
-- @tparam[opt=false] boolean recursive Also look deeper in the hierarchy to
--   find the widget
-- @noreturn
function stack:raise_widget(widget, recursive)
    local idx, layout = self:index(widget, recursive)

    if not idx or not layout then return end

    -- Bubble up in the stack until the right index is found
    while layout and layout ~= self do
        idx, layout = self:index(layout, recursive)
    end

    if layout == self and idx ~= 1 then
        self:raise(idx)
    end
end

--- Add an horizontal offset to each layers.
--
-- Note that this reduces the overall size of each widgets by the sum of all
-- layers offsets.
--
--@DOC_wibox_layout_stack_offset_EXAMPLE@
--
-- @property horizontal_offset
-- @tparam[opt=0] number horizontal_offset
-- @propertyunit pixel
-- @negativeallowed true
-- @propemits true false
-- @see vertical_offset

--- Add an vertical offset to each layers.
--
-- Note that this reduces the overall size of each widgets by the sum of all
-- layers offsets.
--
-- @property vertical_offset
-- @tparam[opt=0] number vertical_offset
-- @propertyunit pixel
-- @negativeallowed true
-- @propemits true false
-- @see horizontal_offset

function stack:set_horizontal_offset(value)
    self._private.h_offset = value
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::horizontal_offset", value)
end

function stack:get_horizontal_offset()
    return self._private.h_offset
end

function stack:set_vertical_offset(value)
    self._private.v_offset = value
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::vertical_offset", value)
end

function stack:get_vertical_offset()
    return self._private.v_offset
end

--- Create a new stack layout.
--
-- @constructorfct wibox.layout.stack
-- @treturn widget A new stack layout

local function new(...)
    local ret = fixed.horizontal(...)

    gtable.crush(ret, stack, true)

    ret._private.h_offset = 0
    ret._private.v_offset = 0

    return ret
end

function stack.mt:__call(...)
    return new(...)
end

--@DOC_fixed_COMMON@

--- wibox.layout.stack -> one floating element per child, attached to the
-- stack's top left and sized to it (clay.h:2230-2234 sizes a floating root
-- with grow sizing to its parent), each drawn over the one before (equal
-- zIndex, declaration order, clay.h:2603-2615). The stack's spacing and the
-- accumulated offsets are that element's padding around the child, which is
-- how the engine shrinks each child: by twice the spacing and by the offset
-- times the child count.
local function describe_stack(w)
    local p = w._private
    local spacing = clay.pixels(w, "spacing", p.spacing)
    local ho = clay.pixels(w, "horizontal_offset", p.h_offset)
    local vo = clay.pixels(w, "vertical_offset", p.v_offset)

    local n = #p.widgets
    local specs = {}

    for i, child in ipairs(p.widgets) do
        local k = i - 1

        specs[i] = {
            float = true, w = "grow", h = "grow",
            pad = { spacing + k * ho, spacing + (n - k) * ho,
                spacing + k * vo, spacing + (n - k) * vo },
            children = clay.whole_box(child),
        }
        if p.top_only then
            break
        end
    end

    return { specs = specs }
end

-- Fixed's constructor builds stack, so widget_name names fixed.
stack._clay = { describe = describe_stack, name = "wibox.layout.stack" }

return setmetatable(stack, stack.mt)
-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
