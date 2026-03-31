# Tag Slide Animation (KDE-style Desktop Slide)

## Overview

Horizontal slide animation for tag switching (Super+Left/Right). Clients and
wallpaper slide in/out like KDE's Desktop Slide effect. Wibar stays stationary.
Per-tag wallpapers are supported via the preload cache.

## Architecture (3 layers)

### 1. C Layer (upstream changes)

| File | Change | Lines |
|------|--------|-------|
| `root.c` | 4 new Lua-callable functions: `root.wp_snapshot()`, `root.wp_snapshot_path()`, `root.wp_overlay_move()`, `root.wp_overlay_destroy()` — wallpaper overlay helpers placed in LyrBottom layer. Also added `{fit="contain"\|"cover"}` scaling parameter for cache preload | +200 |
| `luaa.c` | Removed old wp_overlay code (moved to root.c). Only `awesome._client_scene_set_enabled()` remains (~15 lines) | -180 |
| `animation.c` | Bugfix: absolute `start_time` instead of cumulative dt (fixes 95% animation skip on first frame) | ~10 |
| `animation.h` | +1 field `double start_time` | +1 |
| `globalconf.h` | +1 declaration `wallpaper_cache_lookup()` (was extern hack in luaa.c) | +1 |

### 2. Lua Module (upstream — somewm feature)

| File | Purpose |
|------|---------|
| `lua/somewm/tag_slide.lua` | Main module. Wraps `awful.tag.viewidx`, snapshots old clients/wallpaper before switch, executes tag change, animates horizontal slide. Filters shared clients (multi-tag + sticky). Config pattern matches anim_client: `enable({duration, easing, wallpaper})` + `beautiful.tag_slide_*` theme override |
| `lua/somewm/init.lua` | Registration: `tag_slide = "somewm.tag_slide"` |
| `lua/awful/anim_client.lua` | +1 line guard: `if _tag_slide_active then return end` — suppresses layout animations during slide |

### 3. User Configuration (somewm-one, NOT upstream)

| File | What it configures |
|------|-------------------|
| `plans/somewm-one/rc.lua` | `s._wppath` = wallpaper directory path, `root.wallpaper_cache_preload()` at startup, `require("somewm.tag_slide").enable({...})` |

## Animation Sequence

```
Super+Right -> animated_viewidx(+1)
  1. snap_clients()              -- save old client positions
  2. root.wp_snapshot(s)         -- overlay of old wallpaper in LyrBottom
  3. root.wp_snapshot_path(path) -- overlay of new WP (from preload cache)
  4. orig_viewidx(i, s)         -- real tag switch (layout + set_wallpaper runs)
  5. snap_clients()              -- new client positions (post-layout)
  6. Filter shared clients       -- multi-tag clients excluded from animation
  7. start_animation -> tick:
       old clients + old WP slide OUT (left for viewnext, right for viewprev)
       new clients + new WP slide IN  (from opposite direction)
  8. completion -> cleanup overlays, restore geometry, scene_set_enabled(false)
```

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Tag slide vs anim_client | Separate module | Different architecture (viewidx wrapper vs reactive signals) |
| Config format | Same as anim_client | `enable({duration, easing, wallpaper={...}})` + `beautiful.*` override |
| C helpers location | `root.c` | Shares `wallpaper_cache_entry_t`, `layers[]`, no extern hacks |
| Lua API namespace | `root.wp_*` | Consistent with `root.wallpaper_cache_*` |
| `_client_scene_set_enabled` | Stays in `luaa.c` as `awesome.*` | Client function, not wallpaper |
| Overlay layer | LyrBottom (not LyrBg) | `awful.wallpaper`'s deferred paint creates new nodes in LyrBg that would cover overlays |
| Shared client handling | Excluded from both snap lists | Multi-tag and sticky clients stay in place during animation |
| Scaling mode | Configurable `{fit="contain"\|"cover"}` | rc.lua uses contain (imagebox centered), cache must match |

## Configuration

```lua
-- In rc.lua (after anim_client.enable):
require("somewm.tag_slide").enable({
    duration  = 0.25,            -- seconds
    easing    = "ease-out-cubic", -- any easing from animation.c
    wallpaper = { enabled = true },
})
```

Theme overrides (highest priority):
- `beautiful.tag_slide_duration`
- `beautiful.tag_slide_easing`
- `beautiful.tag_slide_wallpaper_enabled`

## Upstream Impact

- Minimal. C changes are 4 isolated Lua-callable functions in `root.c` + 1 bugfix in `animation.c`
- No changes to core compositor code (somewm.c, client.c)
- Module is opt-in — without `enable()` nothing happens
- Graceful degradation: if C helpers missing, animation runs without wallpaper overlays

## Upstream PR Strategy

1. **PR 1: `fix: animation timing — use absolute start_time`**
   - Just animation.c + animation.h (18 lines)
   - Standalone bugfix, no dependencies

2. **PR 2: `fix: wallpaper cache preload at rc.lua load time`**
   - root.c: screen_t parameter + scaling mode
   - globalconf.h: lookup declaration
   - Standalone fix for existing cache API

3. **PR 3: `feat: KDE-style tag slide animation`**
   - root.c: wp_overlay C helpers
   - lua/somewm/tag_slide.lua: animation module
   - lua/somewm/init.lua: registration
   - lua/awful/anim_client.lua: suppress guard
   - tests/test-tag-slide.lua
   - Depends on PR 1 + PR 2

## Testing

Sandbox test results (nested compositor, `WLR_BACKENDS=wayland`):
- Module load + enable/disable cycle: OK
- All 5 C helpers available (`root.wp_*` + `awesome._client_scene_set_enabled`)
- viewnext/viewprev with clients on both tags: correct direction
- Multi-tag shared clients: stay visible, not animated
- Sticky clients: excluded from animation, stay visible
- Rapid switching (cancel/snap): correct final positions
- No ASAN errors, segfaults, or assertion failures
