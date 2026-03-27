# Plan: Animation Configuration System

## Goal

Provide a clean, declarative configuration API for client animations
that allows users to enable/disable individual animations and tweak
their parameters without touching the module source code.

## Design Principles

1. **Zero config works** — sensible defaults, all animations enabled
2. **Single table** — one `beautiful.anim` or `anim_client.config()` call
3. **Per-animation control** — enable/disable + params for each type
4. **Global kill switch** — `enabled = false` disables everything
5. **Theme-friendly** — all values readable from `beautiful.anim_*`

## Proposed API

### Option A: Theme variables (current pattern, extended)

```lua
-- theme.lua
theme.anim_enabled           = true     -- global kill switch
theme.anim_maximize_enabled  = true
theme.anim_maximize_duration = 0.25
theme.anim_maximize_easing   = "ease-out-cubic"
theme.anim_fullscreen_enabled  = true
theme.anim_fullscreen_duration = 0.25
theme.anim_fullscreen_easing   = "ease-out-cubic"
theme.anim_fade_in_enabled   = true
theme.anim_fade_in_duration  = 0.4
theme.anim_fade_out_enabled  = true
theme.anim_fade_out_duration = 0.4
theme.anim_fade_easing       = "ease-out-cubic"
```

Pros: Consistent with AwesomeWM theming pattern. No API change.
Cons: Many flat variables, no structure.

### Option B: Config table via module API (recommended)

```lua
-- rc.lua
require("anim_client").enable({
    enabled = true,           -- global kill switch

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
    fade_in = {
        enabled  = true,
        duration = 0.4,
        easing   = "ease-out-cubic",
    },
    fade_out = {
        enabled  = true,
        duration = 0.4,
        easing   = "ease-out-cubic",
    },
    minimize = {
        enabled  = true,       -- fadeOut on minimize
        duration = 0.4,
        easing   = "ease-out-cubic",
    },
})
```

Pros: Structured, self-documenting, easy to extend.
Cons: Slightly different from pure theme pattern.

### Option C: Hybrid (recommended final)

Theme variables as defaults, overridable via `enable(config)`.
Module reads `beautiful.anim_*` first, then merges with passed config.

```lua
-- Minimal (all defaults from theme):
require("anim_client").enable()

-- Disable just fade:
require("anim_client").enable({ fade_in = { enabled = false } })

-- Disable all animations:
require("anim_client").enable({ enabled = false })
```

## Implementation Complexity

**Low** — ~30 lines of config merging code. The animation logic
stays identical, just reads from config table instead of directly
from `beautiful.*`.

### Changes needed:
1. Add `local config = {}` with defaults in anim_client.lua
2. `enable(user_config)` deep-merges user_config over defaults
3. Each animation function reads from `config.maximize.duration` etc.
4. Add `config.enabled` check at top of each animation function
5. Theme fallback: `config.maximize.duration = beautiful.anim_maximize_duration or 0.25`

### Future extensibility:
- `layout_switch` — animate when layout changes (carousel already has this)
- `tag_switch` — fade between tags
- `float_toggle` — animate float ↔ tiled transition
- `resize` — smooth resize during tiling
- `focus_border` — animate border color transition

## Estimated effort

~1 hour. No C changes needed. Pure Lua refactor of existing module.
