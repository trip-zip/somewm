---------------------------------------------------------------------------
--- Container showing the icon of a client.
-- @author Uli Schlachter
-- @copyright 2017 Uli Schlachter
-- @widgetmod awful.widget.clienticon
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local surface = require("gears.surface")
local gtable = require("gears.table")

local clienticon = {}
local instances = setmetatable({}, { __mode = "k" })

local function icon_surface(c)
    if not c or not c.valid or not c.icon then return nil end
    local s = surface(c.icon)
    local w, h = s.width, s.height
    if w == 0 or h == 0 then return nil end
    return s, w, h
end



--- The widget's @{client}.
--
-- @property client
-- @tparam[opt=nil] client|nil client
-- @propemits true false

function clienticon:get_client()
    return self._private.client
end

function clienticon:set_client(c)
    if self._private.client == c then return end
    self._private.client = c
    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::client", c)
end

--- Returns a new clienticon.
-- @tparam client c The client whose icon should be displayed.
-- @treturn widget A new `widget`
-- @constructorfct awful.widget.clienticon
local function new(c)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, clienticon, true)

    ret._private.client = c

    instances[ret] = true

    return ret
end

client.connect_signal("property::icon", function(c)
    for obj in pairs(instances) do
        if obj._private.client == c and obj._private.client.valid then
            obj:emit_signal("widget::layout_changed")
            obj:emit_signal("widget::redraw_needed")
        end
    end
end)

-- The icon as a Clay image element at the widget's `:fit`, which keeps
-- the icon's aspect within the bound, as `clienticon:draw` scales it; no
-- icon is an empty element, as `:fit` answers 0.
local clay = require("wibox.clay")

clay.describe_class(clienticon, function(w)
    local s, sw, sh = icon_surface(w._private.client)

    if not s then
        return {}
    end

    local image = { image = s._native, class = "image", aspect = sw / sh }

    return { specs = { image } }
end)

return setmetatable(clienticon, {
    __call = function(_, ...)
        return new(...)
    end
})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
