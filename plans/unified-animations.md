# Plan: Unified Animation System (feat/unified-animations)

## Goal

Merge Jimmy's universal `layout_animation.lua` approach (screen::arrange for ALL
tiling transitions) with our `anim_client.lua` features (fade, opacity, maximize,
fullscreen, per-type config, theme overrides) into a single coherent module.

## Branch

Create from: `feat/client-animations` (current work)
Branch name: `feat/unified-animations`

## Current State

### Jimmy's `layout_animation.lua` (upstream PR #362, merged)
- 187 lines, `lua/somewm/layout_animation.lua`
- Single `screen::arrange` handler animates ALL tiled clients
- Covers: swap, mwfact, spawn/kill, layout switch, column count
- Config: 3 global vars (duration=0.15, easing, enabled)
- NOT loaded in our rc.lua (would conflict with anim_client)

### Our `anim_client.lua` (feat/client-animations)
- 640 lines, `lua/awful/anim_client.lua`
- 8 animation types: maximize, fullscreen, fade, minimize, layer, dialog, swap, float
- Swap: screen::arrange handler (today's fix) but ONLY for swap_pending clients
- Config: declarative table + beautiful.anim_* theme overrides
- C changes: floating field, LyrFloat, unconditional LyrFS

### Gaps in Jimmy's module
1. `stop_animation()` clears `visual_geo` — loses mid-point on rapid chains
2. No tiling layout whitelist (animates in max, floating, machi too)
3. Animates ALL clients on every arrange (no per-trigger control)
4. Single duration/easing for everything
5. No integration guard with other animation types (maximize, fade)

### Gaps in our module
1. Only swap + float toggle animated — mwfact, spawn, kill, layout switch snap instantly
2. Only swap_pending clients animated — bystander clients that move due to layout
   recomputation are NOT animated (e.g., A moves because B swapped with C)
3. Manhattan distance threshold (d < 20) is coarser than Jimmy's per-axis (>= 2px)

## Implementation Plan

### Step 1: Add "layout" animation type to config

```lua
defaults = {
    ...existing types...
    layout = {
        enabled  = true,
        duration = 0.15,   -- shorter than swap (0.3) — layout changes should be quick
        easing   = "ease-out-cubic",
    },
}
```

This covers: mwfact changes, client spawn/kill reflow, layout switch, column count.

### Step 2: Replace swap-only arrange handler with universal handler

Current: arrange handler only processes `swap_pending` clients.
New: arrange handler processes ALL tiled clients (like Jimmy's), but selects
the animation type based on context:

```lua
screen.connect_signal("arrange", function(s)
    if mousegrabber.isrunning() then return end
    if not is_tiling_layout(s) then return end   -- NEW: layout whitelist

    local tiled = s.tiled_clients
    if not tiled then return end

    for _, c in ipairs(tiled) do
        local st = get(c)
        local new_geo = c:geometry()
        local old_geo = st.swap_visual or layout_settled[c]

        layout_settled[c] = new_geo

        -- Determine animation type and whether to animate
        local anim_type
        if st.swap_pending then
            st.swap_pending = false
            anim_type = "swap"
        elseif st.float_pending then
            -- float toggle handled separately (different from/to logic)
            goto continue
        else
            anim_type = "layout"
        end

        if not is_enabled(anim_type) then
            st.swap_visual = nil
            goto continue
        end

        -- Skip if another animation type owns this client (maximize, fullscreen)
        if st.geo_animating and not st.swap_visual then
            goto continue
        end

        -- Re-snap: target unchanged, animation running → keep visual pos
        if st.geo_animating and st.swap_visual and old_geo
                and not geos_differ(old_geo, new_geo) then
            c:_set_geometry_silent(st.swap_visual)
            goto continue
        end

        if not old_geo then goto continue end

        -- Threshold check (use per-axis like Jimmy: >= 2px any axis)
        if not geos_differ(old_geo, new_geo) then
            stop_layout_anim(st)
            goto continue
        end

        -- Cancel + snap back + animate
        cancel(c, "geo")
        c:_set_geometry_silent(old_geo)

        local from = old_geo
        local to = new_geo
        local dur = cfg(anim_type, "duration")
        local ease = cfg(anim_type, "easing")

        start_geo_animation(c, st, from, to, dur, ease)

        ::continue::
    end
end)
```

### Step 3: Adopt Jimmy's `geos_differ` threshold

Replace our `d < 20` manhattan check with per-axis `>= 2px`:

```lua
local function geos_differ(a, b)
    return math.abs(a.x - b.x) >= 2
        or math.abs(a.y - b.y) >= 2
        or math.abs(a.width - b.width) >= 2
        or math.abs(a.height - b.height) >= 2
end
```

### Step 4: Fix visual_geo preservation on cancel

Jimmy's `stop_animation()` clears `visual_geo` immediately. Our approach is better:
keep `swap_visual` alive after cancel so the arrange handler can chain from
the actual mid-animation position. Only clear it in the `else` branch (no
pending, no animating).

### Step 5: Extract shared `start_geo_animation` helper

Both swap and layout transitions use the same pattern:
snap back → start_animation → tick with _set_geometry_silent → done callback.

Extract into a shared function:

```lua
local function start_geo_animation(c, st, from, to, dur, ease)
    if dur <= 0 then
        c:_set_geometry_silent(to)
        st.swap_visual = nil
        return
    end
    st.geo_animating = true
    st.swap_visual = from
    st.geo_handle = awesome.start_animation(dur, ease,
        function(t)
            if not c.valid then cancel(c, "geo"); return end
            local g = lerp_geo(from, to, t)
            st.swap_visual = g
            c:_set_geometry_silent(g)
            st.geo_animating = true
        end,
        function()
            st.geo_animating = false
            st.geo_handle = nil
            st.swap_visual = nil
            if c.valid then c:_set_geometry_silent(to) end
        end)
end
```

### Step 6: Guard against maximize/fullscreen conflicts

The arrange handler must skip clients currently in a maximize/fullscreen
geo animation. Check:

```lua
-- Skip if maximize/fullscreen animation owns this client
if st.geo_animating and not st.swap_visual then
    goto continue
end
```

The key: `swap_visual ~= nil` means layout/swap animation owns the client.
`swap_visual == nil and geo_animating` means maximize/fullscreen owns it.

### Step 7: Rename `swap_visual` → `layout_visual`

Since it now tracks ALL layout transitions (not just swap), rename for clarity:
- `swap_visual` → `layout_visual`
- `swap_settled` → `layout_settled`
- `swap_pending` → keep (only swaps set this flag)

### Step 8: Update rc.lua config

```lua
require("anim_client").enable({
    enabled = true,
    ...existing types...
    layout = {
        enabled  = true,        -- animate mwfact, spawn/kill reflow, layout switch
        duration = 0.15,        -- short — layout changes should feel responsive
        easing   = "ease-out-cubic",
    },
    swap = {
        enabled  = true,        -- tiling swap (Super+Shift+J/K)
        duration = 0.3,         -- longer — user-initiated, should be visible
        easing   = "ease-out-cubic",
    },
})
```

### Step 9: Consider disabling upstream layout_animation

Since our unified module subsumes it, ensure `layout_animation.lua` is NOT
loaded. Add a comment in rc.lua:

```lua
-- NOTE: Do NOT require("somewm.layout_animation") — our anim_client
-- handles all layout transitions with per-type config. Both modules
-- write _set_geometry_silent() on tiled clients and would conflict.
```

## Testing

1. **Swap** (Super+Shift+J/K): smooth animation, 0.3s
2. **Rapid swap**: chain smoothly from mid-point, no overlap
3. **mwfact change** (Super+L/H): all tiled clients animate, 0.15s
4. **Spawn new client**: existing clients animate to new positions
5. **Kill client**: remaining clients animate to fill gap
6. **Layout switch** (Super+Space): all clients animate to new layout
7. **Mouse drag**: no animation (mousegrabber guard)
8. **Max/floating/machi layout**: no tiling animation (whitelist guard)
9. **Maximize during swap animation**: no conflict
10. **FadeIn + layout reflow**: fade and layout animate independently

## Files to modify

- `lua/awful/anim_client.lua` — main changes (arrange handler, config, helpers)
- `plans/somewm-one/anim_client.lua` — sync copy
- `plans/somewm-one/rc.lua` — add layout config section

## Risk

Low — purely Lua changes. No new C modifications needed. The universal arrange
handler is a superset of the current swap-only handler + Jimmy's approach.
Worst case: disable `layout.enabled = false` to fall back to current behavior.

## Upstream PR potential

This module could be proposed as upstream PR to replace both:
- `somewm.layout_animation` (Jimmy's, limited)
- Nothing (no fade/opacity/maximize upstream)

Caveat: upstream rule is "Lua libraries are not modified — if a bug surfaces
in Lua, the fix belongs in C" (from PR #362 checklist). Our module lives in
`lua/awful/` which IS the Lua library. May need to move to `lua/somewm/`
namespace or get an exception. The C changes (LyrFloat, floating field, LyrFS)
would need separate PRs.
