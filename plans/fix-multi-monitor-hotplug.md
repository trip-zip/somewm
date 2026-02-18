# Fix: Multi-monitor hotplug — output enable/disable/DPMS

## Status: DONE (revision 5 — implemented, tested, verified on hardware)

## Problem

When a second monitor (TV) is turned on while connected via cable to NVIDIA GPU,
all applications except the focused one move to the TV screen. The TV doesn't
render anything. New applications also open on the invisible screen. Restart
fixes it. Same issue occurs with monitor sleep/wake (DPMS).

## Key finding from bottom-up + top-down review

**`events.request_state` is NOT emitted by the DRM backend.** On real DRM
hardware with NVIDIA, outputs are CREATED and DESTROYED on hotplug, not
enabled/disabled. The critical code paths are `createmon()` and `cleanupmon()`.

**`screen_client_moveto()` (screen.c:2121) DOES update `c->mon`.** After
`screen_removed()` migrates clients, `closemon()` skips them (c->mon != m).
BUT only if another screen existed at migration time.

**`screen_added_idle()` was DEFERRED but `updatemons()` runs SYNCHRONOUSLY**
from `createmon()`. Orphaned clients got assigned to screens without tags.

## Root cause trace: TV turns on (worst case — NVIDIA resets both outputs)

```
TV turns on → DRM hotplug

1. cleanupmon(Dell) fires:
   1a. screen_removed(Dell):
       - Lua "removed" signal fires SYNCHRONOUSLY
       - tag.lua:1913 handler runs:
         for other_screen in capi.screen do → NO other screen
         fallback = nil
         t:delete(nil, true) → ALL tags deleted, clients UNTAGGED
       - C: luaA_screen_getbycoord → NULL (no other screen)
       - Clients NOT moved (c->screen still = Dell, c->mon still = Dell)
       - screen->valid = false, screen->monitor = NULL
   1b. wl_list_remove(Dell from mons) → mons list empty
   1c. closemon(Dell):
       - nmons = 0 → selmon = NULL
       - setmon(c, NULL, 0) for all clients → c->mon = NULL, c->screen = NULL
   1d. Monitor freed

   STATE: All clients orphaned (c->mon=NULL, c->screen=NULL, no tags)

2. createmon(TV) fires:
   2a. New Monitor, new screen_t created
   2b. wlr_output_layout_add_auto(TV) triggers layout::change
   2c. updatemons() runs SYNCHRONOUSLY:
       - Orphaned clients (!c->mon): setmon(c, TV, 0)
       - setmon updates c->mon=TV, c->screen=TV's screen
       - Emits property::screen → tag.lua delayed handler queued
       - BUT TV's screen has NO TAGS (screen_added_idle not fired yet!)
   2d. screen_added_idle(TV) QUEUED for next event loop

3. createmon(Dell) fires:
   3a. New Monitor, new screen_t created
   3b. wlr_output_layout_add_auto(Dell) → updatemons()
       - Clients already on TV (from 2c), not orphaned
   3c. screen_added_idle(Dell) QUEUED

4. Event loop resumes:
   4a. screen_added_idle(TV) fires → rc.lua creates tags 1-9 for TV
   4b. screen_added_idle(Dell) fires → rc.lua creates tags 1-9 for Dell
   4c. tag.lua delayed handlers fire → try to assign tags to clients on TV
       - TV now has tags → clients get tag 1 (or request::tag rule)
       - Clients become visible... on TV

5. RESULT:
   - ALL clients on TV (which may not be rendering)
   - Dell is empty
   - Restart fixes it (clean init, clients go to Dell)
```

## 6 bugs found and fixed

### Bug 1: closemon() selmon iteration doesn't iterate — FIXED

**Problem:** `wl_container_of(mons.next, selmon, link)` always returns first
monitor. The `selmon` parameter is only used for type inference by the macro.
The do-while loop checks the same monitor every iteration.

**Fix (somewm.c closemon()):** Replaced broken do-while with `wl_list_for_each()`
that properly iterates the linked list, skipping the closing monitor and disabled
monitors. Also changed `wl_list_length(&mons) == 0` to `wl_list_empty(&mons)`.

