# Fix: Pointer enter not delivered to newly visible surfaces

## Problem

When a layer-shell surface (e.g. QS dock panel) appears under the cursor,
hover/focus doesn't work until the user clicks. Same issue occurs generally
across somewm — not QS-specific.

## Root Cause (preliminary)

- `motionnotify()` (somewm.c:3964) correctly finds layer surfaces via `xytonode()`
- `pointerfocus()` (somewm.c:4321) correctly calls `wlr_seat_pointer_notify_enter()`
- BUT deferred pointer enter logic (~line 4362-4367) appears to delay `wl_pointer.enter`
  until keyboard focus is established on the surface
- Click forces pointer enter + button events, which "unsticks" the state

## Why click fixes it

Click triggers `wlr_seat_pointer_notify_button()` which implicitly confirms
pointer focus on the surface. After that, motion/hover events flow normally.

## Affected areas

- Layer-shell surfaces (QS panels: dock, dashboard, control panel)
- Possibly also regular client surfaces on tag switch or new window map
- User reports this is a general somewm behavior, not panel-specific

## Fix direction

- Check `pointerfocus()` deferred enter logic — does it need to re-send
  pointer enter when a NEW surface appears under an already-stationary cursor?
- Compare with Sway's `seat_pointer_notify_enter` in `sway/input/seat.c`
- wlroots `wlr_seat_pointer_notify_enter` should be called whenever the
  surface under cursor changes, even without pointer motion

## Status

Parked — will investigate after QS dock stabilization is complete.
