# SceneFX Integration for somewm

## Context

somewm lacks modern compositor effects (rounded corners, GPU shadows, background blur).
SwayFX achieves these via **scenefx** (github.com/wlrfx/scenefx) — a drop-in replacement
for the wlroots scene renderer that adds GLES2 shader-based effects while maintaining
full API compatibility. scenefx 0.4 targets wlroots 0.19, which somewm already uses.

This is a compile-time optional feature (`-Dscenefx=auto`). Without scenefx, somewm
builds and behaves exactly as before.

## Phase 1: Build Integration — Low complexity (~30 min)

### 1.1 meson_options.txt — add option
```
option('scenefx', type: 'feature', value: 'auto',
       description: 'Enable scenefx visual effects (rounded corners, shadows, blur)')
```

### 1.2 subprojects/scenefx.wrap — subproject fallback
```ini
[wrap-git]
url = https://github.com/wlrfx/scenefx.git
revision = 0.4
depth = 1
[provide]
dependency_names = scenefx-0.4
```

### 1.3 meson.build changes
- After wlroots block (line ~146): detect scenefx dependency with subproject fallback
- After PAM block (line ~262): `add_project_arguments('-DHAVE_SCENEFX')`
- In all_deps (line ~366): `if have_scenefx: all_deps += [scenefx]`
- In summary (line ~472): `'SceneFX': have_scenefx`

### 1.4 scenefx_compat.h — new conditional include header
```c
#ifndef SCENEFX_COMPAT_H
#define SCENEFX_COMPAT_H

#ifdef HAVE_SCENEFX
#include <scenefx/types/wlr_scene.h>
#else
#include <wlr/types/wlr_scene.h>
#endif

#endif /* SCENEFX_COMPAT_H */
```

### 1.5 Replace includes in 13+ files
Replace `#include <wlr/types/wlr_scene.h>` → `#include "scenefx_compat.h"` in:

| File | Include line |
|------|-------------|
| somewm.c | ~59 |
| stack.c | ~19 |
| somewm_types.h | ~17 |
| shadow.h | ~27 |
| root.c | ~33 |
| luaa.c | ~70 |
| systray.c | ~31 |
| globalconf.h | (if present) |
| client.h | ~29 |
| objects/client.c | ~121 |
| objects/screen.c | ~20 |
| objects/wibox.c | ~24 |
| objects/drawin.c | ~18 |
| objects/layer_surface.c | ~9 |

### 1.6 Verify
- `meson setup build-nofx -Dscenefx=disabled` → builds identically to current
- `meson setup build-fx -Dscenefx=enabled` → builds with scenefx, runs without visual changes

## Phase 2: Rounded Corners — Medium complexity (~1-2 hours)

### Files
- `objects/client.h` — add `int corner_radius` to client_t
- `objects/client.c` — add Lua property getter/setter, `client_apply_corner_radius()`
- `somewm.c` — re-apply corner_radius in `commitnotify()` and `mapnotify()`
- `objects/drawin.c` / `objects/drawin.h` — corner_radius for panels (optional)

### Implementation
- `client_apply_corner_radius()` walks `c->scene_surface` recursively, calls
  `wlr_scene_buffer_set_corner_radius()` on buffers and
  `wlr_scene_rect_set_corner_radius()` on border rects
- Guarded by `#ifdef HAVE_SCENEFX`, no-op otherwise
- Lua: `c.corner_radius = 10` works even without scenefx (stores value, no visual effect)
- Theme: `beautiful.corner_radius` default
- Re-apply in commitnotify (same pattern as opacity hack)

## Phase 3: SceneFX Native Shadows — Medium complexity (~1-2 hours)

### Files
- `shadow.h` — add `struct wlr_scene_shadow *sfx_shadow` to shadow_nodes_t (ifdef)
- `shadow.c` — dual-path in `shadow_create()`, `shadow_update_geometry()`, `shadow_destroy()`

