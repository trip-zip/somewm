# ALFA PROBLEM: Focus / Keyboard Delivery (Dispatch and other games)

**Priority:** ALFA (highest)
**Hardware:** NVIDIA RTX 5070 Ti (proprietary nvidia-drm)
**Status:** FIXED - keyboard focus delivery works after manual switch AND timer re-delivery
**Related issues:** #137, #135, #133

## Problem Statement

Games (Dispatch via Steam, Minecraft Java, etc.) and some clients appear focused
(border color changes, mouse works) but do NOT receive keyboard input.

## Root Causes Found (4 independent bugs)

### Bug 1: Missing `client_activate_surface()` in Lua focus path

**File:** `somewm_api.c` - `some_set_seat_keyboard_focus()`

`some_set_seat_keyboard_focus()` called `wlr_seat_keyboard_notify_enter()` (Wayland
keyboard focus) but **never called `client_activate_surface()`** (XWayland/XDG activation).

- `focusclient()` always calls `client_activate_surface()` at line ~2415
- `some_set_seat_keyboard_focus()` did NOT call it
- For XWayland: `wlr_xwayland_surface_activate()` tells X11 window it's active
- Without it: Wayland seat knows about focus, but X11 game doesn't know it's active

**Fix:** Added `client_activate_surface(surface, 1)` + deactivation of old surface.

### Bug 2: Missing pointer constraint in Lua focus path

**File:** `somewm.c` + `somewm_api.c`

`focusclient()` calls `cursorconstrain()` at line ~2471 for pointer lock.
`some_set_seat_keyboard_focus()` did NOT update pointer constraints.
Games need pointer lock to follow keyboard focus.

**Fix:** Added `some_update_pointer_constraint()` wrapper, called after keyboard enter.

### Bug 3: wlroots silently drops re-delivery to same surface

**File:** `subprojects/wlroots/types/seat/wlr_seat_keyboard.c` line 237

```c
// wlroots internal - wlr_seat_keyboard_enter():
if (seat->keyboard_state.focused_surface == surface) {
    // this surface already got an enter notify
    return;  // <-- SILENTLY DROPS RE-DELIVERY
}
```

When timer re-delivery calls `wlr_seat_keyboard_notify_enter(seat, surface, ...)`
on an already-focused surface, wlroots drops it silently. No keyboard enter event
reaches XWayland, so the game never gets a FocusIn.

**Fix:** KWin MR !60 pattern - clear seat focus first, then re-enter:
```c
if (seat->keyboard_state.focused_surface == surface) {
    client_activate_surface(surface, 0);
    wlr_seat_keyboard_notify_clear_focus(seat);
}
client_activate_surface(surface, 1);
wlr_seat_keyboard_notify_enter(seat, surface, ...);
```

### Bug 4: `client.focus = nil` doesn't clear wlroots seat focus

**File:** `objects/client.c` - `client_unfocus()` / `client_focus_refresh()`

AwesomeWM defers unfocus: `client.focus = nil` sets `globalconf.focus.client = NULL`
and `need_update = true`, but the actual `wlr_seat_keyboard_notify_clear_focus()`
happens later in `client_focus_refresh()`. When Lua does:
```lua
client.focus = nil    -- defers seat clear
client.focus = c      -- called BEFORE deferred clear runs
```
The seat still has the old surface focused, so wlroots drops the re-entry (Bug 3).
This was worked around by implementing the clear+re-enter in C (Bug 3 fix).

## All Changes Made

### somewm_api.c (THE KEY FILE):
1. `client_activate_surface(old_surface, 0)` - deactivate old surface
2. `client_activate_surface(surface, 1)` - activate new surface
3. KWin clear+re-enter pattern for same-surface re-delivery
4. `wlr_xwayland_set_seat()` on every X11 focus (Sway pattern)
5. NULL keyboard handling (Sway pattern)
6. `some_update_pointer_constraint(surface)` - update pointer lock

### somewm.c:
1. `some_update_pointer_constraint()` - new public wrapper for `cursorconstrain()`

### somewm_api.h:
1. Declaration of `some_update_pointer_constraint()`

### objects/client.c:
1. XWayland focusable fix: use `wlr_xwayland_surface_icccm_input_model()`
   instead of `client_hasproto(c, WM_TAKE_FOCUS)` (always returns false since
   WM_TAKE_FOCUS atom stub is 0)

### client.h:
1. Debug logging in `client_activate_surface()` and `client_notify_enter()`

### luaa.c:
1. `awesome_atexit(true)` instead of `false` in `luaA_exec()` -
   prevents destroying Lua state while still inside Lua call

### rc.lua (user config workarounds):
1. Anti-focus-stealing in `mouse::enter` handler
2. `steam_app_*` client rule (no titlebar, focusable)
3. Timer-based focus re-delivery for game windows (60s, 2s interval)

## Key Source Locations

- `somewm_api.c:some_set_seat_keyboard_focus()` ~line 421 - **THE KEY FIX**
- `somewm.c:focusclient()` ~line 2302 - main C focus function (reference)
- `somewm.c:some_update_pointer_constraint()` ~line 2290 - pointer lock wrapper
- `client.h:client_activate_surface()` ~line 104 - XDG/XWayland activation
- `objects/client.c:luaA_client_get_focusable()` - ICCCM input model fix
- `luaa.c:luaA_exec()` ~line 386 - awesome.exec() atexit fix
- wlroots: `types/seat/wlr_seat_keyboard.c:237` - the silent drop
- Sway reference: `sway/input/seat.c:156-209` - working focus implementation
- KWin reference: MR !60 - clear+re-focus pattern for same-surface FocusIn
