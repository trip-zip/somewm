---------------------------------------------------------------------------
-- Reflect a widget along one or both axis.
--
--@DOC_wibox_container_defaults_mirror_EXAMPLE@
-- @author dodo
-- @copyright 2012 dodo
-- @containermod wibox.container.mirror
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local type = type
local error = error
local ipairs = ipairs
local setmetatable = setmetatable
local base = require("wibox.widget.base")
local gtable = require("gears.table")

local mirror = { mt = {} }



--- The widget to be reflected.
--
-- @property widget
-- @tparam[opt=nil] widget|nil widget
-- @interface container

mirror.set_widget = base.set_widget_common

function mirror:get_widget()
    return self._private.widget
end

function mirror:get_children()
    return {self._private.widget}
end

function mirror:set_children(children)
    self:set_widget(children[1])
end

--- Reset this layout. The widget will be removed and the axes reset.
--
-- @method reset
-- @noreturn
-- @interface container
function mirror:reset()
    self._private.horizontal = false
    self._private.vertical = false
    self:set_widget(nil)
end

function mirror:set_reflection(reflection)
    if type(reflection) ~= 'table' then
        error("Invalid type of reflection for mirror layout: " ..
              type(reflection) .. " (should be a table)")
    end
    for _, ref in ipairs({"horizontal", "vertical"}) do
        if reflection[ref] ~= nil then
            self._private[ref] = reflection[ref]
        end
    end
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::reflection", reflection)
end

--- Get the reflection of this mirror layout.
--
-- @property reflection
-- @tparam table reflection A table of booleans with the keys "horizontal", "vertical".
-- @tparam[opt=false] boolean reflection.horizontal
-- @tparam[opt=false] boolean reflection.vertical
-- @propemits true false

function mirror:get_reflection()
    return { horizontal = self._private.horizontal, vertical = self._private.vertical }
end

--- Returns a new mirror container.
--
-- A mirror container mirrors a given widget. Use the `widget` property to set
-- the widget and `reflection` property to set the direction.
-- horizontal and vertical are by default false which doesn't change anything.
--
-- @tparam[opt] widget widget The widget to display.
-- @tparam[opt] table reflection A table describing the reflection to apply.
-- @treturn table A new mirror container
-- @constructorfct wibox.container.mirror
local function new(widget, reflection)
    local ret = base.make_widget(nil, nil, {enable_properties = true})
    ret._private.horizontal = false
    ret._private.vertical = false

    gtable.crush(ret, mirror, true)

    ret:set_widget(widget)
    ret:set_reflection(reflection or {})

    return ret
end

function mirror.mt:__call(...)
    return new(...)
end

return setmetatable(mirror, mirror.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
