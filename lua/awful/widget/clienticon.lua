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
local aclient = require("awful.client")

local clienticon = {}
local instances = setmetatable({}, { __mode = "k" })

local function find_best_icon(sizes, width, height)
    local best, best_size
    for k, size in ipairs(sizes) do
        if not best then
            best, best_size = k, size
        else
            local best_too_small = best_size[1] < width or best_size[2] < height
            local best_too_large = best_size[1] > width or best_size[2] > height
            local better_because_bigger = best_too_small and size[1] > best_size[1] and size[2] > best_size[2]
            local better_because_smaller = best_too_large and size[1] < best_size[1] and size[2] < best_size[2]
                and size[1] >= width and size[2] >= height
            if better_because_bigger or better_because_smaller then
                best, best_size = k, size
            end
        end
    end
    return best, best_size
end

-- Load and cache a fallback surface from the desktop-entry icon path.
local function get_fallback_surface(self, c)
    if self._private.fallback_surface then
        return self._private.fallback_surface
    end
    local path = aclient.get_icon_path(c)
    if path then
        local s = surface.load_silently(path)
        if s and s.width > 0 and s.height > 0 then
            self._private.fallback_surface = s
            return s
        end
    end
    return nil
end

function clienticon:draw(_, cr, width, height)
    local c = self._private.client
    if not c or not c.valid then
        return
    end

    local s, sw, sh
    local index, size = find_best_icon(c.icon_sizes, width, height)
    if index then
        s = surface(c:get_icon(index))
        sw, sh = size[1], size[2]
    else
        s = get_fallback_surface(self, c)
        if not s then return end
        sw, sh = s.width, s.height
    end

    local aspect = math.min(width / sw, height / sh)
    cr:scale(aspect, aspect)
    cr:set_source_surface(s, 0, 0)
    cr:paint()
end

function clienticon:fit(_, width, height)
    local c = self._private.client
    if not c or not c.valid then
        return 0, 0
    end

    local w, h
    local index, size = find_best_icon(c.icon_sizes, width, height)
    if index then
        w, h = size[1], size[2]
    else
        local s = get_fallback_surface(self, c)
        if not s then return 0, 0 end
        w, h = s.width, s.height
    end

    if w > width then
        h = h * width / w
        w = width
    end
    if h > height then
        w = w * height / h
        h = height
    end

    if h == 0 or w == 0 then
        return 0, 0
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