---

### Bug 2: createmon() screen_added timing race — FIXED

**Problem:** Two timing issues:

1. `screen_added_idle()` was DEFERRED to next event loop via
   `wl_event_loop_add_idle()`, but `updatemons()` runs SYNCHRONOUSLY from
   `createmon()` via `layout::change` signal. Orphaned clients got assigned
   to screens without tags = invisible.

2. `needs_screen_added` flag was set AFTER `wlr_output_layout_add_auto()`,
   but that function triggers `updatemons()` synchronously. So `updatemons()`
   ran with `needs_screen_added == 0` and never emitted `screen_added`.
   Discovered during hardware testing — screen had 0 tags.

**Fix (somewm_types.h + somewm.c):**

- Added `int needs_screen_added` field to Monitor struct
- Removed `deferred_screen_add_t` struct and `screen_added_idle()` function
  (eliminates deferred callback UAF risk)
- In `createmon()`: create screen object and set `needs_screen_added = 1`
  BEFORE `wlr_output_layout_add_auto()` (critical ordering fix)
- In `updatemons()`: emit `screen_added` in a SEPARATE loop after the geometry
  loop but before orphan assignment (collect → emit pattern per external review)
- `in_updatemons = 1` prevents recursive `updatemons()` calls from Lua callbacks

**Verified execution order:**
```
createmon()
  → screen = luaA_screen_new()
  → m->needs_screen_added = 1
  → wlr_output_layout_add_auto() → layout::change → updatemons()
    → geometry loop: m->m set from output layout (correct geometry)
    → screen_added loop: needs_screen_added=1 → emit screen_added
      → rc.lua creates tags + wibar with correct geometry
    → orphan assignment: setmon(c, selmon, 0) — screen has tags ✓
```

---

### Bug 3: rendermon() no safety checks — FIXED

**Fix (somewm.c rendermon()):**

- Added `if (!m->scene_output) return;` — prevents NULL dereference if frame
  fires before scene_output is created (possible on NVIDIA)
- Added `if (!m->wlr_output->enabled) goto skip;` — skips rendering for
  disabled outputs
- Added commit return value check with debug logging

---

### Bug 4: requestmonstate() no error handling — FIXED

**Fix (somewm.c requestmonstate()):** Check `wlr_output_commit_state()` return
value, log errors. Note: DRM backend doesn't emit `request_state`, but
Wayland/X11 backends do (relevant for nested compositor testing).

---

### Bug 5: updatemons() processes disabled monitors repeatedly — FIXED

**Fix (somewm.c updatemons()):** Added `wlr_output_layout_get()` guard to skip
monitors already removed from the output layout. Without this, every
`updatemons()` invocation would call `closemon()` on ALL disabled monitors,
even if they were already processed.

---

### Bug 6: Frame listener before scene_output in createmon() — FIXED

**Fix:** `rendermon()` now checks `if (!m->scene_output) return;` at the very
start. This prevents NULL dereference if a frame event fires between
`LISTEN(&wlr_output->events.frame)` (early in createmon) and
`wlr_scene_output_create()` (later in createmon).

---

## Debug logging added

`[HOTPLUG]` markers on `WLR_ERROR` level in all output lifecycle functions:

| Function | Log format |
|----------|------------|
| `createmon()` | `createmon: %s enabled=%d mons=%d` |
| `cleanupmon()` | `cleanupmon: %s remaining_mons=%d` |
| `closemon()` | `closemon: %s selmon=%s nclients=%d` |
| `updatemons()` entry | `updatemons enter mons=%d` |
| `updatemons()` disable | `updatemons disable: %s` |
| `updatemons()` geometry | `updatemons geom: %s %d,%d %dx%d` |
| `updatemons()` screen_added | `updatemons screen_added: %s` |
| `updatemons()` orphan | `updatemons orphan: %s → %s` |
| `updatemons()` exit | `updatemons exit selmon=%s` |
| `rendermon()` failure | `rendermon commit failed: %s` |
| `requestmonstate()` | `requestmonstate: %s` |
| `powermgrsetmode()` | `powermgrsetmode: %s mode=%d asleep=%d` |
| `setmon()` | `setmon: client=%s old=%s new=%s` |

