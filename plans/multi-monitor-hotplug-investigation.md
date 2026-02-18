# Investigation: Multi-monitor hotplug — clients disappear to invisible screen

## Related upstream issue: #216

## Problem

Two monitors connected via cable to NVIDIA GPU (RTX 5070 Ti, proprietary driver).
Dell monitor is the primary/active display, TV is physically off but cable is connected.
When TV is turned on:

1. All applications except the focused one disappear from Dell
2. Apps literally move to the TV screen
3. TV physically shows nothing (doesn't render)
4. New applications also open on the invisible TV screen
5. Must restart somewm; after restart, everything works perfectly

Also happens with monitor sleep/wake cycles.

## Architecture overview (output lifecycle)

```
Physical output detected by DRM/wlroots
  → createmon()         Create Monitor, screen_t, listeners, scene_output
  → updatemons()        Called from layout::change; sets geometry, arrange, focus
  → rendermon()         Called every frame; commits scene_output
  → requestmonstate()   Called on mode/DPMS change; commits state, updatemons()
  → powermgrsetmode()   Called for wlr-output-power-management; enable/disable
  → cleanupmon()        Called on output destroy; removes Monitor, screen_removed()
  → closemon()          Called from cleanupmon/updatemons; moves clients, updates selmon
```

## Bugs found

### Bug 1: `closemon()` selmon selection loop doesn't iterate (CONFIRMED)

**File:** `somewm.c:1226-1228`

```c
do /* don't switch to disabled mons */
    selmon = wl_container_of(mons.next, selmon, link);
while (!selmon->wlr_output->enabled && i++ < nmons);
```

`wl_container_of(mons.next, selmon, link)` ALWAYS returns the first Monitor in
the `mons` linked list. The `selmon` parameter is only used for type inference
(`typeof(selmon)`), it does NOT advance the iteration. The loop checks the same
monitor every time.

**Consequence:** If the first monitor in the list is disabled, the loop spins
`nmons` times and then falls through to `selmon = NULL`. All clients get
`setmon(c, NULL, 0)`, becoming orphaned.

**Why list order matters:** `wl_list_insert(&mons, &m->link)` at line 1657
inserts at HEAD. The last-created monitor is first in the list. If TV was
detected second (common for HDMI), TV is first in `mons`.

**Scenario where this causes the user's bug:**
1. Startup: Dell created first, TV created second → mons order: [TV, Dell]
2. TV disabled (off) → closemon(TV) runs, but TV has no clients
3. TV turns on → updatemons() → TV added to layout
4. If NVIDIA mode set briefly disables Dell (common on NVIDIA when adding output):
   - closemon(Dell) runs, m == selmon (Dell)
   - Loop: selmon = first in mons = TV
   - TV is now enabled → loop exits, selmon = TV
   - ALL Dell clients: `setmon(c, TV, 0)` → clients move to TV!
5. TV doesn't render properly → clients are invisible

**Fix:** Properly iterate the `mons` list:

```c
} else if (m == selmon) {
    Monitor *iter;
    selmon = NULL;
    wl_list_for_each(iter, &mons, link) {
        if (iter != m && iter->wlr_output->enabled) {
            selmon = iter;
            break;
        }
    }
}
```

### Bug 2: `rendermon()` has no safety checks (CONFIRMED)

**File:** `somewm.c:3856-3861`

```c
wlr_scene_output_commit(m->scene_output, NULL);
// ...
wlr_scene_output_send_frame_done(m->scene_output, &now);
```

No check for:
- `m->wlr_output->enabled` — frame events can fire for disabled outputs
- Return value of `wlr_scene_output_commit()` — silent failure means no rendering
- `m->scene_output` validity — though unlikely to be NULL after createmon()

If the frame event fires but the commit consistently fails (NVIDIA DRM issue
after mode change), the output appears to be running but never renders.

**Fix:** Add enabled check and log commit failures:

```c
void
rendermon(struct wl_listener *listener, void *data)
{
    Monitor *m = wl_container_of(listener, m, frame);
    Client *c;
    struct timespec now;

    if (!m->wlr_output->enabled)
        return;

    foreach(client, globalconf.clients) {
        c = *client;
        if (c->resize && !some_client_get_floating(c) && client_is_rendered_on_mon(c, m) && !client_is_stopped(c))
            goto skip;
    }

    if (!wlr_scene_output_commit(m->scene_output, NULL)) {
        /* Commit failed — output may need reconfiguration */
    }

skip:
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_scene_output_send_frame_done(m->scene_output, &now);
}
```

### Bug 3: `requestmonstate()` has no error handling (CONFIRMED)

**File:** `somewm.c:3886-3891`

```c
void
requestmonstate(struct wl_listener *listener, void *data)
{
    struct wlr_output_event_request_state *event = data;
    wlr_output_commit_state(event->output, event->state);
    updatemons(NULL, NULL);
}
```

`wlr_output_commit_state()` can fail. If it fails, the output state is
inconsistent — wlroots might think it's in one state while the DRM driver
reports another. `updatemons()` then runs with wrong assumptions.

**Fix:** Check return value:

```c
void
requestmonstate(struct wl_listener *listener, void *data)
{
    struct wlr_output_event_request_state *event = data;
    if (!wlr_output_commit_state(event->output, event->state)) {
        wlr_log(WLR_ERROR, "Failed to commit requested output state for %s",
                event->output->name);
    }
    updatemons(NULL, NULL);
}
```

### Bug 4: Frame listener registered before scene_output exists (POTENTIAL)

**File:** `somewm.c:1649-1678`

```c
LISTEN(&wlr_output->events.frame, &m->frame, rendermon);  // line 1649
// ...
wlr_output_commit_state(wlr_output, &state);              // line 1654
// ... (24 lines later)
m->scene_output = wlr_scene_output_create(scene, wlr_output);  // line 1678
```

The frame listener is registered before `scene_output` is created. If
`wlr_output_commit_state()` triggers a synchronous frame event, `rendermon()`
would dereference `m->scene_output` which is NULL (zero-initialized from ecalloc).

In practice, wlroots schedules frame events asynchronously, but on NVIDIA's
DRM backend the timing may differ.

**Fix:** Move scene_output creation before the first commit, or add NULL check
in rendermon().

### Bug 5: `updatemons()` calls `closemon()` repeatedly for disabled monitors

**File:** `somewm.c:5100-5109`

Every `updatemons()` invocation processes ALL disabled monitors through
`closemon()`. This is called from `layout::change`, `requestmonstate()`, and
`powermgrsetmode()` — potentially many times per hotplug event.

`closemon()` does `setmon(c, selmon, 0)` for each client, which emits
`property::screen` signal. The Lua tag system responds to this signal
(tag.lua:1817) and re-tags clients. Repeated closemon calls for the same
disabled monitor cause redundant signal emission and potential tag corruption.

**Fix:** Track whether closemon was already called, or check if monitor has
any clients before processing:

```c
wl_list_for_each(m, &mons, link) {
    if (m->wlr_output->enabled || m->asleep)
        continue;
    if (wlr_output_layout_get(output_layout, m->wlr_output)) {
        config_head = wlr_output_configuration_head_v1_create(config, m->wlr_output);
        config_head->state.enabled = 0;
        wlr_output_layout_remove(output_layout, m->wlr_output);
        closemon(m);
        m->m = m->w = (struct wlr_box){0};
    }
}
```

## Comparison with Sway

Sway handles the same scenario very differently:

| Aspect | somewm | Sway |
|--------|--------|------|
| Client migration | Move all to `selmon` (first in list) | Workspace-level with output priority |
| Selmon selection | Broken loop (Bug 1) | Seat focus stack, cursor position |
| Output disable | `closemon()` every updatemons | `output_disable()` once, removes from active list |
| Output enable | Just add to layout | `output_enable()` restores workspaces from priority |
| Mode change | Blind commit, single updatemons | Atomic backend commit with fallback search |
| Error handling | None | Tests config validity, degrades to off if needed |
| Rendering | No commit error check | Repaint timer with damage tracking |

Key Sway patterns worth adopting:
1. **`output_evacuate()`**: Migrates workspaces to fallback output with priority
2. **Atomic commits**: `wlr_backend_commit()` applies all changes together
3. **Enabled flag**: Separate `output->enabled` flag, not just wlr_output->enabled
4. **Output list**: Maintains separate list of enabled outputs only

## NVIDIA-specific factors

1. **Mode set resets all outputs**: When NVIDIA adds an output, it may briefly
   disable/reset all DRM CRTCs. This causes intermediate disabled states for
   Dell during TV enable sequence.

2. **EDID timing**: HDMI EDID readout can race with the compositor's output
   setup. TV might report "connected" before EDID is available.

3. **DRM atomic commit limitations**: NVIDIA's proprietary driver has known
   issues with atomic commits and multi-output mode sets.

4. **Frame scheduling**: NVIDIA's presentation timing differs from Intel/AMD.
   `wlr_scene_output_commit()` failures may be more common.

## Debug logging plan

To confirm the exact event sequence, add temporary logging:

```c
// In createmon():
wlr_log(WLR_ERROR, "[HOTPLUG] createmon: %s enabled=%d",
    wlr_output->name, wlr_output->enabled);

// In cleanupmon():
wlr_log(WLR_ERROR, "[HOTPLUG] cleanupmon: %s", m->wlr_output->name);

// In requestmonstate():
wlr_log(WLR_ERROR, "[HOTPLUG] requestmonstate: %s enabled=%d",
    event->output->name,
    event->state->committed & WLR_OUTPUT_STATE_ENABLED ? event->state->enabled : -1);

// In closemon():
wlr_log(WLR_ERROR, "[HOTPLUG] closemon: %s selmon=%s nclients=%d",
    m->wlr_output->name,
    selmon ? selmon->wlr_output->name : "NULL",
    /* count clients on m */);

// In updatemons() disabled loop:
wlr_log(WLR_ERROR, "[HOTPLUG] updatemons: disabling %s", m->wlr_output->name);

// In updatemons() enable loop:
wlr_log(WLR_ERROR, "[HOTPLUG] updatemons: enabling %s", m->wlr_output->name);

// In rendermon():
if (!wlr_scene_output_commit(m->scene_output, NULL))
    wlr_log(WLR_ERROR, "[HOTPLUG] rendermon: commit FAILED for %s", m->wlr_output->name);
```

## Fix priority

1. **Bug 1 (closemon iteration)** — HIGH. This is the most likely cause of
   clients moving to TV. Fix is simple and safe.
2. **Bug 5 (repeated closemon)** — HIGH. Guards against redundant processing.
3. **Bug 3 (requestmonstate error)** — MEDIUM. Error handling + logging.
4. **Bug 2 (rendermon safety)** — MEDIUM. Explains why TV doesn't render.
5. **Bug 4 (frame before scene_output)** — LOW. Race condition, unlikely but
   possible on NVIDIA.

## Files involved

| File | Line | Issue |
|------|------|-------|
| `somewm.c` | 1226-1228 | closemon() selmon loop doesn't iterate |
| `somewm.c` | 3856 | rendermon() no enabled check, no commit error check |
| `somewm.c` | 3889 | requestmonstate() no error handling |
| `somewm.c` | 1649/1678 | Frame listener before scene_output creation |
| `somewm.c` | 5100-5109 | updatemons() repeated closemon on disabled monitors |

## Test plan

1. **Add debug logging** — build with [HOTPLUG] markers, reproduce the issue
2. **Fix Bug 1** — proper closemon iteration, verify clients stay on Dell
3. **Fix Bug 5** — guard closemon in updatemons
4. **Fix Bug 2** — rendermon safety checks, verify TV renders
5. **Regression test** — single monitor, dual monitor, hotplug, DPMS sleep/wake
