---------------------------------------------------------------------------
--- Accessibility features for somewm/AwesomeWM.
--
-- This module provides accessibility features such as cursor location
-- indicators to help users find their cursor on screen.
--
-- Bind to a key in rc.lua:
--
--    awful.key({ "Mod4" }, "c", awful.accessibility.find_cursor,
--              {description = "find cursor", group = "accessibility"})
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
-- @module awful.accessibility
---------------------------------------------------------------------------

local gtimer    = require("gears.timer")
local gtable    = require("gears.table")
local gobject   = require("gears.object")
local gcolor    = require("gears.color")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local cairo     = require("lgi").cairo

local capi = {
    mouse = mouse,
    screen = screen,
}

local accessibility = { mt = {} }
local instance_methods = {}

-- Internal state for find cursor
local cursor_finder_wibox = nil
local animation_timer = nil

--- The find cursor animation duration in seconds.
-- @beautiful beautiful.accessibility_cursor_finder_duration
-- @tparam[opt=0.8] number accessibility_cursor_finder_duration

--- The find cursor ring starting radius in pixels.
-- @beautiful beautiful.accessibility_cursor_finder_radius
-- @tparam[opt=100] number accessibility_cursor_finder_radius

--- The find cursor ring color.
-- @beautiful beautiful.accessibility_cursor_finder_color
-- @tparam[opt="#ff6600"] color accessibility_cursor_finder_color

--- The find cursor ring line width in pixels.
-- @beautiful beautiful.accessibility_cursor_finder_line_width
-- @tparam[opt=3] number accessibility_cursor_finder_line_width

--- The number of concentric rings in the find cursor animation.
-- @beautiful beautiful.accessibility_cursor_finder_ring_count
-- @tparam[opt=2] number accessibility_cursor_finder_ring_count

-- Default configuration values
local defaults = {
    cursor_finder_enabled = true,
    cursor_finder_duration = 0.8,
    cursor_finder_radius = 100,
    cursor_finder_color = "#ff6600",
    cursor_finder_line_width = 3,
    cursor_finder_ring_count = 2,
}

--- Is the find cursor feature enabled?
-- @property cursor_finder_enabled
-- @tparam[opt=true] boolean cursor_finder_enabled
-- @propemits true false

--- The duration of the find cursor animation in seconds.
-- @property cursor_finder_duration
-- @tparam[opt=0.8] number cursor_finder_duration
-- @propbeautiful
-- @propemits true false

--- The starting radius of the find cursor ring in pixels.
-- @property cursor_finder_radius
-- @tparam[opt=100] number cursor_finder_radius
-- @propbeautiful
-- @propemits true false

--- The color of the find cursor ring.
-- @property cursor_finder_color
-- @tparam[opt="#ff6600"] color cursor_finder_color
-- @propbeautiful
-- @propemits true false

--- The ring line width in pixels.
-- @property cursor_finder_line_width
-- @tparam[opt=3] number cursor_finder_line_width
-- @propbeautiful
-- @propemits true false

--- Number of concentric animation rings.
-- @property cursor_finder_ring_count
-- @tparam[opt=2] number cursor_finder_ring_count
-- @propbeautiful
-- @propemits true false

