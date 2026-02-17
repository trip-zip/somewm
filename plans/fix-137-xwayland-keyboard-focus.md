# Fix for #137: Steam games frequently lose keyboard focus on launch

**Issue:** https://github.com/trip-zip/somewm/issues/137
**Also fixes:** #135 (keyboard focus desyncs), #133 (Minecraft stuck)
**Fork branch:** https://github.com/raven2cz/somewm/tree/fix/xwayland-keyboard-focus
**Commits:**
- [`fd6ec3d`](https://github.com/raven2cz/somewm/commit/fd6ec3d) fix: XWayland keyboard focus delivery in Lua focus path
- [`d203de4`](https://github.com/raven2cz/somewm/commit/d203de4) fix: XWayland focusable detection via ICCCM input model
- [`aea9cc4`](https://github.com/raven2cz/somewm/commit/aea9cc4) fix: awesome.exec() Lua state use-after-free

## Summary

XWayland clients (games via Steam/Proton, Minecraft Java, etc.) appear
focused (borders change, mouse works) but receive no keyboard input.
The Lua focus path (`client.focus = c`) was missing critical steps that
the C focus path (`focusclient()`) performs.

## Root Cause

When AwesomeWM Lua code sets `client.focus = c`, the setter calls
`some_set_seat_keyboard_focus()` in `somewm_api.c`. This function had
three bugs:

### 1. Missing XWayland/XDG surface activation

`some_set_seat_keyboard_focus()` sent `wlr_seat_keyboard_notify_enter()`
(Wayland-level keyboard focus) but never called `client_activate_surface()`
which calls `wlr_xwayland_surface_activate()` for X11 clients or
`wlr_xdg_toplevel_set_activated()` for native Wayland clients.

Without activation, the X11 window inside XWayland never receives a
`FocusIn` event. The game's input system ignores all keyboard events
because it thinks it's not the active window.

`focusclient()` in `somewm.c` always calls `client_activate_surface()` -
the Lua path simply forgot to.

### 2. Missing pointer constraint update

`focusclient()` calls `cursorconstrain()` after setting keyboard focus.
The Lua path didn't, leaving pointer constraints stale. Games that use
pointer lock (mouse capture) would not get proper constraint updates.

### 3. wlroots drops re-entry to same surface

`wlr_seat_keyboard_enter()` in wlroots (line 237 of
`types/seat/wlr_seat_keyboard.c`) silently returns if the surface is
already focused:

```c
if (seat->keyboard_state.focused_surface == surface) {
    // this surface already got an enter notify
    return;
}
```

This means re-delivering focus to a game that was "already focused"
(but missed the original FocusIn during initialization) is impossible
through the normal API. The fix uses the KWin pattern (KDE MR !60):
clear focus to NULL first, then re-enter.

## The Fix

### somewm_api.c - `some_set_seat_keyboard_focus()`

This is the complete corrected function (without debug logging):

```c
void
some_set_seat_keyboard_focus(Client *c)
{
	struct wlr_surface *surface;
	struct wlr_keyboard *kb;

	if (!c) {
		wlr_seat_keyboard_notify_clear_focus(seat);
		return;
	}

	surface = some_client_get_surface(c);
	if (!surface) {
		wlr_seat_keyboard_notify_clear_focus(seat);
		return;
	}

	/* Check if surface is ready for keyboard input.
	 * For XWayland, use c->scene (set by mapnotify) instead of
	 * wlr_surface->mapped which may be false at map time. */
	int surface_ready;
#ifdef XWAYLAND
	if (c->client_type == X11)
		surface_ready = (c->scene != NULL);
	else
#endif
		surface_ready = surface->mapped;

	if (!surface_ready) {
		wlr_seat_keyboard_notify_clear_focus(seat);
		return;
	}

	/* KWin pattern (MR !60): if re-delivering focus to the same surface,
	 * clear first so wlr_seat_keyboard_enter() doesn't skip it.
	 * Games may miss the initial FocusIn during initialization. */
	if (seat->keyboard_state.focused_surface == surface) {
		client_activate_surface(surface, 0);
		wlr_seat_keyboard_notify_clear_focus(seat);
	} else if (seat->keyboard_state.focused_surface) {
		client_activate_surface(seat->keyboard_state.focused_surface, 0);
	}

	/* Activate the surface (XWayland: wlr_xwayland_surface_activate,
	 * XDG: wlr_xdg_toplevel_set_activated). Without this, X11 games
	 * never know they're the active window. */
	client_activate_surface(surface, 1);

#ifdef XWAYLAND
	if (c->client_type == X11) {
		extern struct wlr_xwayland *xwayland;
		wlr_xwayland_set_seat(xwayland, seat);
	}
#endif

	kb = wlr_seat_get_keyboard(seat);
	if (kb) {
		wlr_seat_keyboard_notify_enter(seat, surface,
		                               kb->keycodes,
		                               kb->num_keycodes,
		                               &kb->modifiers);
	} else {
		wlr_seat_keyboard_notify_enter(seat, surface, NULL, 0, NULL);
	}

	/* Update pointer constraint for mouse lock. */
	some_update_pointer_constraint(surface);
}
```

### somewm.c - Add pointer constraint wrapper

Add before `focusclient()`:

```c
/** Update pointer constraint for a surface.
 * Called from somewm_api.c when Lua changes focus. */
void
some_update_pointer_constraint(struct wlr_surface *surface)
{
	if (!surface)
		return;
	cursorconstrain(wlr_pointer_constraints_v1_constraint_for_surface(
		pointer_constraints, surface, seat));
}
```

### somewm_api.h - Declaration

```c
void some_update_pointer_constraint(struct wlr_surface *surface);
```

### objects/client.c - XWayland focusable fix

In `luaA_client_get_focusable()`, XWayland clients always returned
`focusable=true` because `client_hasproto(c, WM_TAKE_FOCUS)` always
returns false (the WM_TAKE_FOCUS atom stub is 0). Fix by using the
proper ICCCM input model check:

```c
#ifdef XWAYLAND
if (c->client_type == X11) {
	enum wlr_xwayland_icccm_input_model model =
		wlr_xwayland_icccm_input_model(c->surface.xwayland);
	return model == WLR_ICCCM_INPUT_MODEL_PASSIVE ||
	       model == WLR_ICCCM_INPUT_MODEL_LOCAL;
}
#endif
```

## rc.lua workaround for first-launch timing

Games (especially Proton/Wine) may not be ready for input when the
window first maps. A timer-based re-delivery in rc.lua works around this:

```lua
-- Timer-based focus re-delivery for games that aren't ready at map time
do
    local game_focus_timers = {}
    local function stop_game_timer(c)
        if game_focus_timers[c] then
            game_focus_timers[c]:stop()
            game_focus_timers[c] = nil
        end
    end
    local function is_game_client(c)
        return c.class and c.class:match("^steam_app_")
    end
    client.connect_signal("request::manage", function(c)
        gears.timer.start_new(0.5, function()
            if not c.valid or not is_game_client(c) then return false end
            local elapsed = 0
            local max_seconds = 60
            local interval = 2
            local t = gears.timer {
                timeout = interval,
                autostart = true,
                callback = function()
                    elapsed = elapsed + interval
                    if not c.valid or elapsed >= max_seconds then
                        stop_game_timer(c); return
                    end
                    if client.focus ~= c then return end
                    -- KWin pattern: clear then re-set forces FocusIn
                    client.focus = nil
                    client.focus = c
                end,
            }
            game_focus_timers[c] = t
            return false
        end)
    end)
    client.connect_signal("request::unmanage", function(c)
        stop_game_timer(c)
    end)
end
```

## Testing

1. Launch a Steam game (Proton/Wine)
2. Keyboard input should work immediately or within 2-4 seconds
3. Switching away (Super+K) and back should always restore keyboard
4. Mouse pointer lock should work for first-person games

## References

- Sway focus: `sway/input/seat.c:156-209` - `seat_keyboard_notify_enter()`
- KWin MR !60: https://invent.kde.org/plasma/kwin/-/merge_requests/60
- wlroots seat: `types/seat/wlr_seat_keyboard.c:237` - same-surface skip
