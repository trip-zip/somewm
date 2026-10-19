---------------------------------------------------------------------------
--- Accessibility helpers, including explicit and shake-activated pointer location.
--
--    local a11y = awful.accessibility {
--        cursor_finder_effect = "magnify",
--        cursor_finder_shake_enabled = true,
--    }
--    awful.key({"Mod4"}, "c", function() a11y:find_cursor() end)
--
-- Without an instance, awful.accessibility.find_cursor() uses theme defaults.
-- @author Jimmy Cozza
-- @author Milkii Brewster
-- @module awful.accessibility
---------------------------------------------------------------------------
local object = require("gears.object")
local gtable = require("gears.table")
local timer = require("gears.timer")
local beautiful = require("beautiful")
local GLib = require("lgi").GLib
local capi = {awesome = awesome, mouse = mouse, root = root}
local accessibility = {mt = {}}
local methods = {}
local active, shake_owner, default_instance
local motion_connected = false
local on_motion, update_motion

--- Allow explicit and shake activation.
-- @property cursor_finder_enabled
-- @tparam[opt=true] boolean cursor_finder_enabled
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_enabled

--- Visual effect: rings, magnify, or both.
-- @property cursor_finder_effect
-- @tparam[opt=rings] string cursor_finder_effect
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_effect

--- Ring duration in seconds.
-- @property cursor_finder_duration
-- @tparam[opt=0.8] number cursor_finder_duration
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_duration

--- Initial outer ring radius in logical pixels.
-- @property cursor_finder_radius
-- @tparam[opt=100] number cursor_finder_radius
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_radius