## External review

Review obtained from Gemini (Google) and Codex (OpenAI) via avatar-engine.
Both confirmed:
- All 6 bugs correctly identified
- `needs_screen_added` approach is sound
- Recommended "collect → emit" pattern for screen_added (separate loop
  from geometry to avoid reentrancy) — implemented
- `in_updatemons` guard prevents recursive updatemons from Lua callbacks
- Empty mons list guard (`wl_list_empty()`) — implemented

## Files modified

| File | Change |
|------|--------|
| `somewm_types.h` | Added `int needs_screen_added` to Monitor struct |
| `somewm.c` | Removed `deferred_screen_add_t` struct |
| `somewm.c` | Removed `screen_added_idle()` function |
| `somewm.c` | Fixed `closemon()` selmon iteration (Bug 1) |
| `somewm.c` | Added safety checks to `rendermon()` (Bug 3, 6) |
| `somewm.c` | Added error handling to `requestmonstate()` (Bug 4) |
| `somewm.c` | Added layout guard to `updatemons()` disabled loop (Bug 5) |
| `somewm.c` | Reordered `createmon()`: screen + flag BEFORE layout add (Bug 2) |
| `somewm.c` | Added synchronous `screen_added` emission in `updatemons()` (Bug 2) |
| `somewm.c` | Added `[HOTPLUG]` debug logging to all lifecycle functions |
| `tests/test-screen-hotplug.lua` | Integration test (multi-screen tags verification) |
| `tests/smoke-hotplug.sh` | Smoke test script (wlr-randr, stress, interactive) |

## Test results

### Integration test (headless, 2 outputs)
```
WLR_WL_OUTPUTS=2 make test-one TEST=tests/test-screen-hotplug.lua
--- PASS: test-screen-hotplug.lua (0.20s)
```

### Smoke test (live session, NVIDIA RTX 5070 Ti, DP-3 + HDMI-A-1)
```
=== Results ===
  PASS: 15  FAIL: 0  SKIP: 0
```

Tests passed:
- Baseline: 2 screens, 9 tags each, no orphaned clients
- wlr-randr disable/enable: client count preserved, tags recreated
- Stress test (5 rapid cycles): client count preserved, no orphans
- Physical hotplug (TV on/off): clients preserved, tags created (`s2:9t`)

### Physical hotplug DRM log (verified)
```
cleanupmon: HDMI-A-1 remaining_mons=1
closemon: HDMI-A-1 selmon=DP-3 nclients=0
createmon: HDMI-A-1 enabled=0 mons=1
updatemons enter mons=2
updatemons geom: HDMI-A-1 3840,0 3840x2160
updatemons geom: DP-3 0,0 3840x2160
updatemons screen_added: HDMI-A-1          ← tags created!
updatemons exit selmon=DP-3
```

## Known remaining issue (separate from this fix)

**NVIDIA DRM mode detection on first hotplug:** When HDMI-A-1 is connected for
the first time after boot, `wlr_output_preferred_mode()` may return 1024x768
(fallback) instead of 3840x2160 because EDID hasn't been fully read by the DRM
backend. Subsequent hotplug cycles get the correct mode. Workaround:
`wdisplay-switcher` (profile 3) sets the correct mode via wlr-randr. This is
an NVIDIA DRM driver issue, not a somewm lifecycle bug.

## Open questions (answered by hardware testing)

1. **Does NVIDIA destroy Dell when TV connects?** No — only HDMI-A-1 is
   destroyed/recreated. Dell (DP-3) stays. The worst-case (both destroyed)
   may happen with different NVIDIA configurations.
2. **What order do events fire?** cleanupmon(HDMI-A-1) → createmon(HDMI-A-1).
   Single output cycle, not both.
3. **Does wlr_scene_output_commit fail for the TV?** No failures logged.
   TV renders correctly when mode is correct (3840x2160).
4. **Is m->asleep ever set?** Only via `powermgrsetmode()` (DPMS path).
   DRM hotplug uses create/destroy, not sleep/wake.
