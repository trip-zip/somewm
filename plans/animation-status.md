# Animation System Status

**Branch:** `feat/unified-animations`
**Base:** `feat/client-animations`
**Module:** `lua/awful/anim_client.lua` (672 lines with uncommitted changes)
**Date:** 2026-03-27

---

## Commit History

### feat/client-animations (6 commits from main)

| Hash    | Description |
|---------|-------------|
| 536b2e4 | Initial module: maximize, fullscreen, fadeIn, minimize, restore |
| e83cf6e | Declarative config system with deep merge and theme overrides |
| 9414762 | docs: example rc.lua config with all defaults |
| 6ffd212 | Layer surface fadeIn (rofi) + dialog fadeIn (transient windows) |
| 9eb1a75 | Swap animation rewrite (screen::arrange), float toggle, LyrFloat, LyrFS unconditional |
| 2ae3d09 | docs: unified-animations plan |

### feat/unified-animations (no additional commits yet)

The current branch has **uncommitted work in progress** on top of feat/client-animations:

- `layout` config section added to defaults
- `swap` duration changed from 0.3s → 0.25s
- `geos_differ()` helper extracted (per-axis 2px threshold, replacing manhattan d<20)
- `lerp_geo()` helper extracted (shared by swap and layout)
- `swap_settled` renamed to `layout_settled`
- `swap_visual` renamed to `layout_visual`
- Universal arrange handler replaces swap-only handler:
  - ALL tiled clients animated on every arrange (not just swap_pending)
  - `swap_pending` flag selects "swap" config; otherwise uses "layout" config
  - `start_layout_animation()` extracted as shared helper
- rc.lua updated with `layout` config section

This implements Steps 1–8 from `plans/unified-animations.md` in full.

---

## Animation Features — Committed State

### 1. Maximize / Restore Geometry  — WORKING
- Triggered by `property::maximized` signal
- Saves `normal_geo` before maximize, `max_geo` after
- Animates from saved position to current layout-assigned geometry
- Uses `c:geometry()` (not silent) since maximize is not a tiled position
- Default: 0.25s, ease-out-cubic

### 2. Fullscreen / Restore Geometry — WORKING
- Identical architecture to maximize
- Triggered by `property::fullscreen`
- C change (commit 9eb1a75): fullscreen clients unconditionally placed in `LyrFS`
  regardless of focus; previously they could be in `LyrFloat`
- Default: 0.25s, ease-out-cubic

### 3. FadeIn on New Client (request::manage) — WORKING
- All new clients start at opacity=0, animate to 1
- Transient windows and dialogs use "dialog" config (shorter, 0.2s by default)
- Normal windows use "fade" config (0.4s by default)
- Detection: `c.transient_for ~= nil or c.type == "dialog"`

### 4. FadeOut on Minimize — WORKING (requires keybinding change)
- NOT automatic: requires calling `anim_client.fade_minimize(c)` from the Super+N keybinding
- Standard `c.minimized = true` does NOT animate — animation only happens via the API
- Hides border during fadeOut (border_width = 0, wlr_scene_rect has no alpha)
- After animation completes: opacity reset to 1, then `c.minimized = true`
- Default: 0.4s, ease-out-cubic

### 5. FadeIn on Restore from Minimize — WORKING
- Triggered by `property::minimized` when `c.minimized` becomes false
- Restores `border_width` (set to 0 by fade_minimize) before fading
- Animates from opacity=0 to 1 using "fade" config
- Default: 0.4s, ease-out-cubic

### 6. Dialog FadeIn (transient windows) — WORKING
- Same signal path as normal FadeIn (request::manage)
- Separate "dialog" config section allows different duration/easing
- Default: 0.3s (rc.lua overrides to 0.2s), ease-out-cubic

### 7. Layer Surface FadeIn (rofi, launchers) — WORKING
- Triggered by `layer_surface::request::manage`
- Skips panels/bars that reserve screen space (`exclusive_zone > 0`)
- C changes in `objects/layer_surface.c`: opacity field, per-buffer scene tree traversal
- Opacity re-applied in `commitlayersurfacenotify` and `rendermon` to counter
  wlroots resetting buffer opacity on each commit
- Default: 0.35s (rc.lua overrides to 0.2s), ease-out-cubic

### 8. Swap Animation (Super+Shift+J/K) — WORKING
- Two-phase: `swapped` signal → `screen::arrange` signal
- Phase 1 (`swapped`): flags both clients as `swap_pending`, cancels running animations
  (preserves `layout_visual` mid-point for chaining)
- Phase 2 (`arrange`): snaps clients to old visual position, animates to new target
- Only fires in classic tiling layouts (whitelist: tile, tileleft, fairv, spiral, etc.)
- Mouse drag guard: skips if `mousegrabber.isrunning()`
- Mid-animation chaining: rapid key repeat chains from current visual position
- Default: 0.25s, ease-out-cubic