--- Solid ring colour.
-- @property cursor_finder_color
-- @tparam[opt=#ff6600] color cursor_finder_color
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_color

--- Ring stroke width in logical pixels.
-- @property cursor_finder_line_width
-- @tparam[opt=3] number cursor_finder_line_width
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_line_width

--- Number of concentric rings.
-- @property cursor_finder_ring_count
-- @tparam[opt=2] integer cursor_finder_ring_count
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_ring_count

--- Enable event-driven shake detection for this instance.
-- @property cursor_finder_shake_enabled
-- @tparam[opt=false] boolean cursor_finder_shake_enabled
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_shake_enabled

--- Initial cursor magnification factor.
-- @property cursor_finder_magnification
-- @tparam[opt=3] number cursor_finder_magnification
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_magnification

--- Additional magnification per repeated activation.
-- @property cursor_finder_over_magnification
-- @tparam[opt=1] number cursor_finder_over_magnification
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_over_magnification

--- Maximum cursor magnification factor.
-- @property cursor_finder_max_scale
-- @tparam[opt=4] number cursor_finder_max_scale
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_max_scale

--- Cursor inflation duration in seconds; zero snaps.
-- @property cursor_finder_inflate_duration
-- @tparam[opt=0.2] number cursor_finder_inflate_duration
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_inflate_duration

--- Cursor deflation duration in seconds; zero snaps.
-- @property cursor_finder_deflate_duration
-- @tparam[opt=1] number cursor_finder_deflate_duration
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_deflate_duration

--- Inactivity in seconds before cursor deflation.
-- @property cursor_finder_deflate_delay
-- @tparam[opt=1.5] number cursor_finder_deflate_delay
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_deflate_delay

--- Shake motion history window in seconds.
-- @property cursor_finder_history_window
-- @tparam[opt=1] number cursor_finder_history_window
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_history_window

--- Required travelled-distance to bounding-diagonal ratio.
-- @property cursor_finder_sensitivity
-- @tparam[opt=4] number cursor_finder_sensitivity
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_sensitivity

--- Minimum shake bounds diagonal in logical pixels.
-- @property cursor_finder_min_diagonal
-- @tparam[opt=100] number cursor_finder_min_diagonal
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_min_diagonal

--- Shake cooldown in seconds after deflation begins or the locator stops.
-- @property cursor_finder_cooldown
-- @tparam[opt=0.5] number cursor_finder_cooldown
-- @propemits true false
-- @beautiful beautiful.accessibility_cursor_finder_cooldown

local defaults = {
    cursor_finder_enabled = true,
    cursor_finder_effect = "rings",
    cursor_finder_duration = 0.8,
    cursor_finder_radius = 100,
    cursor_finder_color = "#ff6600",
    cursor_finder_line_width = 3,
    cursor_finder_ring_count = 2,
    cursor_finder_shake_enabled = false,
    cursor_finder_magnification = 3,
    cursor_finder_over_magnification = 1,
    cursor_finder_max_scale = 4,
    cursor_finder_inflate_duration = 0.2,
    cursor_finder_deflate_duration = 1,
    cursor_finder_deflate_delay = 1.5,
    cursor_finder_history_window = 1,
    cursor_finder_sensitivity = 4,
    cursor_finder_min_diagonal = 100,
    cursor_finder_cooldown = 0.5,
}
local bounds = {
    duration = {0.01, 60}, radius = {1, 512}, line_width = {1, 64},
    ring_count = {1, 8, true}, magnification = {1, 16},
    over_magnification = {0, 15}, max_scale = {1, 16},
    inflate_duration = {0, 60}, deflate_duration = {0, 60},
    deflate_delay = {0.01, 60}, history_window = {0.01, 10},
    sensitivity = {1, 100}, min_diagonal = {1, 4096}, cooldown = {0, 60},
}
local function now() return GLib.get_monotonic_time() / 1e6 end
local function has_rings(self) return self.cursor_finder_effect ~= "magnify" end
local function has_magnification(self) return self.cursor_finder_effect ~= "rings" end
local function stop_timer(t) if t and t.started then t:stop() end end

local function validate(property, value)
    if value == nil then return end
    local short = property:sub(#"cursor_finder_" + 1)
    if short == "effect" then
        assert(value == "rings" or value == "magnify" or value == "both",
            property .. " must be rings, magnify, or both")
    elseif short == "color" then
        local r = require("gears.color").parse_color(value)
        assert(r, property .. " must be a solid color")
    elseif type(defaults[property]) == "boolean" then
        assert(type(value) == "boolean", property .. " must be a boolean")
    else
        local b = bounds[short]
        assert(type(value) == "number" and value >= b[1] and value <= b[2]
            and (not b[3] or value % 1 == 0), property .. " is outside its supported range")
    end
end

local function follow(self, x, y)
    local w = self._private.overlay
    if w then w:geometry {x = math.floor(x - w.width / 2), y = math.floor(y - w.height / 2)} end
end

local function clear_rings(self)
    local p = self._private
    if p.commit then capi.awesome.disconnect_signal("clay::_commit", p.commit); p.commit = nil end
    stop_timer(p.ring_timer)
    p.ring_token = (p.ring_token or 0) + 1
    if p.overlay then p.overlay.visible = false end
    p.rings_active = false
end

--- End this instance's locator and immediately restore normal cursor size.
-- Other instances are unaffected. Disabling the finder also calls this method.
-- @method stop
function methods:stop()
    local p = self._private
    stop_timer(p.deflate_timer)
    stop_timer(p.finish_timer)
    clear_rings(self)
    p.samples, p.target, p.magnifying = {}, 1, false
    p.cooldown_until = now() + self.cursor_finder_cooldown
    if active == self then
        capi.root._cursor_magnify(1, 0)
        active = nil
        update_motion()
        self:emit_signal("cursor_finder::end")
    else
        update_motion()
    end
end

local function finish_if_idle(self)
    if active == self and not self._private.rings_active and not self._private.magnifying then
        self:stop()
    end
end

local function show_rings(self)
    clear_rings(self)
    local wibox = require("wibox")
    local shape = require("gears.shape")
    local p, rings = self._private, {}
    local size = math.ceil((self.cursor_finder_radius + self.cursor_finder_line_width) * 2)
    local stack = wibox.layout.stack()
    for i = 1, self.cursor_finder_ring_count do
        local diameter = 2 * self.cursor_finder_radius * (1 - (i - 1) / (self.cursor_finder_ring_count + 1))
        local ring = wibox.container.background()
        ring:set_shape(shape.rounded_rect, diameter / 2)
        ring.border_width, ring.border_color = self.cursor_finder_line_width, self.cursor_finder_color
        ring.forced_width, ring.forced_height = diameter, diameter
        rings[#rings + 1] = ring
        stack:add(wibox.container.place(ring))
    end
    p.overlay = p.overlay or wibox {ontop = true, bg = "#00000000",
        input_passthrough = true, shadow = false, animation = false, type = "utility"}
    p.overlay:geometry {width = size, height = size}
    p.overlay.widget = stack
    local coords = capi.mouse.coords()
    follow(self, coords.x, coords.y)
    p.overlay.visible, p.rings_active = true, true
    local token, duration = p.ring_token, self.cursor_finder_duration
    local r, g, b = require("gears.color").parse_color(self.cursor_finder_color)
    local faded = string.format("#%02x%02x%02x01", math.floor(r * 255 + .5),
        math.floor(g * 255 + .5), math.floor(b * 255 + .5))
    -- Wait for the initial sizes to be published before requesting their
    -- transitions. A cancelled locator cannot start from a delayed callback.
    p.commit = function(s)
        if s ~= p.overlay.screen then return end
        capi.awesome.disconnect_signal("clay::_commit", p.commit)
        p.commit = nil
        timer.delayed_call(function()
            if active ~= self or token ~= p.ring_token then return end
            p.overlay.animation = nil
            for _, ring in ipairs(rings) do
                ring:animate {forced_width = 0, forced_height = 0,
                    -- Keep a painted border in the target declaration while its
                    -- colour transitions; the overlay hides at completion.
                    border_color = faded, duration = duration}
            end
            p.ring_timer = timer {timeout = duration, single_shot = true, autostart = true,
                callback = function()
                    clear_rings(self)
                    finish_if_idle(self)
                end}
        end)
    end
    capi.awesome.connect_signal("clay::_commit", p.commit)
end

local function magnify(self)
    local p = self._private
    stop_timer(p.deflate_timer)
    stop_timer(p.finish_timer)
    local current = capi.root._cursor_magnify()
    local target = p.magnifying and current > 1 and (p.target or 1) > 1
        and p.target + self.cursor_finder_over_magnification or self.cursor_finder_magnification
    p.target = math.min(target, self.cursor_finder_max_scale)
    p.magnifying = true
    capi.root._cursor_magnify(p.target, self.cursor_finder_inflate_duration)
    p.deflate_timer = timer {timeout = self.cursor_finder_deflate_delay, single_shot = true,
        autostart = true, callback = function()
            p.target, p.samples = 1, {}
            p.cooldown_until = now() + self.cursor_finder_cooldown
            local duration = self.cursor_finder_deflate_duration
            capi.root._cursor_magnify(1, duration)
            p.finish_timer = timer {timeout = math.max(0.001, duration), single_shot = true,
                autostart = true, callback = function()
                    p.magnifying = false
                    finish_if_idle(self)
                end}
        end}
end

--- Reveal the pointer using rings, magnification, or both.
-- A repeated activation restarts the rings and extends magnification, up to
-- cursor_finder_max_scale. Activating another instance ends this locator.
-- @method find_cursor
-- @signal cursor_finder::start Emitted once when a locator becomes active.
-- @signal cursor_finder::end Emitted when it finishes or is stopped.
function methods:find_cursor()
    if not self.cursor_finder_enabled then return end
    if active and active ~= self then active:stop() end
    local starting = active ~= self
    active = self
    if has_rings(self) then show_rings(self) end
    if has_magnification(self) then magnify(self) end
    update_motion()
    if starting then self:emit_signal("cursor_finder::start") end
end

-- Shake detection: SPDX-FileCopyrightText: 2023 Vlad Zahorodnii
-- SPDX-License-Identifier: GPL-2.0-or-later
-- Collapse same-direction samples; compare travelled distance with the
-- history's bounding diagonal to distinguish reversals from straight motion.
local function same_sign(a, b)
    return (math.abs(a) <= 1 and math.abs(b) <= 1) or (a < 0 and b < 0) or (a > 0 and b > 0)
end
local function detect(self, x, y, t)
    local samples = self._private.samples
    while samples[1] and t - samples[1].t >= self.cursor_finder_history_window do table.remove(samples, 1) end
    local n = #samples
    if n >= 2 then
        local prev, last = samples[n - 1], samples[n]
        if same_sign(last.x - prev.x, x - last.x) and same_sign(last.y - prev.y, y - last.y) then
            last.x, last.y, last.t = x, y, t
            return false, false
        end
    end
    -- Bound storage even with a high-frequency input device oscillating for
    -- the whole history window without meeting the distance threshold.
    if n >= 4096 then table.remove(samples, 1) end
    samples[#samples + 1] = {x = x, y = y, t = t}
    local distance = 0
    local left, right, top, bottom = samples[1].x, samples[1].x, samples[1].y, samples[1].y
    for i = 2, #samples do
        local a, b = samples[i - 1], samples[i]
        distance = distance + math.sqrt((b.x - a.x)^2 + (b.y - a.y)^2)
        left, right, top, bottom = math.min(left, b.x), math.max(right, b.x),
            math.min(top, b.y), math.max(bottom, b.y)
    end
    local diagonal = math.sqrt((right - left)^2 + (bottom - top)^2)
    if diagonal >= self.cursor_finder_min_diagonal and distance / diagonal > self.cursor_finder_sensitivity then
        self._private.samples = {}
        return true, true
    end
    return false, true
end

on_motion = function(x, y)
    if active and active._private.rings_active then follow(active, x, y) end
    local self = shake_owner
    if not self or not self.cursor_finder_enabled then return end
    local t, p = now(), self._private
    if t < (p.cooldown_until or 0) then return end
    local shook, vertex = detect(self, x, y, t)
    if shook then
        self:find_cursor()
    elseif vertex and active == self and p.target > 1 and p.deflate_timer then
        p.deflate_timer:again()
    end
end
update_motion = function()
    local needed = (shake_owner and shake_owner.cursor_finder_enabled)
        or (active and active._private.rings_active) or false
    if needed and not motion_connected then capi.awesome.connect_signal("_accessibility::motion", on_motion)
    elseif not needed and motion_connected then capi.awesome.disconnect_signal("_accessibility::motion", on_motion) end
    motion_connected = not not needed
end

for property, default in pairs(defaults) do
    methods["get_" .. property] = function(self)
        local value = self._private[property]
        if value == nil then value = beautiful["accessibility_" .. property] end
        if value == nil then value = default end
        validate(property, value)
        return value
    end
    methods["set_" .. property] = function(self, value)
        validate(property, value)
        local previous = self[property]
        self._private[property] = value
        local effective = self[property]
        if property == "cursor_finder_shake_enabled" then
            if effective then
                if shake_owner and shake_owner ~= self then shake_owner.cursor_finder_shake_enabled = false end
                shake_owner = self
            elseif shake_owner == self then shake_owner = nil end
            self._private.samples = {}
        end
        if previous ~= effective then
            if property == "cursor_finder_enabled" or property == "cursor_finder_effect" then self:stop() end
            self:emit_signal("property::" .. property, effective)
        end
        update_motion()
    end
end

--- Create an accessibility helper with property overrides and theme defaults.
-- Only the most recently shake-enabled instance observes shake gestures.
-- Each property falls back to the beautiful theme key prefixed with accessibility_.
-- @constructorfct awful.accessibility
-- @tparam[opt={}] table args Configuration properties.
-- @treturn awful.accessibility
function accessibility.new(args)
    local self = object {enable_properties = true}
    rawset(self, "_private", {samples = {}, target = 1})
    gtable.crush(self, methods, true)
    args = args or {}
    for key, value in pairs(args) do
        assert(defaults[key] ~= nil, "unknown accessibility property: " .. tostring(key))
        validate(key, value)
        self._private[key] = value
    end
    -- Validate before subscribing so a rejected constructor cannot retain a
    -- partly configured observer. Initial properties have no lifecycle side effects.
    for key in pairs(defaults) do local _ = self[key] end
    if self.cursor_finder_shake_enabled then self.cursor_finder_shake_enabled = true end
    return self
end

--- Reveal the pointer using the default instance and current theme defaults.
-- @staticfct awful.accessibility.find_cursor
function accessibility.find_cursor()
    default_instance = default_instance or accessibility.new()
    default_instance:find_cursor()
end

--- Stop the default instance's locator.
-- @staticfct awful.accessibility.stop
function accessibility.stop()
    if default_instance then default_instance:stop() end
end

function accessibility.mt:__call(args) return accessibility.new(args) end
capi.awesome.connect_signal("exit", function()
    if active then active:stop() end
    shake_owner = nil
    update_motion()
end)
return setmetatable(accessibility, accessibility.mt)
