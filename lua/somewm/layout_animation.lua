---------------------------------------------------------------------------
--- Animated layout transitions for tiled clients.
--
-- Hooks into `screen::arrange` (fired after `layout.arrange()` applies new
-- geometries) and smoothly animates each tiled client from its previous
-- position to the new one. This covers all arrange triggers: mwfact changes,
-- client spawn/kill, layout switches, column count changes, etc.
--
-- Animation is skipped when:
-- - The module is disabled
-- - A mousegrabber is active (direct manipulation should feel immediate)
-- - The geometry delta is negligible (< 2px on all axes)
-- - The client has not been arranged before (first appear, no old position)
--
-- Usage in rc.lua:
--     local layout_anim = require("somewm.layout_animation")
--     layout_anim.duration = 0.15
--     layout_anim.easing   = "ease-out-cubic"
--     layout_anim.enabled  = true   -- default
--
-- @module somewm.layout_animation
---------------------------------------------------------------------------

local capi = {
    awesome      = awesome,
    screen       = screen,
    mousegrabber = mousegrabber,
}

local layout_animation = {}

--- Animation duration in seconds.
-- @tfield number duration
layout_animation.duration = 0.15

--- Easing function name passed to `awesome.start_animation`.
-- @tfield string easing
layout_animation.easing = "ease-out-cubic"

--- Master switch. When false, layout changes snap instantly.
-- @tfield boolean enabled
layout_animation.enabled = true

-- Per-client animation state. Weak keys so clients can be collected.
local client_state = setmetatable({}, { __mode = "k" })

--- Get or create animation state for a client.
-- @tparam client c
-- @treturn table State table with settled_geo, visual_geo, anim_handle
local function get_state(c)
    local s = client_state[c]
    if not s then
        s = {
            settled_geo = nil,  -- target geometry from last completed arrange
            visual_geo  = nil,  -- current interpolated position (nil when idle)
            anim_handle = nil,  -- current animation handle (nil when idle)
        }
        client_state[c] = s
    end
    return s
end

--- Cancel any running animation for a client.
-- @tparam table state Client animation state
local function stop_animation(state)
    if state.anim_handle then
        state.anim_handle:cancel()
        state.anim_handle = nil
        state.visual_geo = nil
    end
end

--- Check if two geometries differ by more than a negligible threshold.
-- @tparam table a Geometry {x, y, width, height}
-- @tparam table b Geometry {x, y, width, height}
-- @treturn boolean True if any field differs by >= 2
local function geos_differ(a, b)
    return math.abs(a.x - b.x) >= 2
        or math.abs(a.y - b.y) >= 2
        or math.abs(a.width - b.width) >= 2
        or math.abs(a.height - b.height) >= 2
end

--- Interpolate between two geometries.
-- @tparam table from Start geometry
-- @tparam table to End geometry
-- @tparam number progress Easing progress (0..1)
-- @treturn table Interpolated geometry with integer values, width/height >= 1
local function lerp_geo(from, to, progress)
    return {
        x = math.floor(from.x + (to.x - from.x) * progress + 0.5),
        y = math.floor(from.y + (to.y - from.y) * progress + 0.5),
        width = math.max(1, math.floor(
            from.width + (to.width - from.width) * progress + 0.5)),
        height = math.max(1, math.floor(
            from.height + (to.height - from.height) * progress + 0.5)),
    }
end

---------------------------------------------------------------------------
-- Signal handler
---------------------------------------------------------------------------

capi.screen.connect_signal("arrange", function(s)
    local tiled = s.tiled_clients
    if not tiled then return end

    local enabled = layout_animation.enabled
    local grabbing = capi.mousegrabber.isrunning()

    for _, c in ipairs(tiled) do
        local state = get_state(c)
        local new_geo = c:geometry()
        local prev_target = state.settled_geo
        state.settled_geo = new_geo

        -- When disabled or mouse is dragging: snap, no animation
        if not enabled or grabbing then
            stop_animation(state)
            state.visual_geo = nil
            goto continue
        end

        -- Target unchanged and animation already running: re-snap to
        -- current visual position (counteracts the non-silent
        -- c:geometry(target) that triggered this arrange) and skip.
        if state.anim_handle and prev_target
                and not geos_differ(prev_target, new_geo) then
            if state.visual_geo then
                c:_set_geometry_silent(state.visual_geo)
            end
            goto continue
        end

        -- Current visual position: mid-animation or last settled
        local old_geo = state.visual_geo or prev_target

        -- First arrange for this client: no old position, skip animation
        if not old_geo then
            goto continue
        end

        -- Skip if delta is negligible
        if not geos_differ(old_geo, new_geo) then
            stop_animation(state)
            state.visual_geo = nil
            goto continue
        end

        -- Cancel any running animation
        stop_animation(state)

        -- Snap back to old visual position (before compositor renders)
        c:_set_geometry_silent(old_geo)

        -- Animate toward new target
        local from = old_geo
        local target = new_geo
        local duration = layout_animation.duration

        if duration <= 0 then
            c:_set_geometry_silent(target)
            state.visual_geo = nil
            goto continue
        end

        state.anim_handle = capi.awesome.start_animation(
            duration, layout_animation.easing,
            function(progress)
                if not c.valid then return end
                local g = lerp_geo(from, target, progress)
                state.visual_geo = g
                c:_set_geometry_silent(g)
            end,
            function()
                if c.valid then
                    c:_set_geometry_silent(target)
                end
                state.visual_geo = nil
                state.anim_handle = nil
            end)

        ::continue::
    end
end)

return layout_animation
