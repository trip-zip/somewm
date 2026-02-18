# Fix: Keyboard focus desync from visual focus (sloppy focus / autofocus)

**Status:** DONE
**Branch:** `fix/keyboard-focus-desync`
**Revision:** 2

## Test Results

- 28/28 integration tests PASS (including new test-keyboard-focus-sync.lua)
- No regressions
- Manual testing pending (user will test on live session with NVIDIA RTX 5070 Ti)

## Problem

When using focus-follows-mouse (sloppy focus), the visual focus (border color,
`client.focus` in Lua) updates correctly, but the Wayland keyboard focus
(`seat->keyboard_state.focused_surface`) does not follow. The user sees the
correct window highlighted but cannot type into it. Clicking in the window
with the mouse restores keyboard input.

This happens intermittently but "fairly often" according to the user.

## Root Cause Analysis

### The guard in `client_focus()` (objects/client.c:2065)

```c
void client_focus(client_t *c) {
    if(client_focus_update(c)) {       // returns false when globalconf.focus.client == c
        globalconf.focus.need_update = true;
        some_set_seat_keyboard_focus(c);  // SKIPPED when false
    }
}
```

`client_focus_update()` returns false when `globalconf.focus.client == c` — Lua
thinks the same client is still focused. But `seat->keyboard_state.focused_surface`
(the actual Wayland keyboard focus) can change independently without updating
`globalconf.focus.client`.

### Desync scenarios

**Scenario 1: Layer surface steals keyboard, then unmaps**
1. Window A focused: `globalconf.focus.client = A`, keyboard on A
2. Notification popup (layer surface with keyboard_interactive) maps
3. `layer_surface_grant_keyboard()` → `focusclient(NULL, 0)` → `globalconf.focus.client = NULL`
4. `client_notify_enter(popup_surface)` → keyboard focus on popup
5. Popup unmaps → `unmaplayersurfacenotify()` clears `exclusive_focus = NULL`
6. `arrangelayers()` finds no other keyboard-interactive layer → falls through
7. `motionnotify(0, ...)` restores pointer focus but with `time=0`, mouse::enter is SKIPPED
8. Nobody restores keyboard focus to the top client
9. Mouse is still over A → no `mouse::enter` fires → `client.focus` is never set again
10. **Keyboard lost**

**Scenario 2: Popup/subsurface takes keyboard focus**
1. Window A focused, opens XDG popup or XWayland transient
2. Popup receives keyboard enter (via wlroots internal popup focus)
3. `seat->keyboard_state.focused_surface = popup_surface`
4. `globalconf.focus.client` still = A (popup isn't a separate client)
5. Popup closes, wlroots clears `seat->keyboard_state.focused_surface`
6. Now: `globalconf.focus.client = A`, but seat keyboard focus = NULL
7. Mouse stays on A → no `mouse::enter` → `client.focus = A` doesn't trigger
8. Even if it did: `client_focus_update(A)` returns false → keyboard NOT re-sent
9. **Keyboard lost**

**Scenario 3: Surface recreation (XWayland mode changes)**
1. XWayland game changes video mode → surface destroyed and recreated
2. wlroots clears `seat->keyboard_state.focused_surface`
3. `globalconf.focus.client` still points to the game client
4. `client_focus_update()` returns false → keyboard not re-delivered
5. **Keyboard lost**

### Why clicking fixes it

The user likely moves the mouse slightly when clicking, crossing out and back
into the window area. This triggers `mouse::enter` → `client.focus = c` with a
different `globalconf.focus.client`, making `client_focus_update()` return true.

## Fix Plan

### Change 1: `objects/client.c` — always sync keyboard focus

Remove the `if` guard around `some_set_seat_keyboard_focus()`. Call it
unconditionally so the Wayland keyboard focus is always synced.

```c
void client_focus(client_t *c) {
    extern void some_set_seat_keyboard_focus(client_t *c);

    if(!c && globalconf.clients.len && !(c = globalconf.clients.tab[0]))
        return;

    if(client_focus_update(c)) {
        globalconf.focus.need_update = true;
    }

    /* Always sync seat keyboard focus. client_focus_update() returns false
     * when globalconf.focus.client hasn't changed, but the Wayland seat
     * keyboard focus can desync independently (layer surfaces, popups,
     * surface recreation). some_set_seat_keyboard_focus() handles the
     * already-focused case efficiently with an early return. */
    some_set_seat_keyboard_focus(c);
}
```

### Change 2: `somewm_api.c` — efficient no-op for already-focused case

Replace the KWin same-surface clear+re-enter pattern with an early return.
The KWin pattern was for game focus re-delivery, but the game timer already
handles this by doing `client.focus = nil; client.focus = c` (which clears
keyboard focus first).

```c
// In some_set_seat_keyboard_focus(), replace:
if (seat->keyboard_state.focused_surface == surface) {
    client_activate_surface(surface, 0);
    wlr_seat_keyboard_notify_clear_focus(seat);
}

// With:
if (seat->keyboard_state.focused_surface == surface) {
    wlr_log(WLR_DEBUG, "[FOCUS-API] already correctly focused, skipping");
    return;
}
```

Remove the `else if` for deactivating old surface — it becomes a plain `if`
since the same-surface case returns early.

### Change 3: `somewm.c` — restore focus after exclusive layer surface unmaps

In `unmaplayersurfacenotify()`, after clearing `exclusive_focus`, restore
keyboard focus to the top client (same pattern as `layer_surface_revoke_keyboard()`).

```c
if (l == exclusive_focus) {
    exclusive_focus = NULL;
    focusclient(focustop(selmon), 1);  // restore keyboard focus
}
```

### Change 4: Integration test

Create `tests/test-keyboard-focus-sync.lua` to verify:
1. Focus switch via Lua `client.focus = c` delivers keyboard enter
2. Setting `client.focus = c` when already focused still has keyboard on c
3. After clearing and re-setting focus, keyboard is delivered

## Files to modify

| File | Change |
|------|--------|
| `objects/client.c` | Remove guard around `some_set_seat_keyboard_focus()` |
| `somewm_api.c` | Replace KWin same-surface pattern with early return |
| `somewm.c` | Add `focusclient()` after clearing `exclusive_focus` in unmap |
| `tests/test-keyboard-focus-sync.lua` | Integration test |
| `plans/fix-keyboard-focus-desync.md` | This plan |

## Risk assessment

- **Low risk:** The `some_set_seat_keyboard_focus()` early-return for same-surface
  means no extra protocol traffic when focus is already correct
- **Game timer compatibility:** The `nil` → `c` pattern in rc.lua clears keyboard
  focus first, so the early return doesn't interfere
- **Performance:** `some_set_seat_keyboard_focus()` is called per `client.focus = c`
  setter, not per mouse motion event. The early return makes redundant calls cheap
