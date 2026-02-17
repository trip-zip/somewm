# somewm stabilization issues

## 1. heap-use-after-free in updatemons (re-entrancy)

**Status:** fixed
**File:** `somewm.c` - `updatemons()`
**Symptom:** Crash at startup when launched from LightDM display manager. System freezes completely (no VT switch, no restart possible). Works fine when launched manually from TTY via `dbus-run-session somewm`.

**Root cause:** Re-entrancy in `updatemons()`. When `createmon()` calls `wlr_output_layout_add_auto()`, wlroots emits `layout::change` signal which triggers `updatemons()`. Inside `updatemons()`, `wlr_output_layout_remove()` (line 4900) frees an `l_output` structure. When control returns to wlroots' `output_layout_add()`, it accesses the freed memory via `wl_signal_add()` - heap-use-after-free.

**Why TTY works:** From a bare TTY, no monitors are in disabled state, so `updatemons()` skips the remove loop and no re-entrancy issue occurs. From LightDM, the greeter leaves DRM in a different state with a disabled output present.

**Fix:** Added `static int in_updatemons` re-entrancy guard. Nested calls to `updatemons()` return immediately, letting the outer invocation handle the full layout update.

**ASAN trace:**
```
AddressSanitizer: heap-use-after-free in wl_signal_add (wayland-server-core.h:476)
  wlr_xdg_output_v1.c:203  add_output
  wlr_output_layout.c:208   output_layout_add
  somewm.c:1649              createmon
freed in:
  wlr_output_layout.c:46    output_layout_output_destroy
  somewm.c:4900              updatemons (wlr_output_layout_remove)
```

## 2. Assertion fail in wlr_output_finish: commit listener not removed

**Status:** fixed (two iterations)
**File:** `somewm.c` - `cleanupmon()`
**Symptom:** After fix #1, somewm starts from LightDM (sees both monitors HDMI-A-1 and DP-3), but then crashes with:
```
somewm: types/output/output.c:387: wlr_output_finish:
  Assertion `wl_list_empty(&output->events.commit.listener_list)' failed.