### Implementation
- When `HAVE_SCENEFX`: `wlr_scene_shadow_create()` + setters (blur_sigma, color, corner_radius)
- Single GPU-rendered node replaces 9 texture slices + manual positioning
- Fallback: existing 9-slice system unchanged
- `shadow_update_config()` updates via scenefx setters instead of destroy+recreate

## Phase 4: Opacity Improvement — RESOLVED (no code change)

### Answer: NO — scenefx does NOT fix buffer opacity reset

The opacity reset happens in wlroots' `wlr_scene_xdg_surface_create()` path which
destroys and recreates buffer nodes on surface reconfigure. SceneFX only extends
the scene renderer — the XDG surface lifecycle is unchanged in wlroots.

**Decision:** Keep all existing opacity re-apply workarounds as-is:
- `somewm.c` commitnotify — re-apply opacity after surface commit ✓
- `somewm.c` commitlayersurfacenotify — re-apply layer surface opacity ✓
- `somewm.c` rendermon — per-frame layer surface opacity re-apply ✓

The same pattern applies to `corner_radius` (already handled in commitnotify).

## Phase 5: Background Blur

### Implementation
- Per-client `backdrop_blur` boolean property (Lua: `c.backdrop_blur = true`)
- Global blur parameters via `wlr_scene_set_blur_data()` at startup
- `client_apply_backdrop_blur()` walks scene tree, sets `backdrop_blur` on buffers
- Re-applied in commitnotify alongside opacity and corner_radius
- Guarded by `#ifdef HAVE_SCENEFX`, no-op without it

### SceneFX Blur API
- Global: `wlr_scene_set_blur_data(scene, num_passes, radius, noise, brightness, contrast, saturation)`
- Per-buffer: `wlr_scene_buffer_set_backdrop_blur(buf, bool)`
- Per-buffer: `wlr_scene_buffer_set_backdrop_blur_optimized(buf, bool)`
- Per-buffer: `wlr_scene_buffer_set_backdrop_blur_ignore_transparent(buf, bool)`

## Risks

| Risk | Mitigation |
|------|-----------|
| scenefx GLES2-only (no Vulkan) | NVIDIA usually works with GLES2; add runtime warning if non-GLES2 renderer |
| scenefx pre-1.0 API instability | Pin to 0.4 in wrap, concentrate calls in compat header |
| Corner radius reset on surface reconfigure | Same re-apply pattern as opacity (commitnotify) |

## SceneFX API reference

### New functions (additive, existing wlr_scene_* unchanged)
- `wlr_scene_buffer_set_opacity(buffer, float)` — per-buffer opacity
- `wlr_scene_buffer_set_corner_radius(buffer, int)` / `set_corner_radii()` — per-corner
- `wlr_scene_rect_set_corner_radius(rect, int)` / `set_corner_radii()`
- `wlr_scene_shadow_create(tree, w, h)` + `set_blur_sigma()`, `set_color()`, `set_corner_radius()`
- `wlr_scene_blur_create(tree, w, h)` + `set_strength()`, `set_alpha()`, `set_corner_radii()`
- Global blur: `wlr_scene_set_blur_data/num_passes/radius/noise/brightness/contrast/saturation()`

### Include path
`<scenefx/types/wlr_scene.h>` replaces `<wlr/types/wlr_scene.h>`

### Build
Both `wlroots-0.19` AND `scenefx-0.4` are linked simultaneously.
scenefx extends wlroots structs, doesn't replace the library.

## Verification

1. Build without scenefx: `meson setup build -Dscenefx=disabled && ninja -C build`
2. Build with scenefx: `meson setup build-fx -Dscenefx=enabled && ninja -C build-fx`
3. Run nested compositor with scenefx build, verify no crashes
4. Set `c.corner_radius = 12` from IPC, verify visual rounding
5. Verify shadows still render (scenefx path or 9-slice fallback)
6. Verify opacity still works (with and without scenefx)