### 9. Float Toggle Animation (Ctrl+Super+Space) — WORKING
- Triggered by `property::floating`, deferred via `gears.timer.delayed_call`
- Captures geometry BEFORE float state change, reads final position AFTER
  `set_floating()` and `layout.arrange()` have both completed
- float→tiled uses `_set_geometry_silent` to avoid layout thrashing
- tiled→float uses `c:geometry()` (floating client, normal geometry call)
- Screen workarea clamping: prevents cross-screen fly when `floating_geometry`
  has stale coordinates from another screen
- Generation counter: rapid toggles only animate the latest
- Guards: skips if maximize/fullscreen implicit floating, skips if `geo_animating`
- Only fires in classic tiling layouts (same whitelist as swap)
- Default: 0.3s, ease-out-cubic

### 10. Layout Animation (mwfact, spawn/kill, layout switch) — WORKING (uncommitted)
- Universal `screen::arrange` handler animates ALL tiled clients on position change
- Uses "layout" config (0.15s) for background reflows vs "swap" config (0.25s) for user swaps
- `geos_differ()` per-axis threshold (>= 2px any axis) replaces manhattan d<20
- Shared `start_layout_animation()` helper used by both swap and layout paths
- Status: fully implemented in working tree, not yet committed

---

## Architecture Decisions

### screen::arrange signal vs delayed_call

The swap animation was originally implemented with `delayed_call` to defer geometry
reads until after `layout.arrange()` had run. This created a FIFO race: both our
callback and `layout.arrange()` were queued, so `_set_geometry_silent(from)` competed
with `c:geometry(target)` from layout. The fix (commit 9eb1a75) replaced this with
`screen::arrange`, which fires synchronously AFTER `layout.arrange` has committed all
positions. The arrange handler sees final geometry immediately without any queuing race.

### Two-phase swap (swapped signal + arrange)

The `swapped` signal fires before layout runs; `screen::arrange` fires after.
Phase 1 (swapped): cancel running animations, flag clients as `swap_pending`, preserve
mid-animation `layout_visual` for chaining. Phase 2 (arrange): read final positions,
snap back to old visual, start animation. This clean separation means the animation
always starts from the accurate mid-point even during rapid key repeat.

### Universal arrange handler

The unified handler processes ALL tiled clients on every arrange, not just
`swap_pending` ones. Animation type selection is based on context: `swap_pending` flag
→ "swap" config; otherwise → "layout" config. This subsumes Jimmy's upstream
`layout_animation.lua` (which animates everything with one duration) and adds
per-type config, mid-animation chaining, and integration guards.

**Important:** `somewm.layout_animation` must NOT be loaded alongside this module.
Both write `_set_geometry_silent()` on tiled clients and will conflict.

### _set_geometry_silent vs c:geometry()

Tiled client animations use `c:_set_geometry_silent()` to suppress
`property::geometry` signals on every frame. Without this, each animation frame
triggers `layout.arrange()`, creating feedback loops and thrashing. Floating client
animations (maximize, fullscreen, float→floating) use `c:geometry()` normally since
they are not managed by the tiling layout.

### Re-snap guard

The arrange handler includes a re-snap guard: if a layout target is unchanged
(same `prev_settled` vs `new_geo`) and an animation is already running, the client
is snapped back to its `layout_visual` position. This counteracts layout's non-silent
`c:geometry()` call which would otherwise reset the visual position mid-animation.
The guard compares `prev_settled` (the previous layout target) against `new_geo`
(the new layout target), not the visual mid-point — otherwise the guard would almost
never fire.

### Per-type config with theme overrides

Configuration priority (most specific wins):
1. `beautiful.anim_<type>_<param>` — theme variable, read at call time
2. Table passed to `enable({...})` — user config, merged at startup
3. Module defaults — hardcoded fallback

Nine independently configurable animation types: `maximize`, `fullscreen`, `fade`,
`minimize`, `layer`, `dialog`, `swap`, `float`, `layout`.

### Floating z-order (LyrFloat)

Commit 9eb1a75 added a dedicated `WINDOW_LAYER_FLOATING` scene layer between
`LyrTile` and `LyrWibox`. Floating clients are placed here instead of `LyrFloat`
(which is for wlroots internal use). The `floating` bool in `client_t` is synced
from Lua via `_c_floating` property on `property::floating` signal. Transient dialogs
are stacked with their parent (checked before floating in `get_window_layer()`).

---

## Known Bugs and Limitations

### Overlap during swap animation (linear interpolation)
During a swap between two adjacent tiled windows, both slide in opposite directions
using linear interpolation. At t=0.5 their paths cross and they visually overlap.
Arc/curve paths would eliminate this but are not implemented. The overlap is brief
and less noticeable with shorter durations.

### One-frame flicker on cancel+restart
When a running geometry animation is cancelled and a new one starts from the same
position, there is a one-frame flash. The cancel stops the animation at the current
visual position, then `_set_geometry_silent(old_geo)` sets it back to the snap-back
position before the new animation starts. The compositor renders one frame at the
snap-back position before the animation begins. This is a C-level timing issue
(no sub-frame defer mechanism exists).

