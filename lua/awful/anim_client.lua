---------------------------------------------------------------------------
--- Client animation module for somewm.
--
-- Animates maximize/fullscreen/restore geometry transitions,
-- fadeIn/fadeOut opacity transitions for clients and layer surfaces
-- (rofi, waybar, etc.), tiling swap and float toggle animations.
--
-- Usage:
--    require("anim_client").enable()           -- all defaults
--    require("anim_client").enable({           -- with overrides
--        maximize  = { duration = 0.3 },
--        fade      = { enabled = false },
--        layer     = { duration = 0.2 },       -- layer surface fade
--        swap      = { duration = 0.3 },       -- tiling swap (Super+Shift+J/K)
--        float     = { duration = 0.3 },       -- float toggle (Ctrl+Super+Space)
--    })
--
-- Configuration priority (most specific wins):
--    1. beautiful.anim_<type>_<param>  (theme, read at call time)
--    2. config passed to enable()
--    3. Module defaults
--
-- @module anim_client
---------------------------------------------------------------------------

local awful     = require("awful")
local beautiful = require("beautiful")
local gears     = require("gears")

local anim_client = {}
local cstate = setmetatable({}, { __mode = "k" })
local active = false

-- Whitelist of classic tiling layouts where swap/float animations make sense.
-- Anything not listed here is skipped (carousel, machi, max, floating, etc.).
local tiling_layouts = {
    tile        = true,
    tileleft    = true,
    tilebottom  = true,
    tiletop     = true,
    fairv       = true,
    fairh       = true,
    spiral      = true,
    dwindle     = true,
    magnifier   = true,
    cornernw    = true,
    cornerne    = true,
    cornersw    = true,
    cornerse    = true,
}

--- Check if the current layout on a screen is a classic tiling layout.
local function is_tiling_layout(s)
    if not s then return false end
    local lt = awful.layout.get(s)
    if not lt then return false end
    return tiling_layouts[lt.name or ""] == true
end

-- =========================================================================
-- Configuration
-- =========================================================================

local defaults = {
    enabled = true,
    maximize = {
        enabled  = true,
        duration = 0.25,
        easing   = "ease-out-cubic",
    },
    fullscreen = {
        enabled  = true,
        duration = 0.25,
        easing   = "ease-out-cubic",
    },
    fade = {
        enabled      = true,
        duration     = 0.4,
        out_duration = nil,  -- falls back to duration if nil
        easing       = "ease-out-cubic",
    },
    minimize = {
        enabled  = true,
        duration = 0.4,
        easing   = "ease-out-cubic",
    },
    layer = {
        enabled  = true,
        duration = 0.35,
        easing   = "ease-out-cubic",
    },
    dialog = {
        enabled  = true,
        duration = 0.3,
        easing   = "ease-out-cubic",
    },
    swap = {
        enabled  = true,
        duration = 0.25,
        easing   = "ease-out-cubic",
    },
    float = {
        enabled  = true,
        duration = 0.3,
        easing   = "ease-out-cubic",
    },
    layout = {
        enabled  = true,
        duration = 0.15,
        easing   = "ease-out-cubic",
    },
}

local config = {}

--- Deep merge: src into dst (nil-safe for booleans)
local function merge(dst, src)
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

--- Read a config value with theme override.
-- beautiful.anim_<section>_<key> takes priority (read at call time).
local function cfg(section, key)
    local theme_key = "anim_" .. section .. "_" .. key
    local theme_val = beautiful[theme_key]
    if theme_val ~= nil then return theme_val end
    local sec = config[section]
    if sec and sec[key] ~= nil then return sec[key] end
    return defaults[section] and defaults[section][key]
end

--- Check if a specific animation type is enabled
local function is_enabled(section)
    if not config.enabled then return false end
    return cfg(section, "enabled") ~= false
end

-- =========================================================================
-- Internal helpers
-- =========================================================================

local function get(c)
    local s = cstate[c]
    if not s then s = {}; cstate[c] = s end
    return s
end

