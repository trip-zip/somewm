# Fix: Stale yellow border on unfocused clients

## Problem

When focus is switched via Wayland foreign-toplevel-management protocol
(e.g. dock panel's `toplevel.activate()`), the previously focused client
keeps its accent border color (`#e2b55a`) despite `active:false`.

## Reproduction

1. Open 2+ windows of same app (e.g. ghostty)
2. Super+X → dock panel
3. Click multi-window icon → preview opens
4. Click a preview card to activate a specific window
5. Previous window still has yellow border, new window also has yellow border
6. Verify: `somewm-client eval` shows `active:false` but `border:#e2b55a`

## Root Cause (preliminary)

Foreign-toplevel activate goes through a different code path than
`focusclient()` in somewm.c. The unfocus path likely misses
`client_set_border_color()` for the old client.

Check:
- `focusclient()` (~line 2302) — does it reset border on prev client?
- foreign-toplevel `handle_activate` — does it call `focusclient()` or bypass it?
- Lua `client::unfocus` signal — does rc.lua handle border reset there?
- `some_set_seat_keyboard_focus()` in somewm_api.c — PATH 2 focus, may skip border update

## Status

Parked — will investigate after QS dock stabilization.