### Float toggle skipped if layout animation running
The `property::floating` handler returns early if `s.geo_animating` is true.
If a layout animation is in progress when the user hits Ctrl+Super+Space, the float
toggle gets no animation. The `geo_animating` flag is shared between all geometry
animation types.

### First arrange does not animate (warm-up needed)
On the first `screen::arrange` for each client, `layout_settled[c]` is nil (no
previous position recorded). The arrange handler skips animation and just records
the position. This means the very first arrange after a client appears — including
initial placement when spawned — does not animate. Subsequent arranges animate
normally. This is intentional (there is no meaningful "from" position for the first
arrange).

### FadeOut on minimize only via API
Standard `c.minimized = true` does NOT fade out. The keybinding must call
`anim_client.fade_minimize(c)` instead. If any other code path minimizes a client
(rules, scripts, external tools), there is no fadeOut. This is a design limitation
of the current approach (signal-based fadeOut would require intercepting the minimize
request before it executes).

### Border hidden during fadeOut
`fade_minimize()` sets `border_width = 0` before the fadeOut and restores it on
restore. This is a workaround for `wlr_scene_rect` not supporting alpha. If the
compositor crashes or is killed mid-fadeOut, the border width may not be restored.
The `property::minimized` restore handler does restore it, but only on the next
unminimize.

### Layout animation not yet committed
The `layout` animation type (mwfact, spawn/kill, layout switch) is fully implemented
in the working tree but not yet committed to the branch. The uncommitted diff also
includes `geos_differ()` and `lerp_geo()` helper extraction and the rename from
`swap_visual`/`swap_settled` to `layout_visual`/`layout_settled`.

---

## Not Implemented / Future Work

### FadeOut on close
When a client is killed (`c:kill()`) there is no fadeOut animation. The client
disappears immediately. Implementing this requires holding the surface alive after
`request::unmanage` fires — non-trivial in wlroots because the surface is destroyed
by the client. Would require `destroy_on_unmanage = false` semantics or a snapshot.

### Arc/curve paths for swap
Swap animation uses linear interpolation, causing clients to overlap at the midpoint.
True arc paths (quarter-circle or bezier) would route each client around the other,
eliminating the overlap. Not implemented.

### FadeOut for layer surfaces (rofi close)
Layer surfaces get fadeIn but not fadeOut. Implementing fadeOut requires the same
surface-lifetime workaround as client close fadeOut.

### Stagger on layout switch
When switching layouts (Super+Space), all clients animate simultaneously. A stagger
(each client delayed by N ms from the previous) would look more polished. Not
implemented.

### Per-client animation disable
No mechanism to disable animations for specific clients (e.g., video players,
terminals with custom opacity). Could be implemented via a client property or rule.

### Easing functions
Only one easing function is currently available from the C side (`ease-out-cubic`).
Additional easings (ease-in, bounce, elastic) would require C additions to
`awesome.start_animation`. Not implemented.

### Layout animation for non-tiling layouts
The tiling layout whitelist explicitly excludes carousel, machi, max, and floating
layouts. These get no animation at all. A separate mechanism for max-layout transitions
(e.g., tab switching) would need different logic.

---

## C Changes Summary

These C changes are on feat/client-animations and carry forward to feat/unified-animations:

| File | Change | Commit |
|------|--------|--------|
| `objects/client.c` | `client_apply_opacity_to_scene` applies opacity to shadow tree | 536b2e4 |
| `objects/client.c` | Border opacity via `wlr_scene_rect` alpha channel | 536b2e4 |
| `objects/layer_surface.c` | Opacity field + per-buffer scene traversal | 6ffd212 |
| `objects/layer_surface.h` | `opacity` field in `LayerSurface` struct | 6ffd212 |
| `somewm.c` | `commitlayersurfacenotify` + `rendermon` opacity re-apply | 6ffd212 |
| `somewm.c` | `commitpopup` opacity inheritance for layer+client popups | 6ffd212 |
| `objects/client.c` | `floating` bool in `client_t`, synced from Lua `_c_floating` | 9eb1a75 |
| `objects/client.h` | `floating` field declaration | 9eb1a75 |
| `lua/awful/client.lua` | `_c_floating` property set on `property::floating` signal | 9eb1a75 |
| `stack.c` | `WINDOW_LAYER_FLOATING` layer + `get_window_layer()` updates | 9eb1a75 |
| `stack.h` | `WINDOW_LAYER_FLOATING` enum value | 9eb1a75 |

No new C changes are needed for the uncommitted `layout` animation work.

---

## Files

| File | Role |
|------|------|
| `lua/awful/anim_client.lua` | Primary module (673 lines committed, ~865 with WIP) |
| `plans/somewm-one/anim_client.lua` | Deploy copy (kept in sync) |
| `plans/somewm-one/rc.lua` | Config example + `anim_client.enable({...})` call |
| `plans/unified-animations.md` | Implementation plan for this branch |