--- Check if two geometries differ by more than a negligible threshold.
-- Per-axis check (>= 2px on any axis), matching upstream layout_animation.
local function geos_differ(a, b)
    return math.abs(a.x - b.x) >= 2
        or math.abs(a.y - b.y) >= 2
        or math.abs(a.width - b.width) >= 2
        or math.abs(a.height - b.height) >= 2
end

--- Interpolate between two geometries.
local function lerp_geo(from, to, t)
    return {
        x      = math.floor(from.x + (to.x - from.x) * t + 0.5),
        y      = math.floor(from.y + (to.y - from.y) * t + 0.5),
        width  = math.max(1, math.floor(from.width + (to.width - from.width) * t + 0.5)),
        height = math.max(1, math.floor(from.height + (to.height - from.height) * t + 0.5)),
    }
end

local function cancel(c, which)
    local s = cstate[c]
    if not s then return end
    if which == "geo" or not which then
        if s.geo_handle then pcall(function() s.geo_handle:cancel() end); s.geo_handle = nil end
        s.geo_animating = false
    end
    if which == "fade" or not which then
        if s.fade_handle then pcall(function() s.fade_handle:cancel() end); s.fade_handle = nil end
    end
end

-- =========================================================================
-- Geometry animation
-- =========================================================================

--- Animate client geometry from `from` to `to`.
-- @param silent  When true, use _set_geometry_silent() to avoid triggering
--                property::geometry signals and layout re-arrange on each
--                frame. Required for tiled clients (swap, float→tiled).
local function animate_geo(c, from, to, section, silent)
    if not is_enabled(section) then return end
    local dur = cfg(section, "duration")
    local ease = cfg(section, "easing")
    if dur <= 0 or not c.valid then return end

    local d = math.abs(from.x - to.x) + math.abs(from.y - to.y)
        + math.abs(from.width - to.width) + math.abs(from.height - to.height)
    if d < 20 then return end

    local function set_geo(g)
        if silent then
            c:_set_geometry_silent(g)
        else
            c:geometry(g)
        end
    end

    cancel(c, "geo")
    local s = get(c)
    s.geo_animating = true
    set_geo(from)

    s.geo_handle = awesome.start_animation(dur, ease,
        function(t)
            if not c.valid then cancel(c, "geo"); return end
            s.geo_animating = true
            set_geo({
                x      = math.floor(from.x + (to.x - from.x) * t + 0.5),
                y      = math.floor(from.y + (to.y - from.y) * t + 0.5),
                width  = math.max(1, math.floor(from.width + (to.width - from.width) * t + 0.5)),
                height = math.max(1, math.floor(from.height + (to.height - from.height) * t + 0.5)),
            })
            s.geo_animating = true
        end,
        function()
            s.geo_animating = false
            s.geo_handle = nil
            if c.valid then
                set_geo(to)
                -- Silent animations don't emit property::geometry, so
                -- update the cached geometry manually for maximize/fullscreen
                if silent then
                    if not c.maximized and not c.fullscreen then
                        s.normal_geo = to
                    else
                        s.max_geo = to
                    end
                end
            end
        end)
end

-- =========================================================================
-- Fade animation (opacity)
-- =========================================================================