```

**Root cause:** `cleanupmon()` explicitly called `wlr_output_layout_remove()`, which emits `layout::change` signal triggering `updatemons()`. This could re-add outputs to the layout during the destroy sequence, leaving stale commit listeners attached to the output being destroyed. When `wlr_output_finish()` then checks assertions, the commit listener list is not empty.

The key insight: `wlr_output_layout` registers an **addon** on each output (`wlr_addon_init` in `output_layout_output_create`). When `wlr_output_finish()` runs, it calls `wlr_addon_set_finish()` which automatically invokes `addon_destroy` → `output_layout_output_destroy`, cleanly removing the layout's commit listener without emitting any signals that could cause re-entrancy.

**Reference:** Sway's `begin_destroy()` (`sway/desktop/output.c:431`) does NOT call `wlr_output_layout_remove()` in the destroy handler. Instead, it destroys `scene_output`, disables the output, and defers layout changes via `request_modeset()` (10ms timer).

**Fix iteration 1:** Swapped order: `wlr_scene_output_destroy()` before `wlr_output_layout_remove()`. Did not help - the problem was `wlr_output_layout_remove` itself.

**Fix iteration 2 (final):** Removed `wlr_output_layout_remove()` from `cleanupmon()` entirely. Wlroots handles layout cleanup automatically via the addon system in `wlr_output_finish()`. Only `wlr_scene_output_destroy()` is called explicitly (to remove the scene's commit listener), because scene_output does not use the addon pattern for this output.

**Fix iteration 3:** Restored `wlr_output_layout_remove()` in `cleanupmon()`, now AFTER `wlr_scene_output_destroy()`. Debug logging revealed that after `scene_output_destroy` removes one commit listener, one still remains (the layout's). The re-entrancy guard in `updatemons()` was supposed to prevent the original problem, but the crash persisted.

**Fix iteration 4 (final):** Root cause identified - `wlr_output_layout_remove()` emits `layout::change` → `updatemons()` runs (NOT blocked because `in_updatemons` was a local static in updatemons, and we're calling from cleanupmon). `updatemons()` does arrange/focus/render work that can indirectly cause new commit listeners (presentation_time, gamma) to be added to the output being destroyed.

Solution: Moved `in_updatemons` from local static in `updatemons()` to file-scope static. In `cleanupmon()`, set `in_updatemons = 1` before cleanup and `= 0` after. This prevents `updatemons()` from running during output destruction.

**Cleanup order in `cleanupmon()`:**
1. `wl_list_remove(&m->link)` - remove from mons list
2. `in_updatemons = 1` - block updatemons during cleanup
3. `wlr_scene_output_destroy()` - removes scene's commit listener + addon
4. `wlr_output_layout_remove()` - removes layout's commit listener + cursor's commit listener (via l_output destroy signal) + addon
5. `in_updatemons = 0` - re-enable updatemons
6. Return to `wlr_output_finish()` → `wlr_addon_set_finish()` → no remaining addons → assertions pass ✓

## 3. Keyboard focus not delivered to new clients / games

**Status:** IN PROGRESS - fixes applied but NOT confirmed working on NVIDIA 5070 Ti
**File:** `somewm.c` - `focusclient()` and `mapnotify()`
**Symptom:** When launching games from Steam (e.g., Dispatch) or when new windows appear:
- Mouse focus works (cursor interacts with the window)
- Keyboard focus is NOT delivered - the window appears selected/active but keyboard input is ignored
- For regular windows: clicking away and back fixes it
- For fullscreen games: no workaround, game is completely uncontrollable via keyboard
- Happens specifically on NVIDIA

**Root cause (two issues):**

1. **No keyboard enter when keyboard device is NULL:** `focusclient()` only called `wlr_seat_keyboard_notify_enter()` when `wlr_seat_get_keyboard()` returned a valid keyboard. If no keyboard was registered at the wlroots seat level at that moment, focus was silently skipped. Sway (`sway/input/seat.c:156-171`) always sends keyboard enter, passing NULL for keycodes/modifiers when no keyboard device exists.

2. **Surface not ready when focusclient() is called from Lua rules:** During `mapnotify()`, AwesomeWM Lua rules call `focusclient()` to set focus on the new client. However, for XWayland clients and some native Wayland clients, the surface may not yet be mapped at that point. `focusclient()` checks `surface->mapped` (or `c->scene` for XWayland) and skips keyboard enter if the surface isn't ready. By the time the surface IS ready, no one re-sends the keyboard enter.

**Reference:** Sway's `seat_keyboard_notify_enter()` (`sway/input/seat.c:156-171`) sends keyboard enter even without a keyboard device, passing NULL parameters.

**Fix (four changes):**

1. **focusclient() - keyboard enter without keyboard device:** Added `else` branch that calls `wlr_seat_keyboard_notify_enter(seat, surface, NULL, 0, NULL)` when `wlr_seat_get_keyboard()` returns NULL. This matches the Sway pattern.

2. **focusclient() - wlr_xwayland_set_seat on every focus change:** Added `wlr_xwayland_set_seat(xwayland, seat)` call before keyboard enter for XWayland clients. Sway does this on every focus change to an X11 client (`sway/input/seat.c:196`). Without this, XWayland may not properly route keyboard events to the X11 client.

3. **mapnotify() - re-deliver keyboard focus after surface maps:** After `printstatus()`, added a block that checks if the just-mapped client is the focused client but doesn't have keyboard focus at the seat level. Re-sends keyboard enter.

4. **mapnotify() - XWayland surface_ready check:** The re-delivery code was using `client_surface(c)->mapped` which is FALSE for XWayland clients even after map event. Changed to use `c->scene != NULL` for XWayland (matching focusclient's surface_ready logic). Also calls `wlr_xwayland_set_seat` for XWayland clients.

**Additional affected case:** Minecraft Java server GUI (Swing/AWT via XWayland) - cannot get keyboard focus at all, even clicking into the console text field doesn't work. Java Swing uses ICCCM "Globally Active" focus model (`WM_HINTS.input=False` + `WM_TAKE_FOCUS` in `WM_PROTOCOLS`). `wlr_xwayland_surface_activate()` should handle this by sending `WM_TAKE_FOCUS` ClientMessage. The `wlr_xwayland_set_seat` fix should help.

**Note:** `client.h` already has a `client_notify_enter()` helper (line 309) that handles NULL keyboard, but `focusclient()` was not using it. The fix duplicates this logic inline for clarity.