-- Generate property getters/setters for all configuration
for prop, default in pairs(defaults) do
    local beautiful_key = "accessibility_" .. prop

    instance_methods["set_" .. prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("property::" .. prop, value)
    end

    instance_methods["get_" .. prop] = function(self)
        return self._private[prop]
            or beautiful[beautiful_key]
            or default
    end
end

-- Parse color to RGBA components
local function parse_color_rgba(color_str)
    local r, g, b, a = gcolor.parse_color(color_str)
    return r or 1, g or 0.4, b or 0, a or 1
end

--- Trigger the find cursor animation.
--
-- Shows animated rings that shrink toward and converge on the current
-- cursor position, helping the user locate the cursor on screen.
--
-- @method find_cursor
-- @noreturn
-- @emits cursor_finder::start When the animation begins.
-- @emits cursor_finder::end When the animation completes.
function instance_methods:find_cursor()
    -- Early exit if disabled
    if not self.cursor_finder_enabled then return end

    -- Don't start a new animation if one is already running
    if animation_timer and animation_timer.started then return end

    -- Get configuration values
    local duration = self.cursor_finder_duration
    local start_radius = self.cursor_finder_radius
    local ring_color = self.cursor_finder_color
    local line_width = self.cursor_finder_line_width
    local ring_count = self.cursor_finder_ring_count

    -- Get cursor position
    local coords = capi.mouse.coords()

    -- Calculate wibox size (needs to fit largest ring plus line width)
    local size = math.ceil((start_radius + line_width) * 2)

    -- Create or reconfigure the overlay wibox
    cursor_finder_wibox = cursor_finder_wibox or wibox {
        ontop = true,
        visible = false,
        bg = "#00000000",  -- Fully transparent background
        type = "utility",
    }

    cursor_finder_wibox.input_passthrough = true
    cursor_finder_wibox:geometry({
        x = coords.x - size / 2,
        y = coords.y - size / 2,
        width = size,
        height = size,
    })

    -- Animation state
    local elapsed = 0
    local fps = 60
    local frame_time = 1 / fps

    self:emit_signal("cursor_finder::start")

    -- Parse the color once
    local r, g, b, _ = parse_color_rgba(ring_color)

    -- Animation timer
    animation_timer = gtimer {
        timeout = frame_time,
        callback = function()
            elapsed = elapsed + frame_time
            local progress = elapsed / duration

            if progress >= 1 then
                cursor_finder_wibox.visible = false
                animation_timer:stop()
                self:emit_signal("cursor_finder::end")
                return false
            end

            -- Update position to follow cursor during animation
            local new_coords = capi.mouse.coords()
            cursor_finder_wibox:geometry({
                x = new_coords.x - size / 2,
                y = new_coords.y - size / 2,
            })

            -- Create a new surface for this frame
            local img = cairo.ImageSurface(cairo.Format.ARGB32, size, size)
            local cr = cairo.Context(img)

            cr:set_line_width(line_width)

            -- Draw each ring
            for i = 1, ring_count do
                -- Each ring starts with a slight delay for staggered effect
                local ring_delay = (i - 1) * 0.15
                local ring_progress = math.max(0, (progress - ring_delay) / (1 - ring_delay))

                if ring_progress > 0 and ring_progress < 1 then
                    -- Radius shrinks from start_radius toward 0
                    local radius = start_radius * (1 - ring_progress)
                    -- Opacity fades out as ring shrinks
                    local alpha = 1 - ring_progress

                    cr:set_source_rgba(r, g, b, alpha)
                    cr:arc(size / 2, size / 2, radius, 0, 2 * math.pi)
                    cr:stroke()
                end
            end

            cursor_finder_wibox.bgimage = img
            cursor_finder_wibox.visible = true

            return true
        end,
    }

    animation_timer:start()
end

-- NOTE: Passive key monitoring (for double-tap CTRL detection) would require
-- C-level changes to emit key events without grabbing the keyboard.
-- For now, users should bind find_cursor() to a key combo like Mod4+c.

-- Singleton instance for module-level convenience functions
local default_instance = nil

local function get_default()
    if not default_instance then
        default_instance = accessibility.new({})
    end
    return default_instance
end

--- Create a new accessibility manager instance.
--
-- @constructorfct awful.accessibility
-- @tparam[opt={}] table args Configuration arguments.
-- @tparam[opt=true] boolean args.cursor_finder_enabled Enable the find cursor feature.
-- @tparam[opt=0.8] number args.cursor_finder_duration Animation duration in seconds.
-- @tparam[opt=100] number args.cursor_finder_radius Starting ring radius in pixels.
-- @tparam[opt="#ff6600"] color args.cursor_finder_color Ring color.
-- @tparam[opt=3] number args.cursor_finder_line_width Ring line width in pixels.
-- @tparam[opt=2] number args.cursor_finder_ring_count Number of concentric rings.
-- @treturn awful.accessibility The accessibility instance.
function accessibility.new(args)
    args = args or {}

    local self = gobject {
        enable_properties = true,
    }

    rawset(self, "_private", {})

    gtable.crush(self, instance_methods, true)

    -- Apply any provided configuration
    for k, v in pairs(args) do
        if instance_methods["set_" .. k] then
            self[k] = v
        end
    end

    return self
end

function accessibility.mt:__call(...)
    return accessibility.new(...)
end

-- Module-level convenience functions that use the singleton

--- Trigger the find cursor animation (module-level convenience function).
--
-- @staticfct awful.accessibility.find_cursor
-- @noreturn
function accessibility.find_cursor()
    get_default():find_cursor()
end

return setmetatable(accessibility, accessibility.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