local function fade(c, from_alpha, to_alpha, section, on_done)
    if not is_enabled(section) then
        if c.valid then c.opacity = to_alpha end
        if on_done then on_done() end
        return
    end

    local fading_out = (to_alpha < from_alpha)
    local dur = fading_out and (cfg(section, "out_duration") or cfg(section, "duration"))
        or cfg(section, "duration")
    local ease = cfg(section, "easing")

    if dur <= 0 or not c.valid then
        if c.valid then c.opacity = to_alpha end
        if on_done then on_done() end
        return
    end

    cancel(c, "fade")
    local s = get(c)
    s.fading = true
    c.opacity = from_alpha

    -- Hide border during fadeOut (wlr_scene_rect doesn't support opacity)
    local saved_border
    if fading_out and c.valid then
        saved_border = c.border_width
        c.border_width = 0
    end

    s.fade_handle = awesome.start_animation(dur, ease,
        function(t)
            if not c.valid then cancel(c, "fade"); return end
            c.opacity = from_alpha + (to_alpha - from_alpha) * t
        end,
        function()
            s.fading = false
            s.fade_handle = nil
            if c.valid then
                c.opacity = to_alpha
            end
            if on_done then on_done() end
        end)
end

-- =========================================================================
-- Public API
-- =========================================================================

--- Fade-minimize a client (called from keybinding instead of c.minimized=true)
function anim_client.fade_minimize(c)
    if not c or not c.valid then return end
    if not is_enabled("minimize") then
        c.minimized = true
        return
    end
    local s = get(c)
    if s.fading then
        c.minimized = true
        return
    end
    fade(c, 1, 0, "minimize", function()
        if c.valid then
            -- Reset opacity before hiding so restore shows full opacity
            c.opacity = 1
            c.minimized = true
        end
    end)
end

--- Get current configuration (read-only copy)
function anim_client.get_config()
    return config
end

--- Enable animations with optional config overrides.
-- @tparam[opt] table user_config Override table (deep-merged over defaults)
function anim_client.enable(user_config)
    -- Build config: start with defaults, merge user overrides
    config = merge(merge({}, defaults), user_config or {})

    -- Only connect signals once
    if active then return end
    active = true

    -- Track geometry for maximize/fullscreen transitions
    client.connect_signal("property::geometry", function(c)
        if not config.enabled then return end
        local s = cstate[c]
        if s and s.geo_animating then return end
        if not c.maximized and not c.fullscreen then
            get(c).normal_geo = c:geometry()
        else
            get(c).max_geo = c:geometry()
        end
    end)

    -- Maximize animation
    client.connect_signal("property::maximized", function(c)
        local s = get(c)
        if s.geo_animating then return end
        if c.maximized then
            local from = s.normal_geo
            if not from then return end
            animate_geo(c, from, c:geometry(), "maximize")
        else
            local from = s.max_geo
            if not from then return end
            animate_geo(c, from, c:geometry(), "maximize")
        end
    end)

    -- Fullscreen animation
    client.connect_signal("property::fullscreen", function(c)
        local s = get(c)
        if s.geo_animating then return end
        if c.fullscreen then
            local from = s.normal_geo
            if not from then return end
            animate_geo(c, from, c:geometry(), "fullscreen")
        else
            local from = s.max_geo
            if not from then return end
            animate_geo(c, from, c:geometry(), "fullscreen")
        end
    end)

    -- FadeIn: new client appears
    client.connect_signal("request::manage", function(c)
        if c.valid then
            -- Use shorter "dialog" animation for transient/dialog windows
            local section = (c.transient_for or c.type == "dialog") and "dialog" or "fade"
            fade(c, 0, 1, section)
        end
    end)

    -- FadeIn on restore from minimize
    client.connect_signal("property::minimized", function(c)
        if not c.valid then return end
        local s = get(c)
        if s.fading then return end
        if not c.minimized then
            -- Restore border (fade_minimize sets it to 0)
            c.border_width = beautiful.border_width or 1
            fade(c, 0, 1, "fade")
        end
    end)

    -- Cleanup
    client.connect_signal("request::unmanage", function(c)
        cancel(c)
        cstate[c] = nil
    end)

    -- =====================================================================
    -- Layout geometry animations (swap, mwfact, spawn/kill, layout switch)
    -- =====================================================================

    -- Universal screen::arrange handler — animates ALL tiled clients when
    -- their layout position changes. Merges Jimmy's layout_animation.lua
    -- approach (universal, every arrange trigger) with our per-type config
    -- and mid-animation chaining.
    --
    -- Animation type selection:
    --   swap_pending flag  → "swap" config (0.3s, user-initiated)
    --   otherwise          → "layout" config (0.15s, background reflow)
    --
    -- NOTE: Do NOT require("somewm.layout_animation") alongside this
    -- module — both write _set_geometry_silent() and would conflict.

    -- Per-client settled geometry from last completed layout arrange.
    local layout_settled = setmetatable({}, { __mode = "k" })

    --- Start a layout/swap geometry animation on a client.
    -- Shared by swap_pending and general layout transitions.
    local function start_layout_animation(c, st, from, to, anim_type)
        local dur = cfg(anim_type, "duration")
        local ease = cfg(anim_type, "easing")
        if dur <= 0 then
            c:_set_geometry_silent(to)
            st.layout_visual = nil
            return
        end

        st.geo_animating = true
        st.layout_visual = from
        st.geo_handle = awesome.start_animation(dur, ease,
            function(t)
                if not c.valid then cancel(c, "geo"); return end
                local g = lerp_geo(from, to, t)
                st.layout_visual = g
                c:_set_geometry_silent(g)
                st.geo_animating = true
            end,
            function()
                st.geo_animating = false
                st.geo_handle = nil
                st.layout_visual = nil
                if c.valid then c:_set_geometry_silent(to) end
            end)
    end

    -- Phase 1: "swapped" signal flags clients for swap-specific animation
    client.connect_signal("swapped", function(c, other, is_origin)
        if not is_origin then return end
        if not is_enabled("swap") then return end
        if mousegrabber.isrunning() then return end
        if not is_tiling_layout(c.screen) then return end
        if not is_tiling_layout(other.screen) then return end

        local s1, s2 = get(c), get(other)

        -- Cancel running layout animations (preserves layout_visual for
        -- chaining — the arrange handler reads it as the "from" position)
        if s1.geo_animating then cancel(c, "geo") end
        if s2.geo_animating then cancel(other, "geo") end

        s1.swap_pending = true
        s2.swap_pending = true
    end)

    -- Phase 2: screen::arrange fires AFTER layout.arrange commits positions
    screen.connect_signal("arrange", function(s)
        if mousegrabber.isrunning() then return end
        if anim_client._tag_slide_active then return end
        if not is_tiling_layout(s) then return end

        local tiled = s.tiled_clients
        if not tiled then return end

        for _, c in ipairs(tiled) do
            local st = get(c)
            local new_geo = c:geometry()

            -- Capture previous layout target BEFORE updating settled cache.
            -- This is critical for the re-snap guard: we compare the previous
            -- layout target with the new one, NOT the visual mid-point.
            local prev_settled = layout_settled[c]
            local old_geo = st.layout_visual or prev_settled

            -- Always track the layout-assigned position
            layout_settled[c] = new_geo

            -- Determine animation type: swap (explicit) or layout (reflow)
            local anim_type
            if st.swap_pending then
                st.swap_pending = false
                anim_type = "swap"
            else
                anim_type = "layout"
            end

            if not is_enabled(anim_type) then
                st.layout_visual = nil
                goto continue
            end

            -- Skip if maximize/fullscreen animation owns this client
            -- (geo_animating=true but layout_visual=nil means non-layout anim)
            if st.geo_animating and not st.layout_visual then
                goto continue
            end

            -- Re-snap: layout target unchanged and animation running → keep
            -- visual position (counteracts layout's non-silent c:geometry()).
            -- Compare prev_settled (last layout target) with new_geo, NOT
            -- the visual mid-point — otherwise this guard almost never fires.
            if st.geo_animating and st.layout_visual and prev_settled
                    and not geos_differ(prev_settled, new_geo) then
                c:_set_geometry_silent(st.layout_visual)
                goto continue
            end

            -- First arrange for this client: no old position
            if not old_geo then goto continue end

            -- Skip negligible changes (< 2px per axis)
            if not geos_differ(old_geo, new_geo) then
                if st.geo_animating then cancel(c, "geo") end
                st.layout_visual = nil
                goto continue
            end

            -- Cancel any running animation, snap back, animate
            cancel(c, "geo")
            c:_set_geometry_silent(old_geo)
            start_layout_animation(c, st, old_geo, new_geo, anim_type)

            ::continue::
        end
    end)

    -- =====================================================================
    -- Float toggle animation (Ctrl+Super+Space)
    -- =====================================================================

    -- Capture geometry BEFORE the float state change applies, then defer
    -- animation start until set_floating() and layout.arrange() both finish.
    --
    -- Ordering: property::floating fires BEFORE set_floating() restores
    -- floating_geometry and reassigns screen. layout.arrange() is queued
    -- via delayed_call by the layout module (registered before us).
    -- Our delayed_call fires AFTER both, so c:geometry() returns the
    -- final, screen-corrected position.
    --
    -- Guards:
    -- - Skip implicit floating from maximize/fullscreen (those have their
    --   own animation paths via property::maximized/fullscreen).
    -- - Generation counter prevents stale callbacks from rapid toggling.
    -- - Target geo is clamped to screen workarea to prevent cross-screen fly.
    -- - Uses _set_geometry_silent when client ends up tiled (float→tiled).
    client.connect_signal("property::floating", function(c)
        if not c.valid then return end
        if not is_enabled("float") then return end
        if not c.screen then return end

        -- Skip implicit floating changes from maximize/fullscreen
        if c.maximized or c.fullscreen
                or c.maximized_horizontal or c.maximized_vertical then
            return
        end

        if not is_tiling_layout(c.screen) then return end

        local s = get(c)
        if s.geo_animating then return end
        local from = c:geometry()
        local orig_screen = c.screen

        -- Generation token: rapid toggles only animate the latest
        local seq = (s.float_seq or 0) + 1
        s.float_seq = seq

        gears.timer.delayed_call(function()
            if not c.valid then return end
            if s.geo_animating then return end
            if s.float_seq ~= seq then return end

            local to = c:geometry()
            local scr = orig_screen.valid and orig_screen or c.screen

            -- Clamp target to screen workarea (prevents cross-screen fly
            -- when floating_geometry has stale coordinates from another screen)
            local clamped = false
            if scr and scr.valid then
                local wa = scr.workarea
                local clamped_x = math.max(wa.x, math.min(to.x, wa.x + math.max(0, wa.width - to.width)))
                local clamped_y = math.max(wa.y, math.min(to.y, wa.y + math.max(0, wa.height - to.height)))
                if clamped_x ~= to.x or clamped_y ~= to.y then
                    to = {
                        x      = clamped_x,
                        y      = clamped_y,
                        width  = to.width,
                        height = to.height,
                    }
                    clamped = true
                end
            end

            local d = math.abs(from.x - to.x) + math.abs(from.y - to.y)
                + math.abs(from.width - to.width) + math.abs(from.height - to.height)
            local is_floating = awful.client.object.get_floating(c)
            if d >= 20 then
                -- Use silent geometry for tiled clients (float→tiled)
                -- to avoid layout.arrange thrashing on every frame
                animate_geo(c, from, to, "float", not is_floating)
            elseif clamped then
                -- Delta too small to animate, but geo was off-screen — snap it
                if is_floating then
                    c:geometry(to)
                else
                    c:_set_geometry_silent(to)
                    -- Silent snap: update cache manually (same as animate_geo)
                    if not c.maximized and not c.fullscreen then
                        s.normal_geo = to
                    else
                        s.max_geo = to
                    end
                end
            end
        end)
    end)

    -- =====================================================================
    -- Layer surface animations (rofi, launchers, etc.)
    -- =====================================================================

    -- FadeIn: layer surface appears
    layer_surface.connect_signal("request::manage", function(ls)
        if not ls.valid then return end
        if not is_enabled("layer") then return end
        -- Skip panels/bars that reserve screen space (waybar, wibar, etc.)
        if (ls.exclusive_zone or 0) > 0 then return end

        local dur = cfg("layer", "duration")
        local ease = cfg("layer", "easing")
        if dur <= 0 then return end

        local s = get(ls)
        s.fading = true
        ls.opacity = 0

        s.fade_handle = awesome.start_animation(dur, ease,
            function(t)
                if not ls.valid then cancel(ls, "fade"); return end
                ls.opacity = t
            end,
            function()
                s.fading = false
                s.fade_handle = nil
                if ls.valid then ls.opacity = 1 end
            end)
    end)

    -- Cleanup layer surface state
    layer_surface.connect_signal("request::unmanage", function(ls)
        cancel(ls, "fade")
        cstate[ls] = nil
    end)
end

return anim_client
