# SceneFX Visual Effects for somewm

**Branch:** `feat/scenefx-integration` (22 commits)
**Library:** [scenefx](https://github.com/wlrfx/scenefx) v0.4.0 (upstream, unmodified)
**Status:** Fully functional, tested on NVIDIA RTX 5070 Ti (proprietary driver)
**Video demo:** _(TODO: record and link before upstream issue)_

## What is scenefx?

scenefx is a drop-in extension library for wlroots that adds GPU-accelerated
visual effects to the scene graph renderer. It was created by the SwayFX project
and provides SDF-based (signed distance field) shader effects:

- **Rounded corners** on buffers and rects (`wlr_scene_buffer_set_corner_radius`)
- **GPU shadows** as single-pass scene nodes (`wlr_scene_shadow_create`)
- **Background blur** per buffer (`wlr_scene_buffer_set_backdrop_blur`)
- **Per-corner radius** control via `corner_location` bitflags

scenefx v0.4 targets wlroots 0.19, which somewm already uses. It extends
wlroots structs without replacing the library — both are linked simultaneously.
The renderer is GLES2-based (works fine on NVIDIA with proprietary drivers).

## Why this matters for somewm

somewm already has an animation framework (`anim_client.lua`) that handles
fade-in/out, geometry animations (maximize, fullscreen, tiling), and an
existing 9-slice texture shadow system. What was missing:

1. **Rounded corners** — no way to round window edges at the compositor level
2. **Efficient shadows** — 9-slice textures work but require 9 scene nodes and
   CPU-side texture generation per shadow; GPU shadows need one node
3. **Background blur** — Wayland has no protocol for this; must be compositor-side
4. **Rounded borders** — standard 4-rect borders can't follow rounded corners

scenefx fills all four gaps while keeping everything optional at compile time.

## Design: optional compile-time extension

The entire integration is guarded by `#ifdef HAVE_SCENEFX` / `-Dscenefx=auto`.

**Without scenefx (`-Dscenefx=disabled`):**
- somewm builds and behaves identically to upstream
- All Lua properties (`corner_radius`, `backdrop_blur`, `shadow`) are accepted
  and stored, but have no visual effect
- anim_client.lua configures effects via `ruled.client` rules without errors
- 9-slice texture shadows continue to work as before

**With scenefx (`-Dscenefx=enabled`):**
- GPU-rendered rounded corners, shadows, and blur become active
- Single-rect border frame replaces 4-rect borders for rounded windows
- Titlebar buffers get per-corner rounding matching the window
- All effects are configurable per-client via Lua rules

This means the animation framework code is unified — it sets properties on
clients regardless of whether scenefx is compiled in. The C side either
applies GPU effects or silently ignores them.

## What was implemented

### Build integration
- Meson option `scenefx` (type: feature, default: auto)
- `subprojects/scenefx.wrap` for automatic download
- `scenefx_compat.h` — conditional include that switches between
  `<scenefx/types/wlr_scene.h>` and `<wlr/types/wlr_scene.h>`
- All 14 files that include `wlr_scene.h` redirected through the compat header
- `HAVE_SCENEFX` compile flag, shown in build summary

### Rounded corners (`c.corner_radius`)
- New Lua property on client: `c.corner_radius = 14`
- `client_apply_corner_radius()` walks the scene tree recursively, applies
  `wlr_scene_buffer_set_corner_radius()` to all surface buffers
- Re-applied in `commitnotify()` because wlroots resets buffer state on
  surface reconfigure (same pattern as the existing opacity re-apply hack)
- Per-corner control via `corner_location` bitflags — surfaces with titlebars
  only get rounding on the exposed corners

### GPU shadows (dual-path)
- When scenefx is available: `wlr_scene_shadow_create()` produces a single
  GPU-rendered shadow node with configurable blur_sigma, color, corner_radius
- When scenefx is not available: existing 9-slice texture shadow system
- Both paths share the same Lua API: `c.shadow = { enabled=true, sigma=12, ... }`
- Shadow corner_radius automatically tracks window corner_radius

### Background blur (`c.backdrop_blur`)
- New boolean Lua property: `c.backdrop_blur = true`
- Global blur parameters set once at startup via `wlr_scene_set_blur_data()`
- `client_apply_backdrop_blur()` walks scene tree, enables blur on buffers
- Re-applied in commitnotify (same as opacity and corner_radius)
- Automatically disabled on fullscreen clients (performance)

### Rounded borders (single frame rect)
Standard 4-rect borders (top/bottom/left/right) can't render rounded corners —
thin rects cause SDF shader distortion. The solution is a single full-geometry
`border_frame` rect with a scenefx `clipped_region` punch-hole:

```
+---------------------+   outer rect: full client geometry
|  +===============+  |   corner_radius = cr + border_width
|  |               |  |
|  |   (content)   |  |   inner hole (clipped_region)
|  |               |  |   corner_radius = cr
|  +===============+  |
+---------------------+
```

The border is the visual difference between the outer rounded rect and the
inner rounded hole. Key decisions:

- Frame stays **above** the surface in z-order (not below — placing it below
  causes SDF mismatch artifacts between two different shader paths).
  `clipped_region` prevents overdraw over content.
- Outer radius = `corner_radius + border_width` for consistent border width.
- When `border_width <= 0` (maximize/fullscreen), all borders are hidden.
- When `corner_radius == 0`, falls back to standard 4-rect flat borders.
- No new Lua API — switching happens automatically based on corner_radius.

### Titlebar rounded corners
When titlebars are enabled, their scene_buffers get matching rounded corners:

- Top titlebar: `CORNER_LOCATION_TOP` (top-left + top-right)
- Bottom titlebar: `CORNER_LOCATION_BOTTOM`
- Surface corners are adjusted: top titlebar present = no surface top rounding

A 1px SDF mismatch between rect and buffer shaders is handled by using
`corner_radius + 1` on titlebar buffers, creating a tiny overlap.

Corner radius is applied at three points to cover all applications:
1. Buffer creation (`titlebar_get_drawable`)
2. Titlebar toggle (`titlebar_resize`)
3. Each surface commit (`commitnotify` -> `client_apply_corner_radius`)

### Fade animation + decoration interaction
`wlr_scene_rect` color alpha doesn't visually affect border rendering
(confirmed by testing — the shader uses it but the visual result is unchanged).
Workaround in `anim_client.lua`:

- FadeIn/FadeOut hides border (`border_width=0`), shadow, and backdrop blur
- FadeIn restores decorations at 70% animation progress
- FadeOut keeps decorations hidden (window is closing anyway)

## Lua configuration (anim_client.lua)

All scenefx features are configured through `ruled.client` rules in the
animation module, making them part of the existing per-class/per-instance
rule system:

```lua
-- Default corner radius for all windows
ruled.client.append_rule {
    rule = {},
    properties = { corner_radius = 14 },
}

-- Disable corners for specific apps
ruled.client.append_rule {
    rule_any = { class = { "steam", "gamescope" } },
    properties = { corner_radius = 0 },
}

-- Background blur for terminals
ruled.client.append_rule {
    rule_any = { class = { "Alacritty", "kitty", "foot" } },
    properties = { backdrop_blur = true, opacity = 0.75 },
}
```

Global blur parameters are set once at compositor startup:
```lua
if awesome.scenefx then
    awesome.set_blur_data(2, 5, 0.02, 0.9, 0.9, 1.0)
end
```

## Files changed (C side)

| File | Changes |
|------|---------|
| `meson_options.txt` | `scenefx` feature option |
| `meson.build` | Dependency detection, `HAVE_SCENEFX` flag |
| `scenefx_compat.h` | NEW — conditional include header |
| `objects/client.h` | `corner_radius`, `backdrop_blur`, `border_frame` fields |
| `objects/client.c` | Corner radius, blur, border frame logic (~300 lines) |
| `client.h` | `client_set_border_color` border_frame support |
| `shadow.h` | `sfx_shadow` field in shadow_nodes_t |
| `shadow.c` | Dual-path shadow create/update/destroy |
| `somewm.c` | commitnotify re-apply, border_frame create/teardown |
| `somewm_api.c` | `awesome.scenefx` property, `set_blur_data` |
| 14 files | `#include "scenefx_compat.h"` redirect |

## Known issues and limitations

1. **fadeIn + blur_opacity interaction**: FadeIn hardcodes target opacity to 1.0,
   which overrides `ruled.client` blur_opacity settings. Needs full opacity
   lifecycle analysis — not a quick fix.

2. **wlr_scene_rect opacity**: Color alpha on rects doesn't visually work for
   dynamic opacity changes. Workaround: hide decorations during fade.

3. **scenefx is GLES2-only**: No Vulkan renderer support. Works fine on NVIDIA
   with proprietary drivers (GLES2 is the default), but systems that require
   Vulkan won't get effects.

4. **scenefx pre-1.0**: API may change. Pinned to v0.4 via meson wrap.

## Commit history

```
820415a feat: rounded corner support for titlebars
acf63d2 refactor: tune fadeIn duration from 0.7s to 0.5s
d5743f4 fix: hide border, shadow and blur during fade animations
1591d56 fix: border_frame z-order and maximize/fullscreen visibility
e36e704 fix: address review findings for border_frame implementation
d6eb0b1 feat: single frame rect border for rounded corners (tinywl pattern)
39804f9 refactor: revert border corner experiments, prepare for frame rect approach
7770ec6 fix: rounded border rendering with scenefx clipped_region punch-holes
97070e5 refactor: move scenefx config from rc.lua to anim_client module
46af53c feat(somewm-one): add scenefx visual effects configuration
029d6cd fix: unconditional scenefx re-apply and fullscreen blur skip
e0c1f60 fix: use luaA_checkboolean for backdrop_blur setter
9bbbabd fix: address review findings in backdrop blur
5f804a5 test: add scenefx backdrop_blur integration test
82c3560 feat: add backdrop_blur property for clients (Phase 5)
f491608 docs: document Phase 4 opacity findings (no code change needed)
f7e2541 fix: address review findings in scenefx shadow path
65423f6 refactor: simplify scenefx dependency detection
34ab94e test: add scenefx corner_radius and shadow integration tests
38a3c87 feat: add scenefx native GPU shadows (Phase 3)
573312b feat: add corner_radius property for clients (Phase 2)
96e3283 feat: add scenefx build integration (Phase 1)
```

## SceneFX API reference (used in this integration)

```c
// Buffers (surfaces, titlebars)
wlr_scene_buffer_set_corner_radius(buffer, int radius, enum corner_location corners);
wlr_scene_buffer_set_opacity(buffer, float opacity);
wlr_scene_buffer_set_backdrop_blur(buffer, bool enabled);
wlr_scene_buffer_set_backdrop_blur_optimized(buffer, bool enabled);

// Rects (borders)
wlr_scene_rect_set_corner_radius(rect, int radius, enum corner_location corners);
wlr_scene_rect_set_clipped_region(rect, struct clipped_region region);

// Shadows
struct wlr_scene_shadow *wlr_scene_shadow_create(tree, w, h);
wlr_scene_shadow_set_blur_sigma(shadow, float sigma);
wlr_scene_shadow_set_color(shadow, float color[4]);
wlr_scene_shadow_set_corner_radius(shadow, int radius);

// Global blur
wlr_scene_set_blur_data(scene, passes, radius, noise, brightness, contrast, saturation);

// Corner location bitflags
CORNER_LOCATION_TOP_LEFT | TOP_RIGHT | BOTTOM_RIGHT | BOTTOM_LEFT
CORNER_LOCATION_TOP | BOTTOM | LEFT | RIGHT | ALL | NONE
```

## Next steps

1. Record video demo (rounded corners, shadows, blur, fade animations)
2. Create upstream issue referencing this branch as proof of concept
3. Position as optional extension to the existing animation framework
