---------------------------------------------------------------------------
-- A container rotating the conained widget by 90 degrees.
--
--@DOC_wibox_container_defaults_rotate_EXAMPLE@
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @containermod wibox.container.rotate
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local error = error
local setmetatable = setmetatable
local tostring = tostring
local base = require("wibox.widget.base")
local gtable = require("gears.table")

local rotate = { mt = {} }




--- The widget to be rotated.
--
-- @property widget
-- @tparam[opt=nil] widget|nil widget
-- @interface container

rotate.set_widget = base.set_widget_common

function rotate:get_widget()
    return self._private.widget
end

function rotate:get_children()
    return {self._private.widget}
end

function rotate:set_children(children)
    self:set_widget(children[1])
end

--- Reset this layout.
--
-- The widget will be removed and the rotation reset.
--
-- @method reset
-- @noreturn
-- @interface container
function rotate:reset()
    self._private.direction = nil
    self:set_widget(nil)
end

--- The direction of this rotating container.
--
--@DOC_wibox_container_rotate_angle_EXAMPLE@
-- @property direction
-- @tparam[opt="north"] string direction
-- @propertyvalue "north"
-- @propertyvalue "east"
-- @propertyvalue "south"
-- @propertyvalue "north"
-- @propemits true false

function rotate:set_direction(dir)
    local allowed = {
        north = true,
        east = true,
        south = true,
        west = true
    }

    if not allowed[dir] then
        error("Invalid direction for rotate layout: " .. tostring(dir))
    end

    self._private.direction = dir
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::direction")
end

-- Get the direction of this rotating layout
function rotate:get_direction()
    return self._private.direction or "north"
end

--- Returns a new rotate container.
--
-- A rotate container rotates a given widget. Use the `widget` property
-- to set the widget and `direction` property for the direction.
-- The default direction is "north" which doesn't change anything.
-- @tparam[opt] widget widget The widget to display.
-- @tparam[opt] string dir The direction to rotate to.
-- @treturn table A new rotate container.
-- @constructorfct wibox.container.rotate
local function new(widget, dir)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, rotate, true)

    ret:set_widget(widget)
    ret:set_direction(dir or "north")

    return ret
end

function rotate.mt:__call(...)
    return new(...)
end

return setmetatable(rotate, rotate.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
