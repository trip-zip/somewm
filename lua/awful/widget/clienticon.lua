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

function clienticon:draw(_, cr, width, height)
    local s, w, h = icon_surface(self._private.client)
    if not s then return end
    local aspect = math.min(width / w, height / h)
    cr:scale(aspect, aspect)
    cr:set_source_surface(s, 0, 0)
    cr:paint()
end

function clienticon:fit(_, width, height)
    local _, w, h = icon_surface(self._private.client)
    if not w then return 0, 0 end

    if w > width then
        h = h * width / w
        w = width
    end
    if h > height then
        w = w * height / h
        h = height
    end

    local aspect = math.min(width / w, height / h)
    return w * aspect, h * aspect
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

return setmetatable(clienticon, {
    __call = function(_, ...)
        return new(...)
    end
})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
