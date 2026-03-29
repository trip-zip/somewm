/* input.c - Input handling for somewm compositor */

#include <libinput.h>
#include <linux/input-event-codes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/libinput.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_cursor_shape_v1.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_keyboard_group.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_pointer_gestures_v1.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/util/log.h>
#include <wlr/util/region.h>
#include <xkbcommon/xkbcommon.h>

#include "somewm.h"
#include "somewm_api.h"
#include "input.h"
#include "event_queue.h"
#include "monitor.h"
#include "globalconf.h"
#include "client.h"
#include "common/luaobject.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/drawable.h"
#include "objects/keybinding.h"
#include "objects/keygrabber.h"
#include "objects/mousegrabber.h"
#include "objects/gesture.h"
#include "objects/layer_surface.h"
#include "objects/button.h"
#include "objects/root.h"
#include "objects/signal.h"
#include "event.h"
#include "xkb.h"
#include <wlr/types/wlr_virtual_keyboard_v1.h>
#include <wlr/types/wlr_virtual_pointer_v1.h>

/* macros */
#define CLEANMASK(mask) (mask & ~WLR_MODIFIER_CAPS & ~WLR_MODIFIER_MOD2)

#include "focus.h"
#include "window.h"
#include "somewm_internal.h"
#include "bench.h"

/* Module-private state */
static unsigned int cursor_mode;
static bool gesture_swipe_consumed = false;
static bool gesture_pinch_consumed = false;
static bool gesture_hold_consumed = false;

/* Forward declarations */
void axisnotify(struct wl_listener *listener, void *data);
void buttonpress(struct wl_listener *listener, void *data);
void cursorframe(struct wl_listener *listener, void *data);
void motionrelative(struct wl_listener *listener, void *data);
void motionabsolute(struct wl_listener *listener, void *data);
void inputdevice(struct wl_listener *listener, void *data);
void virtualkeyboard(struct wl_listener *listener, void *data);
void virtualpointer(struct wl_listener *listener, void *data);
void createpointerconstraint(struct wl_listener *listener, void *data);
void gestureswipebegin(struct wl_listener *listener, void *data);
void gestureswipeupdate(struct wl_listener *listener, void *data);
void gestureswipeend(struct wl_listener *listener, void *data);
void gesturepinchbegin(struct wl_listener *listener, void *data);
void gesturepinchupdate(struct wl_listener *listener, void *data);
void gesturepinchend(struct wl_listener *listener, void *data);
void gestureholdbegin(struct wl_listener *listener, void *data);
void gestureholdend(struct wl_listener *listener, void *data);
void destroypointerconstraint(struct wl_listener *listener, void *data);
static void destroytrackedpointer(struct wl_listener *listener, void *data);
void motionnotify(uint32_t time, struct wlr_input_device *device, double dx, double dy,
		double dx_unaccel, double dy_unaccel);
void pointerfocus(Client *c, struct wlr_surface *surface, double sx, double sy,
		uint32_t time);
int keybinding(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);
void createkeyboard(struct wlr_keyboard *keyboard);
KeyboardGroup *createkeyboardgroup(void);
void createpointer(struct wlr_pointer *pointer);
void cursorconstrain(struct wlr_pointer_constraint_v1 *constraint);
void cursorwarptohint(void);
void apply_input_settings_to_device(struct libinput_device *device);
void mouse_emit_leave(lua_State *L);
void mouse_emit_client_enter(lua_State *L, client_t *c);
void mouse_emit_drawin_enter(lua_State *L, drawin_t *d);
void setcursor(struct wl_listener *listener, void *data);
void setcursorshape(struct wl_listener *listener, void *data);
void keypress(struct wl_listener *listener, void *data);
void keypressmod(struct wl_listener *listener, void *data);
int keyrepeat(void *data);
bool drawin_accepts_input_at(drawin_t *d, double local_x, double local_y);
void setpsel(struct wl_listener *listener, void *data);
void setsel(struct wl_listener *listener, void *data);
void requeststartdrag(struct wl_listener *listener, void *data);
void startdrag(struct wl_listener *listener, void *data);
void destroydrag(struct wl_listener *listener, void *data);
void destroydragicon(struct wl_listener *listener, void *data);
void xytonode(double x, double y, struct wlr_surface **psurface,
		Client **pc, LayerSurface **pl, drawin_t **pd, drawable_t **pdrawable,
		double *nx, double *ny);

/* Tracked pointer device for runtime libinput configuration */
typedef struct {
	struct libinput_device *libinput_dev;
	struct wl_listener destroy;
	struct wl_list link;
} TrackedPointer;

/* Listener structs */
struct wl_listener cursor_axis = {.notify = axisnotify};
struct wl_listener cursor_button = {.notify = buttonpress};
struct wl_listener cursor_frame = {.notify = cursorframe};
struct wl_listener cursor_motion = {.notify = motionrelative};
struct wl_listener cursor_motion_absolute = {.notify = motionabsolute};
struct wl_listener new_input_device = {.notify = inputdevice};
struct wl_listener new_virtual_keyboard = {.notify = virtualkeyboard};
struct wl_listener new_virtual_pointer = {.notify = virtualpointer};
struct wl_listener new_pointer_constraint = {.notify = createpointerconstraint};
struct wl_listener gesture_swipe_begin = {.notify = gestureswipebegin};
struct wl_listener gesture_swipe_update = {.notify = gestureswipeupdate};
struct wl_listener gesture_swipe_end = {.notify = gestureswipeend};
struct wl_listener gesture_pinch_begin = {.notify = gesturepinchbegin};
struct wl_listener gesture_pinch_update = {.notify = gesturepinchupdate};
struct wl_listener gesture_pinch_end = {.notify = gesturepinchend};
struct wl_listener gesture_hold_begin = {.notify = gestureholdbegin};
struct wl_listener gesture_hold_end = {.notify = gestureholdend};
struct wl_listener request_cursor = {.notify = setcursor};
struct wl_listener request_set_psel = {.notify = setpsel};
struct wl_listener request_set_sel = {.notify = setsel};
struct wl_listener request_set_cursor_shape = {.notify = setcursorshape};
struct wl_listener request_start_drag = {.notify = requeststartdrag};
struct wl_listener start_drag = {.notify = startdrag};

void
gestureswipebegin(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_swipe_begin_event *event = data;
	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	gesture_swipe_consumed = luaA_gesture_check_swipe_begin(
		event->time_msec, event->fingers);
	if (!gesture_swipe_consumed)
		wlr_pointer_gestures_v1_send_swipe_begin(pointer_gestures,
			seat, event->time_msec, event->fingers);
}

void
gestureswipeupdate(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_swipe_update_event *event = data;
	luaA_gesture_check_swipe_update(
		event->time_msec, event->fingers, event->dx, event->dy);
	if (!gesture_swipe_consumed)
		wlr_pointer_gestures_v1_send_swipe_update(pointer_gestures,
			seat, event->time_msec, event->dx, event->dy);
}

void
gestureswipeend(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_swipe_end_event *event = data;
	luaA_gesture_check_swipe_end(event->time_msec, event->cancelled);
	if (!gesture_swipe_consumed)
		wlr_pointer_gestures_v1_send_swipe_end(pointer_gestures,
			seat, event->time_msec, event->cancelled);
	gesture_swipe_consumed = false;
}

void
gesturepinchbegin(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_pinch_begin_event *event = data;
	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	gesture_pinch_consumed = luaA_gesture_check_pinch_begin(
		event->time_msec, event->fingers);
	if (!gesture_pinch_consumed)
		wlr_pointer_gestures_v1_send_pinch_begin(pointer_gestures,
			seat, event->time_msec, event->fingers);
}

void
gesturepinchupdate(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_pinch_update_event *event = data;
	luaA_gesture_check_pinch_update(
		event->time_msec, event->fingers,
		event->dx, event->dy, event->scale, event->rotation);
	if (!gesture_pinch_consumed)
		wlr_pointer_gestures_v1_send_pinch_update(pointer_gestures,
			seat, event->time_msec,
			event->dx, event->dy, event->scale, event->rotation);
}

void
gesturepinchend(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_pinch_end_event *event = data;
	luaA_gesture_check_pinch_end(event->time_msec, event->cancelled);
	if (!gesture_pinch_consumed)
		wlr_pointer_gestures_v1_send_pinch_end(pointer_gestures,
			seat, event->time_msec, event->cancelled);
	gesture_pinch_consumed = false;
}

void
gestureholdbegin(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_hold_begin_event *event = data;
	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	gesture_hold_consumed = luaA_gesture_check_hold_begin(
		event->time_msec, event->fingers);
	if (!gesture_hold_consumed)
		wlr_pointer_gestures_v1_send_hold_begin(pointer_gestures,
			seat, event->time_msec, event->fingers);
}

void
gestureholdend(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_hold_end_event *event = data;
	luaA_gesture_check_hold_end(event->time_msec, event->cancelled);
	if (!gesture_hold_consumed)
		wlr_pointer_gestures_v1_send_hold_end(pointer_gestures,
			seat, event->time_msec, event->cancelled);
	gesture_hold_consumed = false;
}

void
axisnotify(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits an axis event,
	 * for example when you move the scroll wheel. */
	struct wlr_pointer_axis_event *event = data;
	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	some_notify_activity();

	/* If mousegrabber is active, route event to Lua callback */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		int button_states[5];
		uint16_t mask = 0;

		/* Get current button states */
		some_get_button_states(button_states);

		/* Convert button_states array to X11-style mask */
		for (int i = 0; i < 5; i++) {
			if (button_states[i])
				mask |= (1 << (8 + i));
		}

		/* Push coords table to Lua stack */
		mousegrabber_handleevent(L, cursor->x, cursor->y, mask);

		/* Get the callback from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

		/* Push coords table as argument */
		lua_pushvalue(L, -2);

		/* Call callback(coords) */
		if (lua_pcall(L, 1, 1, 0) == 0) {
			/* Check return value */
			int continue_grab = lua_toboolean(L, -1);
			lua_pop(L, 1); /* Pop return value */

			if (!continue_grab) {
				/* Callback returned false, stop grabbing */
				luaA_mousegrabber_stop(L);
			}
		} else {
			/* Error in callback */
			fprintf(stderr, "somewm: mousegrabber callback error: %s\n",
				lua_tostring(L, -1));
			lua_pop(L, 1);
			luaA_mousegrabber_stop(L);
		}

		lua_pop(L, 1); /* Pop coords table */
		return; /* Don't process event further */
	}

	/* Handle scroll wheel for mousebindings (AwesomeWM compatibility)
	 * Convert axis events to X11-style button 4/5/6/7 press+release events.
	 * In X11, each scroll tick generates a button press+release pair.
	 *
	 * Wayland uses "value120" for discrete scroll: one standard wheel click
	 * sends delta_discrete=±120. High-resolution mice send smaller steps
	 * (e.g. ±15 or ±30). We accumulate until a full step (±120) is reached
	 * to avoid multiple tag switches per physical wheel click. */
	if (!session_is_locked() && event->delta != 0) {
		/* NOTE: process-global accumulators shared across all pointer devices.
		 * Multi-mouse interleaving is possible but negligible in practice. */
		static int32_t scroll_acc_v = 0;
		static int32_t scroll_acc_h = 0;
		int32_t *acc;
		int ticks = 0;

		acc = (event->orientation == WL_POINTER_AXIS_VERTICAL_SCROLL)
			? &scroll_acc_v : &scroll_acc_h;

		if (event->delta_discrete != 0) {
			/* Discrete scroll (wheel): accumulate value120 steps */
			*acc += event->delta_discrete;
			/* Count full steps (±120 each) */
			while (*acc >= 120) { ticks++; *acc -= 120; }
			while (*acc <= -120) { ticks++; *acc += 120; }
		} else {
			/* Continuous scroll (touchpad/smooth): use delta directly,
			 * one button event per axis event (no accumulation) */
			ticks = 1;
		}

		/* Reset accumulator on direction change to prevent stale state */
		if ((event->delta > 0 && *acc < 0) || (event->delta < 0 && *acc > 0))
			*acc = 0;

		for (int tick = 0; tick < ticks; tick++) {
			lua_State *L = globalconf_get_lua_State();
			struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
			uint32_t mods = keyboard ? wlr_keyboard_get_modifiers(keyboard) : 0;
			Client *c = NULL;
			drawin_t *drawin = NULL;
			drawable_t *titlebar_drawable = NULL;
			uint32_t button;
			int rel_x, rel_y;

			/* Determine button number based on axis orientation and direction */
			if (event->orientation == WL_POINTER_AXIS_VERTICAL_SCROLL) {
				button = (event->delta < 0) ? 4 : 5;
			} else {
				button = (event->delta < 0) ? 6 : 7;
			}

			/* Find what's under the cursor */
			xytonode(cursor->x, cursor->y, NULL, &c, NULL, &drawin, &titlebar_drawable, NULL, NULL);

			if (drawin) {
				/* Scroll on drawin (wibox) */
				rel_x = (int)cursor->x - drawin->x;
				rel_y = (int)cursor->y - drawin->y;

				/* Emit press then release (scroll is instantaneous) */
				luaA_drawin_button_check(drawin, rel_x, rel_y, button, CLEANMASK(mods), true);
				luaA_drawin_button_check(drawin, rel_x, rel_y, button, CLEANMASK(mods), false);
			} else if (c && (!client_is_unmanaged(c) || client_wants_focus(c))) {
				/* Scroll on client */
				rel_x = (int)cursor->x - c->geometry.x;
				rel_y = (int)cursor->y - c->geometry.y;

				/* Emit on titlebar drawable if applicable */
				if (titlebar_drawable) {
					luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, button,
					                          CLEANMASK(mods), true);
					luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, button,
					                          CLEANMASK(mods), false);
				}

				/* Emit on client (press + release) */
				luaA_client_button_check(c, rel_x, rel_y, button, CLEANMASK(mods), true);
				luaA_client_button_check(c, rel_x, rel_y, button, CLEANMASK(mods), false);
			} else {
				/* Scroll on root/empty space */
				luaA_root_button_check(L, button, CLEANMASK(mods), cursor->x, cursor->y, true);
				luaA_root_button_check(L, button, CLEANMASK(mods), cursor->x, cursor->y, false);
			}
		}
	}

	/* Notify the client with pointer focus of the axis event. */
	wlr_seat_pointer_notify_axis(seat,
			event->time_msec, event->orientation, event->delta,
			event->delta_discrete, event->source, event->relative_direction);
}

void
buttonpress(struct wl_listener *listener, void *data)
{
#ifdef SOMEWM_BENCH
	bench_input_event_record();
#endif
	struct wlr_pointer_button_event *event = data;
	struct wlr_keyboard *keyboard;
	uint32_t mods;
	Client *c;

	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	some_notify_activity();

	/* Update globalconf button state tracking FIRST, before any early returns.
	 * This ensures mousegrabber callbacks receive accurate button states.
	 * Map wlroots button codes (BTN_LEFT=0x110, etc.) to indices 0-4.
	 */
	{
		int idx = -1;
		switch (event->button) {
		case 0x110: idx = 0; break;  /* BTN_LEFT -> button 1 */
		case 0x112: idx = 1; break;  /* BTN_MIDDLE -> button 2 */
		case 0x111: idx = 2; break;  /* BTN_RIGHT -> button 3 */
		case 0x113: idx = 3; break;  /* BTN_SIDE -> button 4 */
		case 0x114: idx = 4; break;  /* BTN_EXTRA -> button 5 */
		}
		if (idx >= 0) {
			globalconf.button_state.buttons[idx] =
				(event->state == WL_POINTER_BUTTON_STATE_PRESSED);
		}
	}

	/* If mousegrabber is active, route event to Lua callback */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		int button_states[5];
		uint16_t mask = 0;

		/* Get current button states */
		some_get_button_states(button_states);

		/* Convert button_states array to X11-style mask */
		for (int i = 0; i < 5; i++) {
			if (button_states[i])
				mask |= (1 << (8 + i));
		}

		/* Push coords table to Lua stack */
		mousegrabber_handleevent(L, cursor->x, cursor->y, mask);

		/* Get the callback from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

		/* Push coords table as argument */
		lua_pushvalue(L, -2);

		/* Call callback(coords) */
		if (lua_pcall(L, 1, 1, 0) == 0) {
			/* Check return value */
			int continue_grab = lua_toboolean(L, -1);
			lua_pop(L, 1); /* Pop return value */

			if (!continue_grab) {
				/* Callback returned false, stop grabbing */
				luaA_mousegrabber_stop(L);
			}
		} else {
			/* Error in callback */
			fprintf(stderr, "somewm: mousegrabber callback error: %s\n",
				lua_tostring(L, -1));
			lua_pop(L, 1);
			luaA_mousegrabber_stop(L);
		}

		lua_pop(L, 1); /* Pop coords table */
		return; /* Don't process event further */
	}

	switch (event->state) {
	case WL_POINTER_BUTTON_STATE_PRESSED: {
		Monitor *mon;
		LayerSurface *l = NULL;
		drawin_t *drawin = NULL;
		drawable_t *titlebar_drawable = NULL;
		int rel_x, rel_y;

		cursor_mode = CurPressed;
		if (locked)
			break;

		/* Change focus if the button was _pressed_ over a client or layer surface */
		xytonode(cursor->x, cursor->y, NULL, &c, &l, &drawin, &titlebar_drawable, NULL, NULL);

		/* For Lua lock, only allow interaction with the lock surface */
		if (some_is_lua_locked() && drawin != some_get_lua_lock_surface())
			return;

		/* Get keyboard modifiers */
		keyboard = wlr_seat_get_keyboard(seat);
		mods = keyboard ? wlr_keyboard_get_modifiers(keyboard) : 0;

		/* Check if a drawin was clicked */
		if (drawin) {
			/* Calculate drawin-relative coordinates */
			rel_x = (int)cursor->x - drawin->x;
			rel_y = (int)cursor->y - drawin->y;

			/* Check drawin-specific button array (AwesomeWM-compatible two-stage emission) */
			if (luaA_drawin_button_check(drawin, rel_x, rel_y, event->button,
			                             CLEANMASK(mods), true)) {
				return;
			}

			} else if (c && (!client_is_unmanaged(c) || client_wants_focus(c))) {
			/* Calculate client-relative coordinates */
			rel_x = (int)cursor->x - c->geometry.x;
			rel_y = (int)cursor->y - c->geometry.y;

			/* If click is on a titlebar drawable, emit button signal on it
			 * This matches AwesomeWM's event.c:76-84 where they call event_emit_button on titlebar drawable */
			if (titlebar_drawable) {
				luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, event->button,
				                          CLEANMASK(mods), true);
			}

			/* Check client button array (AwesomeWM-compatible two-stage emission)
			 * This enables awful.mouse.client.move() and resize() to work via
			 * client button bindings defined in rc.lua
			 * Note: Unlike root/drawin handlers, we don't return early here.
			 * AwesomeWM always passes clicks through to clients (XCB_ALLOW_REPLAY_POINTER),
			 * so button bindings act as transparent observers, not consumers. */
			luaA_client_button_check(c, rel_x, rel_y, event->button,
			                        CLEANMASK(mods), true);
		} else if (l && l->lua_object) {
			/* Layer surface was clicked - grant keyboard focus if it wants it */
			uint32_t kb_mode = l->layer_surface->current.keyboard_interactive;
			if (kb_mode == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE ||
			    kb_mode == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND) {
				/* Emit signal for Lua to observe, then grant focus */
				layer_surface_emit_request_keyboard(l->lua_object, "click");
				/* Set focus state and emit property signal */
				if (!l->lua_object->has_keyboard_focus) {
					lua_State *Ls = globalconf_get_lua_State();
					l->lua_object->has_keyboard_focus = true;
					luaA_object_push(Ls, l->lua_object);
					luaA_object_emit_signal(Ls, -1, "property::has_keyboard_focus", 0);
					lua_pop(Ls, 1);
				}
				layer_surface_grant_keyboard(l);
			}
		}

		/* Check root button bindings (ONLY for empty space, not client clicks) */
		if (!c && !l) {
			lua_State *L = globalconf_get_lua_State();

			/* Check root button bindings */
			if (luaA_root_button_check(L, event->button, CLEANMASK(mods),
			                           cursor->x, cursor->y, true) > 0) {
				/* Root button binding matched and handled */
				return;
			}

			/* No root binding matched - update selmon based on cursor position */
			mon = xytomon(cursor->x, cursor->y);
			if (mon && mon != selmon) {
				selmon = mon;
				/* Emit signal so Lua knows monitor changed */
				luaA_emit_signal_global("screen::focus");
			}
		}

		break;
	}
	case WL_POINTER_BUTTON_STATE_RELEASED: {
		drawin_t *drawin = NULL;
		drawable_t *titlebar_drawable = NULL;

		/* NOTE: C-level move/resize exit handling removed - Lua mousegrabber handles this now */
		cursor_mode = CurNormal;

		/* Check if a drawin was released over */
		if (!session_is_locked()) {
			xytonode(cursor->x, cursor->y, NULL, &c, NULL, &drawin, &titlebar_drawable, NULL, NULL);

			/* Get keyboard modifiers */
			keyboard = wlr_seat_get_keyboard(seat);
			mods = keyboard ? wlr_keyboard_get_modifiers(keyboard) : 0;

			if (drawin) {
				/* Calculate drawin-relative coordinates */
				int rel_x = (int)cursor->x - drawin->x;
				int rel_y = (int)cursor->y - drawin->y;

				/* Emit button release signals (AwesomeWM-compatible) */
				if (luaA_drawin_button_check(drawin, rel_x, rel_y, event->button,
				                             CLEANMASK(mods), false)) {
					return;
				}
			} else if (c) {
				/* Released on client - check client button bindings */
				int rel_x = (int)cursor->x - c->geometry.x;
				int rel_y = (int)cursor->y - c->geometry.y;

				/* If release is on a titlebar drawable, emit button signal on it */
				if (titlebar_drawable) {
					luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, event->button,
					                          CLEANMASK(mods), false);
				}

				/* Emit button release signals on client (AwesomeWM-compatible)
				 * Like press events, releases are passed through to the client. */
				luaA_client_button_check(c, rel_x, rel_y, event->button,
				                        CLEANMASK(mods), false);
			} else {
				/* Released on empty space - check root button bindings */
				lua_State *L = globalconf_get_lua_State();

				/* Check root button bindings for release event */
				if (luaA_root_button_check(L, event->button, CLEANMASK(mods),
				                           cursor->x, cursor->y, false) > 0) {
					/* Root button release binding matched and handled */
					return;
				}
			}
		}
		break;
	}
	}

	/* Don't forward button event to client if mousegrabber started during
	 * Lua callback processing (e.g., awful.mouse.client.move() grabbed it).
	 * This ensures symmetric handling: if the press was consumed by starting
	 * a mousegrabber, the client never sees either press or release. */
	if (mousegrabber_isrunning()) {
		return;
	}

	/* If the event wasn't handled by the compositor, notify the client with
	 * pointer focus that a button press has occurred */
	wlr_seat_pointer_notify_button(seat,
			event->time_msec, event->button, event->state);
}

void
cursorframe(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits a frame
	 * event. Frame events are sent after regular pointer events to group
	 * multiple events together. For instance, two axis events may happen at the
	 * same time, in which case a frame event won't be sent in between. */
	/* Notify the client with pointer focus of the frame event. */
	wlr_seat_pointer_notify_frame(seat);
}

void
motionrelative(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits a _relative_
	 * pointer motion event (i.e. a delta) */
	struct wlr_pointer_motion_event *event = data;
	/* The cursor doesn't move unless we tell it to. The cursor automatically
	 * handles constraining the motion to the output layout, as well as any
	 * special configuration applied for the specific input device which
	 * generated the event. You can pass NULL for the device if you want to move
	 * the cursor around without any input. */
	motionnotify(event->time_msec, &event->pointer->base, event->delta_x, event->delta_y,
			event->unaccel_dx, event->unaccel_dy);
}

void
motionabsolute(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits an _absolute_
	 * motion event, from 0..1 on each axis. This happens, for example, when
	 * wlroots is running under a Wayland window rather than KMS+DRM, and you
	 * move the mouse over the window. You could enter the window from any edge,
	 * so we have to warp the mouse there. Also, some hardware emits these events. */
	struct wlr_pointer_motion_absolute_event *event = data;
	double lx, ly, dx, dy;

	if (!event->time_msec) /* this is 0 with virtual pointers */
		wlr_cursor_warp_absolute(cursor, &event->pointer->base, event->x, event->y);

	wlr_cursor_absolute_to_layout_coords(cursor, &event->pointer->base, event->x, event->y, &lx, &ly);
	dx = lx - cursor->x;
	dy = ly - cursor->y;
	motionnotify(event->time_msec, &event->pointer->base, dx, dy, dx, dy);
}

/* Helper function to emit mouse::leave on the object that previously had the mouse.
 * Also clears drawable_under_mouse tracking to emit leave on the drawable. */
void
mouse_emit_leave(lua_State *L)
{
	if (globalconf.mouse_under.type == UNDER_CLIENT) {
		client_t *c = globalconf.mouse_under.ptr.client;
		luaA_object_push(L, c);
		some_event_queue_property(L, -1, SIG_MOUSE_LEAVE);
		lua_pop(L, 1);
	} else if (globalconf.mouse_under.type == UNDER_DRAWIN) {
		drawin_t *d = globalconf.mouse_under.ptr.drawin;
		luaA_object_push(L, d);
		if (lua_isnil(L, -1)) {
			warn("mouse::leave on unregistered drawin %p", (void*)d);
		}
		some_event_queue_property(L, -1, SIG_MOUSE_LEAVE);
		lua_pop(L, 1);
	}
	globalconf.mouse_under.type = UNDER_NONE;

	/* Also clear drawable tracking - emit leave on drawable if any */
	if (globalconf.drawable_under_mouse != NULL) {
		luaA_object_push(L, globalconf.drawable_under_mouse);
		some_event_queue_property(L, -1, SIG_MOUSE_LEAVE);
		lua_pop(L, 1);
		luaA_object_unref(L, globalconf.drawable_under_mouse);
		globalconf.drawable_under_mouse = NULL;
	}
}

/* Helper function to emit mouse::enter on a client */
void
mouse_emit_client_enter(lua_State *L, client_t *c)
{
	luaA_object_push(L, c);
	some_event_queue_property(L, -1, SIG_MOUSE_ENTER);
	lua_pop(L, 1);
	globalconf.mouse_under.type = UNDER_CLIENT;
	globalconf.mouse_under.ptr.client = c;
}

/* Helper function to emit mouse::enter on a drawin */
void
mouse_emit_drawin_enter(lua_State *L, drawin_t *d)
{
	luaA_object_push(L, d);
	if (lua_isnil(L, -1)) {
		warn("mouse::enter on unregistered drawin %p", (void*)d);
	}
	some_event_queue_property(L, -1, SIG_MOUSE_ENTER);
	lua_pop(L, 1);
	globalconf.mouse_under.type = UNDER_DRAWIN;
	globalconf.mouse_under.ptr.drawin = d;
}

void
motionnotify(uint32_t time, struct wlr_input_device *device, double dx, double dy,
		double dx_unaccel, double dy_unaccel)
{
#ifdef SOMEWM_BENCH
	bench_input_event_record();
#endif
	double sx = 0, sy = 0, sx_confined, sy_confined;
	Client *c = NULL, *w = NULL;
	LayerSurface *l = NULL;
	struct wlr_surface *surface = NULL;

	/* Find the client under the pointer and send the event along. */
	xytonode(cursor->x, cursor->y, &surface, &c, NULL, NULL, NULL, &sx, &sy);

	if (cursor_mode == CurPressed && !seat->drag
			&& surface != seat->pointer_state.focused_surface
			&& toplevel_from_wlr_surface(seat->pointer_state.focused_surface, &w, &l) >= 0) {
		c = w;
		surface = seat->pointer_state.focused_surface;
		sx = cursor->x - (l ? l->scene->node.x : w->geometry.x);
		sy = cursor->y - (l ? l->scene->node.y : w->geometry.y);
	}

	/* time is 0 in internal calls meant to restore pointer focus. */
	if (time) {
		wlr_relative_pointer_manager_v1_send_relative_motion(
				relative_pointer_mgr, seat, (uint64_t)time * 1000,
				dx, dy, dx_unaccel, dy_unaccel);

		/* Note: Constraint selection is done in focusclient(), not here.
		 * dwl/somewm previously iterated all constraints here which caused
		 * the "last constraint wins" bug breaking games like Minecraft. */

		if (active_constraint) {
			toplevel_from_wlr_surface(active_constraint->surface, &c, NULL);
			if (c && active_constraint->surface == seat->pointer_state.focused_surface) {
				sx = cursor->x - c->geometry.x - c->bw;
				sy = cursor->y - c->geometry.y - c->bw;
				if (wlr_region_confine(&active_constraint->region, sx, sy,
						sx + dx, sy + dy, &sx_confined, &sy_confined)) {
					dx = sx_confined - sx;
					dy = sy_confined - sy;
				}

				if (active_constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED)
					return;
			}
		}

		wlr_cursor_move(cursor, device, dx, dy);
		wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
		some_notify_activity();

		/* Update selected monitor when cursor crosses monitor boundaries.
		 * Without this, layer-shell clients (rofi, etc.) that don't specify
		 * an output get assigned to the stale selmon in createlayersurface(). */
		{
			Monitor *mon = xytomon(cursor->x, cursor->y);
			if (mon && mon != selmon)
				selmon = mon;
		}
	}

	/* Update drag icon's position */
	wlr_scene_node_set_position(&drag_icon->node, (int)round(cursor->x), (int)round(cursor->y));


	/* If drag source became invalid, clear it. */
	if (seat->drag && drag_source_client) {
		bool valid = false;
		foreach(elem, globalconf.clients)
			if (*elem == drag_source_client) { valid = true; break; }
		if (!valid)
			drag_source_client = NULL;
	}

	/* During active drag over compositor surfaces (wibars), don't clear
	 * drag focus - that would cancel the drag on drop. Instead, keep
	 * sending motion events with coordinates projected onto the focused
	 * surface so the source app knows the pointer is outside its window
	 * (e.g., Firefox uses out-of-bounds coords to trigger tab detach). */
	if (seat->drag && drag_source_client && !surface) {
		struct wlr_surface *source_surface = client_surface(drag_source_client);
		if (source_surface) {
			double fx, fy;
			cursor_to_client_coordinates(drag_source_client, &fx, &fy);
			if (seat->pointer_state.focused_surface != source_surface)
				wlr_seat_pointer_notify_enter(seat, source_surface, fx, fy);
			wlr_seat_pointer_notify_motion(seat, time, fx, fy);
		}
		return;
	}

	/* If mousegrabber is active, route event to Lua callback (AwesomeWM behavior:
	 * check mousegrabber BEFORE enter/leave signals to filter them during grabs) */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		int button_states[5];
		uint16_t mask = 0;

		/* Get current button states */
		some_get_button_states(button_states);

		/* Convert button_states array to X11-style mask */
		for (int i = 0; i < 5; i++) {
			if (button_states[i])
				mask |= (1 << (8 + i));
		}

		/* Push coords table to Lua stack */
		mousegrabber_handleevent(L, cursor->x, cursor->y, mask);

		/* Get the callback from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

		/* Push coords table as argument */
		lua_pushvalue(L, -2);

		/* Call callback(coords) */
		if (lua_pcall(L, 1, 1, 0) == 0) {
			/* Check return value */
			int continue_grab = lua_toboolean(L, -1);
			lua_pop(L, 1); /* Pop return value */

			if (!continue_grab) {
				/* Callback returned false, stop grabbing */
				luaA_mousegrabber_stop(L);
			}
		} else {
			/* Error in callback */
			fprintf(stderr, "somewm: mousegrabber callback error: %s\n",
				lua_tostring(L, -1));
			lua_pop(L, 1);
			luaA_mousegrabber_stop(L);
		}

		lua_pop(L, 1); /* Pop coords table */
		return; /* Don't process event further (skip enter/leave signals, pointerfocus) */
	}

	/* Track which object is under the cursor and emit enter/leave/move signals
	 * (only when mousegrabber is NOT active - filtered above) */
	if (time && !globalconf.mouse_under.ignore_next_enter_leave) {
		lua_State *L = globalconf_get_lua_State();
		Client *current_client = NULL;
		drawin_t *current_drawin = NULL;
		drawable_t *titlebar_drawable = NULL;
		bool client_valid = false;

		/* Find what's under cursor */
		xytonode(cursor->x, cursor->y, NULL, &current_client, NULL, &current_drawin, &titlebar_drawable, NULL, NULL);

		/* Validate client pointer - xytonode can return stale pointers from scene graph
		 * if a node's data field wasn't cleared when the client was destroyed */
		if (current_client) {
			foreach(elem, globalconf.clients) {
				if (*elem == current_client) {
					client_valid = true;
					break;
				}
			}
			if (!client_valid) {
				current_client = NULL;  /* Ignore stale/invalid client pointer */
			}
		}

		if (current_client) {
			/* Mouse is over a client */
			if (globalconf.mouse_under.type != UNDER_CLIENT ||
			    globalconf.mouse_under.ptr.client != current_client) {
				/* Different object - emit leave on old, enter on new */
				mouse_emit_leave(L);
				mouse_emit_client_enter(L, current_client);
			}

			/* Always emit mouse::move on current client (coalesced per frame) */
			luaA_object_push(L, current_client);
			if (lua_isnil(L, -1)) {
				warn("mouse::move on unregistered client %p", (void*)current_client);
			}
			some_event_queue_move(L, -1,
				(int)(cursor->x - current_client->geometry.x),
				(int)(cursor->y - current_client->geometry.y));
			lua_pop(L, 1);

			/* Check if mouse is over a titlebar drawable - emit signals for widget hover */
			if (titlebar_drawable) {
				luaA_object_push(L, current_client);
				luaA_object_push_item(L, -1, titlebar_drawable);
				if (lua_isnil(L, -1)) {
					lua_pop(L, 2);
				} else {
				event_drawable_under_mouse(L, -1);

				/* Emit mouse::move on titlebar drawable with local coordinates */
				int tb_x = (int)(cursor->x - current_client->geometry.x);
				int tb_y = (int)(cursor->y - current_client->geometry.y);
				client_get_drawable_offset(current_client, &tb_x, &tb_y);
				some_event_queue_move(L, -1, tb_x, tb_y);

				lua_pop(L, 2);  /* pop drawable and client */
				}
			} else if (globalconf.drawable_under_mouse) {
				/* Left titlebar area - emit leave on previous drawable */
				lua_pushnil(L);
				event_drawable_under_mouse(L, -1);
				lua_pop(L, 1);
			}

		} else if (current_drawin) {
			/* Mouse over drawin - emit signals on drawable for widget hover */
			if (globalconf.mouse_under.type != UNDER_DRAWIN ||
			    globalconf.mouse_under.ptr.drawin != current_drawin) {
				mouse_emit_leave(L);
				mouse_emit_drawin_enter(L, current_drawin);
			}

			luaA_object_push(L, current_drawin);
			if (lua_isnil(L, -1)) {
				warn("mouse event on unregistered drawin %p", (void*)current_drawin);
				lua_pop(L, 1);
			} else {
				luaA_object_push_item(L, -1, current_drawin->drawable);
				event_drawable_under_mouse(L, -1);

				some_event_queue_move(L, -1,
					(int)cursor->x - current_drawin->x,
					(int)cursor->y - current_drawin->y);

				lua_pop(L, 2);
			}

		} else {
			/* Mouse is over empty space - emit leave if we were over something */
			if (globalconf.mouse_under.type != UNDER_NONE) {
				mouse_emit_leave(L);
			}
		}
	}

	/* Reset the ignore flag after processing */
	if (globalconf.mouse_under.ignore_next_enter_leave) {
		globalconf.mouse_under.ignore_next_enter_leave = false;
	}

	/* If there's no client surface under the cursor, set the cursor image.
	 * Check if pointer is over a drawin with a custom cursor first. */
	if (!surface && !seat->drag) {
		drawin_t *hover_drawin = NULL;
		xytonode(cursor->x, cursor->y, NULL, NULL, NULL, &hover_drawin, NULL, NULL, NULL);
		if (hover_drawin && hover_drawin->cursor)
			wlr_cursor_set_xcursor(cursor, cursor_mgr, hover_drawin->cursor);
		else
			wlr_cursor_set_xcursor(cursor, cursor_mgr, selected_root_cursor ? selected_root_cursor : "default");
	}

	pointerfocus(c, surface, sx, sy, time);
}

void
pointerfocus(Client *c, struct wlr_surface *surface, double sx, double sy,
		uint32_t time)
{
	struct timespec now;

	/* If surface is NULL but client exists, use client's main surface as fallback.
	 * This happens when cursor is over titlebar/border (compositor-drawn, not a
	 * wlr_surface). Without this fallback, pointer focus would be cleared and the
	 * client wouldn't receive hover/scroll events. */
	if (!surface && c && client_surface(c) && client_surface(c)->mapped) {
		surface = client_surface(c);
		cursor_to_client_coordinates(c, &sx, &sy);
	}
	if (!surface) {
		wlr_seat_pointer_notify_clear_focus(seat);
		return;
	}

	/* Don't give pointer focus to clients when Lua-locked */
	if (some_is_lua_locked()) {
		wlr_seat_pointer_notify_clear_focus(seat);
		return;
	}

	/* Workaround for wlroots pointer enter race condition:
	 * wlr_seat_pointer_enter() caches focused_surface and returns early if
	 * it matches. But if the initial enter was called before the client bound
	 * wl_pointer (pointers list empty), the wl_pointer.enter event was never
	 * sent even though focused_surface was set. Clear the stale state so
	 * wlr_seat_pointer_enter() re-delivers the enter event. */
	if (seat->pointer_state.focused_surface == surface) {
		struct wlr_seat_client *sc = seat->pointer_state.focused_client;
		if (!sc || wl_list_empty(&sc->pointers)) {
			wlr_log(WLR_DEBUG, "[POINTER-REENTER] clearing stale pointer focus on %s "
				"(client had no wl_pointer resources)",
				c ? client_get_appid(c) : "?");
			wlr_seat_pointer_notify_clear_focus(seat);
		}
	}

	if (!time) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		time = now.tv_sec * 1000 + now.tv_nsec / 1000000;
	}

	/* Deliver pointer enter + motion to the surface.
	 * wlr_seat_pointer_enter is a no-op if surface is already focused AND
	 * the client has pointer resources (normal case). */
	wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
	wlr_seat_pointer_notify_motion(seat, time, sx, sy);
}

int
keybinding(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym)
{
	client_t *focused;
	struct wlr_surface *surface;

	/*
	 * Here we handle compositor keybindings. This is when the compositor is
	 * processing keys, rather than passing them on to the client for its own
	 * processing.
	 *
	 * AwesomeWM pattern: check client-specific keybindings first (they receive
	 * the client as argument), then check global keybindings.
	 */

	/* Get the client that has keyboard focus from the Wayland seat.
	 * This matches AwesomeWM's pattern of using the X11 event window
	 * (event.c:781: client_getbywin(ev->event)) rather than internal
	 * focus state. We don't modify globalconf.focus.client here to
	 * avoid emitting focus signals during keybinding dispatch. */
	surface = seat->keyboard_state.focused_surface;
	focused = surface ? some_client_from_surface(surface) : NULL;

	/* Check client-specific Lua key objects first (AwesomeWM pattern)
	 * Client keybindings pass the client as argument to the "press" signal */
	if (focused && luaA_client_key_check_and_emit(focused, CLEANMASK(mods), keycode, sym, base_sym))
		return 1;

	/* Check global Lua key objects (AwesomeWM pattern) */
	if (luaA_key_check_and_emit(CLEANMASK(mods), keycode, sym, base_sym))
		return 1;

	/* Hardcoded VT switching (compositor-level, non-configurable)
	 * These are standard Linux keybindings that must work even if Lua crashes.
	 * VT switching allows recovering from compositor hangs/crashes via Ctrl-Alt-F2.
	 */
	if (CLEANMASK(mods) == (WLR_MODIFIER_CTRL|WLR_MODIFIER_ALT)) {
		/* Ctrl-Alt-Backspace: Terminate compositor
		 * Block during lock to prevent bypassing lockscreen */
		if (sym == XKB_KEY_Terminate_Server) {
			if (session_is_locked())
				return 1;
			wl_display_terminate(dpy);
			return 1;
		}
		/* Ctrl-Alt-F1..F12: Switch to VT 1-12
		 * Block during lock to prevent bypassing lockscreen */
		if (sym >= XKB_KEY_XF86Switch_VT_1 && sym <= XKB_KEY_XF86Switch_VT_12) {
			if (session_is_locked())
				return 1;
			unsigned int vt = sym - XKB_KEY_XF86Switch_VT_1 + 1;
			wlr_session_change_vt(session, vt);
			return 1;
		}
	}

	return 0;
}

void
keypress(struct wl_listener *listener, void *data)
{
#ifdef SOMEWM_BENCH
	bench_input_event_record();
#endif
	int i;
	uint32_t keycode;
	const xkb_keysym_t *syms;
	int nsyms;
	int handled = 0;
	uint32_t mods;
	xkb_keysym_t base_sym;
	/* This event is raised when a key is pressed or released. */
	KeyboardGroup *group = wl_container_of(listener, group, key);
	struct wlr_keyboard_key_event *event = data;

	/* Translate libinput keycode -> xkbcommon */
	keycode = event->keycode + 8;
	/* Get a list of keysyms based on the keymap for this keyboard */
	nsyms = xkb_state_key_get_syms(
			group->wlr_group->keyboard.xkb_state, keycode, &syms);

	mods = wlr_keyboard_get_modifiers(&group->wlr_group->keyboard);

	/* Get the base keysym (level 0, ignoring Shift/Lock modifiers).
	 * This is what the key produces without any modifiers applied.
	 * We use this for keybinding matching so that users can bind to
	 * "2" instead of "at" when using Shift+2. */
	base_sym = xkb_state_key_get_one_sym(
			group->wlr_group->keyboard.xkb_state, keycode);
	/* If Shift or Lock is active, get the unmodified keysym */
	if (mods & (WLR_MODIFIER_SHIFT | WLR_MODIFIER_CAPS)) {
		/* Get layout index (usually 0 for QWERTY) */
		xkb_layout_index_t layout = xkb_state_key_get_layout(
				group->wlr_group->keyboard.xkb_state, keycode);
		/* Get level 0 (base) keysym for this layout */
		const xkb_keysym_t *base_syms;
		int n = xkb_keymap_key_get_syms_by_level(
				group->wlr_group->keyboard.keymap, keycode, layout, 0, &base_syms);
		if (n > 0)
			base_sym = base_syms[0];
	}

	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	some_notify_activity();

	/* Check if keygrabber is active - if so, route event to Lua callback.
	 * Note: Keygrabber is allowed when Lua-locked (for lock screen password input)
	 * but NOT when externally locked (session-lock-v1 protocol handles that). */
	if (!locked && some_keygrabber_is_running()) {
		bool is_press = event->state == WL_KEYBOARD_KEY_STATE_PRESSED;
		/* Route to keygrabber callback */
		if (some_keygrabber_handle_key(keycode, group->wlr_group->keyboard.xkb_state, is_press)) {
			/* Only disable key repeat for press events */
			if (is_press) {
				group->nsyms = 0;
				wl_event_source_timer_update(group->key_repeat_source, 0);
			}
			return;
		}
	}

	/* On _press_ if there is no active screen locker,
	 * attempt to process a compositor keybinding.
	 * Block for both ext-session-lock-v1 (locked) and Lua lock (some_is_lua_locked). */
	if (!session_is_locked() && event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		for (i = 0; i < nsyms; i++)
			handled = keybinding(mods, keycode, syms[i], base_sym) || handled;
	}

	if (handled && group->wlr_group->keyboard.repeat_info.delay > 0) {
		group->mods = mods;
		group->keycode = keycode;
		group->keysyms = syms;
		group->nsyms = nsyms;
		group->base_sym = base_sym;
		wl_event_source_timer_update(group->key_repeat_source,
				group->wlr_group->keyboard.repeat_info.delay);
	} else {
		group->nsyms = 0;
		wl_event_source_timer_update(group->key_repeat_source, 0);
	}

	if (handled)
		return;

	/* Don't pass keys to clients when Lua-locked (focus is cleared anyway,
	 * but this is a safety check) */
	if (some_is_lua_locked())
		return;

	wlr_seat_set_keyboard(seat, &group->wlr_group->keyboard);
	/* Pass unhandled keycodes along to the client. */
	wlr_seat_keyboard_notify_key(seat, event->time_msec,
			event->keycode, event->state);
}

void
keypressmod(struct wl_listener *listener, void *data)
{
	/* This event is raised when a modifier key, such as shift or alt, is
	 * pressed. We simply communicate this to the client. */
	KeyboardGroup *group = wl_container_of(listener, group, modifiers);
	xkb_layout_index_t current_group;

	wlr_seat_set_keyboard(seat, &group->wlr_group->keyboard);
	/* Send modifiers to the client. */
	wlr_seat_keyboard_notify_modifiers(seat,
			&group->wlr_group->keyboard.modifiers);

	/* Check for layout group change (e.g., from Alt+Shift toggle) */
	current_group = xkb_state_serialize_layout(
		group->wlr_group->keyboard.xkb_state,
		XKB_STATE_LAYOUT_EFFECTIVE);

	if (current_group != globalconf.xkb.last_group) {
		globalconf.xkb.last_group = current_group;
		xkb_schedule_group_changed();
	}
}

int
keyrepeat(void *data)
{
	KeyboardGroup *group = data;
	int i;
	if (!group->nsyms || group->wlr_group->keyboard.repeat_info.rate <= 0)
		return 0;

	/* Block key repeat during lock to prevent compositor keybindings
	 * from firing behind the lockscreen */
	if (session_is_locked()) {
		group->nsyms = 0;
		return 0;
	}

	wl_event_source_timer_update(group->key_repeat_source,
			1000 / group->wlr_group->keyboard.repeat_info.rate);

	for (i = 0; i < group->nsyms; i++)
		keybinding(group->mods, group->keycode, group->keysyms[i], group->base_sym);

	return 0;
}

void
createpointerconstraint(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_constraint_v1 *constraint = data;
	PointerConstraint *pointer_constraint = ecalloc(1, sizeof(*pointer_constraint));
	pointer_constraint->constraint = constraint;
	LISTEN(&pointer_constraint->constraint->events.destroy,
			&pointer_constraint->destroy, destroypointerconstraint);

	/* If this constraint's surface already has keyboard focus, activate it */
	if (constraint->surface == seat->keyboard_state.focused_surface)
		cursorconstrain(constraint);
}

void
destroypointerconstraint(struct wl_listener *listener, void *data)
{
	PointerConstraint *pointer_constraint = wl_container_of(listener, pointer_constraint, destroy);

	if (active_constraint == pointer_constraint->constraint) {
		cursorwarptohint();
		active_constraint = NULL;
	}

	wl_list_remove(&pointer_constraint->destroy.link);
	free(pointer_constraint);
}

void
cursorconstrain(struct wlr_pointer_constraint_v1 *constraint)
{
	if (active_constraint == constraint)
		return;

	if (active_constraint)
		wlr_pointer_constraint_v1_send_deactivated(active_constraint);

	active_constraint = constraint;

	if (active_constraint)
		wlr_pointer_constraint_v1_send_activated(active_constraint);
}

void
cursorwarptohint(void)
{
	Client *c = NULL;
	double sx = active_constraint->current.cursor_hint.x;
	double sy = active_constraint->current.cursor_hint.y;

	toplevel_from_wlr_surface(active_constraint->surface, &c, NULL);
	if (c && active_constraint->current.cursor_hint.enabled) {
		wlr_cursor_warp(cursor, NULL, sx + c->geometry.x + c->bw, sy + c->geometry.y + c->bw);
		wlr_seat_pointer_warp(active_constraint->seat, sx, sy);
	}
}

void
inputdevice(struct wl_listener *listener, void *data)
{
	/* This event is raised by the backend when a new input device becomes
	 * available. */
	struct wlr_input_device *device = data;
	uint32_t caps;

	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		createkeyboard(wlr_keyboard_from_input_device(device));
		break;
	case WLR_INPUT_DEVICE_POINTER:
		createpointer(wlr_pointer_from_input_device(device));
		break;
	default:
		/* TODO handle other input device types */
		break;
	}

	/* We need to let the wlr_seat know what our capabilities are, which is
	 * communiciated to the client. In somewm we always have a cursor, even if
	 * there are no pointer devices, so we always include that capability. */
	/* TODO do we actually require a cursor? */
	caps = WL_SEAT_CAPABILITY_POINTER;
	if (!wl_list_empty(&kb_group->wlr_group->devices))
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	wlr_seat_set_capabilities(seat, caps);
}

void
createkeyboard(struct wlr_keyboard *keyboard)
{
	/* Set the keymap to match the group keymap */
	wlr_keyboard_set_keymap(keyboard, kb_group->wlr_group->keyboard.keymap);

	/* Add the new keyboard to the group */
	wlr_keyboard_group_add_keyboard(kb_group->wlr_group, keyboard);
}

KeyboardGroup *
createkeyboardgroup(void)
{
	KeyboardGroup *group = ecalloc(1, sizeof(*group));
	struct xkb_context *context;
	struct xkb_keymap *keymap;
	struct xkb_rule_names rules;

	group->wlr_group = wlr_keyboard_group_create();
	group->wlr_group->data = group;

	/* Prepare an XKB keymap and assign it to the keyboard group. */
	context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);

	/* Build XKB rules from globalconf (set via Lua or defaults) */
	rules.layout = globalconf.keyboard.xkb_layout;
	rules.variant = globalconf.keyboard.xkb_variant;
	rules.options = globalconf.keyboard.xkb_options;
	rules.rules = NULL;
	rules.model = NULL;

	if (!(keymap = xkb_keymap_new_from_names(context, &rules,
				XKB_KEYMAP_COMPILE_NO_FLAGS)))
		die("failed to compile keymap");

	wlr_keyboard_set_keymap(&group->wlr_group->keyboard, keymap);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);

	wlr_keyboard_set_repeat_info(&group->wlr_group->keyboard,
		globalconf.keyboard.repeat_rate, globalconf.keyboard.repeat_delay);

	/* Set up listeners for keyboard events */
	LISTEN(&group->wlr_group->keyboard.events.key, &group->key, keypress);
	LISTEN(&group->wlr_group->keyboard.events.modifiers, &group->modifiers, keypressmod);

	group->key_repeat_source = wl_event_loop_add_timer(event_loop, keyrepeat, group);

	/* A seat can only have one keyboard, but this is a limitation of the
	 * Wayland protocol - not wlroots. We assign all connected keyboards to the
	 * same wlr_keyboard_group, which provides a single wlr_keyboard interface for
	 * all of them. Set this combined wlr_keyboard as the seat keyboard.
	 */
	wlr_seat_set_keyboard(seat, &group->wlr_group->keyboard);
	return group;
}

void
destroykeyboardgroup(struct wl_listener *listener, void *data)
{
	KeyboardGroup *group = wl_container_of(listener, group, destroy);
	wl_event_source_remove(group->key_repeat_source);
	wl_list_remove(&group->key.link);
	wl_list_remove(&group->modifiers.link);
	wl_list_remove(&group->destroy.link);
	wlr_keyboard_group_destroy(group->wlr_group);
	free(group);
}

/* Determine device type string for input rule matching */
static const char *
get_input_device_type(struct libinput_device *device)
{
	return libinput_device_config_tap_get_finger_count(device) > 0
		? "touchpad" : "pointer";
}

/* Resolve effective input settings for a device by overlaying matching rules
 * on top of the global defaults. String fields in the result are borrowed
 * pointers (not owned), so the caller must not free them. */
static void
resolve_input_settings(struct libinput_device *device, struct InputSettings *out)
{
	/* Start with global defaults */
	*out = globalconf.input;
	/* String fields are borrowed from globalconf, not duplicated */

	const char *dev_type = get_input_device_type(device);
	const char *dev_name = libinput_device_get_name(device);

	for (int i = 0; i < globalconf.input_rules_count; i++) {
		struct InputRule *rule = &globalconf.input_rules[i];

		/* Check type match */
		if (rule->type && strcmp(rule->type, dev_type) != 0)
			continue;
		/* Check name match (substring) */
		if (rule->name && (!dev_name || !strstr(dev_name, rule->name)))
			continue;

		/* Overlay properties from this rule (-2 = not set, skip) */
		struct InputSettings *p = &rule->properties;
		if (p->tap_to_click != -2) out->tap_to_click = p->tap_to_click;
		if (p->tap_and_drag != -2) out->tap_and_drag = p->tap_and_drag;
		if (p->drag_lock != -2) out->drag_lock = p->drag_lock;
		if (p->tap_3fg_drag != -2) out->tap_3fg_drag = p->tap_3fg_drag;
		if (p->natural_scrolling != -2) out->natural_scrolling = p->natural_scrolling;
		if (p->disable_while_typing != -2) out->disable_while_typing = p->disable_while_typing;
		if (p->dwtp != -2) out->dwtp = p->dwtp;
		if (p->left_handed != -2) out->left_handed = p->left_handed;
		if (p->middle_button_emulation != -2) out->middle_button_emulation = p->middle_button_emulation;
		if (p->scroll_button != -2) out->scroll_button = p->scroll_button;
		if (p->scroll_button_lock != -2) out->scroll_button_lock = p->scroll_button_lock;
		if (p->scroll_method) out->scroll_method = p->scroll_method;
		if (p->click_method) out->click_method = p->click_method;
		if (p->clickfinger_button_map) out->clickfinger_button_map = p->clickfinger_button_map;
		if (p->send_events_mode) out->send_events_mode = p->send_events_mode;
		if (p->accel_profile) out->accel_profile = p->accel_profile;
		if (p->tap_button_map) out->tap_button_map = p->tap_button_map;
		if (p->accel_speed_set) {
			out->accel_speed = p->accel_speed;
			out->accel_speed_set = true;
		}
	}
}

/* Apply resolved input settings to a single libinput device */
void
apply_input_settings_to_device(struct libinput_device *device)
{
	struct InputSettings s;
	resolve_input_settings(device, &s);

	if (libinput_device_config_tap_get_finger_count(device)) {
		if (s.tap_to_click >= 0)
			libinput_device_config_tap_set_enabled(device, s.tap_to_click);
		if (s.tap_and_drag >= 0)
			libinput_device_config_tap_set_drag_enabled(device, s.tap_and_drag);
		if (s.drag_lock >= 0)
			libinput_device_config_tap_set_drag_lock_enabled(device, s.drag_lock);

		if (s.tap_button_map) {
			enum libinput_config_tap_button_map map = LIBINPUT_CONFIG_TAP_MAP_LRM;
			if (strcmp(s.tap_button_map, "lmr") == 0)
				map = LIBINPUT_CONFIG_TAP_MAP_LMR;
			libinput_device_config_tap_set_button_map(device, map);
		}
	}

	/* Three-finger drag (libinput 1.27+) */
#ifdef HAVE_LIBINPUT_3FG_DRAG
	if (libinput_device_config_3fg_drag_get_finger_count(device)) {
		if (s.tap_3fg_drag >= 0)
			libinput_device_config_3fg_drag_set_enabled(device,
				s.tap_3fg_drag ? LIBINPUT_CONFIG_3FG_DRAG_ENABLED_3FG
				               : LIBINPUT_CONFIG_3FG_DRAG_DISABLED);
	} else if (s.tap_3fg_drag > 0) {
		wlr_log(WLR_INFO, "Device '%s' does not support three-finger drag",
			libinput_device_get_name(device));
	}
#endif

	if (libinput_device_config_scroll_has_natural_scroll(device)
			&& s.natural_scrolling >= 0)
		libinput_device_config_scroll_set_natural_scroll_enabled(device,
			s.natural_scrolling);

	if (libinput_device_config_dwt_is_available(device)
			&& s.disable_while_typing >= 0)
		libinput_device_config_dwt_set_enabled(device,
			s.disable_while_typing);

	if (libinput_device_config_dwtp_is_available(device)
			&& s.dwtp >= 0)
		libinput_device_config_dwtp_set_enabled(device, s.dwtp);

	if (libinput_device_config_left_handed_is_available(device)
			&& s.left_handed >= 0)
		libinput_device_config_left_handed_set(device, s.left_handed);

	if (libinput_device_config_middle_emulation_is_available(device)
			&& s.middle_button_emulation >= 0)
		libinput_device_config_middle_emulation_set_enabled(device,
			s.middle_button_emulation);

	if (libinput_device_config_scroll_get_methods(device) != LIBINPUT_CONFIG_SCROLL_NO_SCROLL
			&& s.scroll_method) {
		enum libinput_config_scroll_method method = LIBINPUT_CONFIG_SCROLL_2FG;
		if (strcmp(s.scroll_method, "no_scroll") == 0)
			method = LIBINPUT_CONFIG_SCROLL_NO_SCROLL;
		else if (strcmp(s.scroll_method, "two_finger") == 0)
			method = LIBINPUT_CONFIG_SCROLL_2FG;
		else if (strcmp(s.scroll_method, "edge") == 0)
			method = LIBINPUT_CONFIG_SCROLL_EDGE;
		else if (strcmp(s.scroll_method, "button") == 0)
			method = LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN;
		libinput_device_config_scroll_set_method(device, method);
	}

	if (s.scroll_button > 0)
		libinput_device_config_scroll_set_button(device, s.scroll_button);

	if (s.scroll_button_lock >= 0)
		libinput_device_config_scroll_set_button_lock(device,
			s.scroll_button_lock ? LIBINPUT_CONFIG_SCROLL_BUTTON_LOCK_ENABLED
			                     : LIBINPUT_CONFIG_SCROLL_BUTTON_LOCK_DISABLED);

	if (libinput_device_config_click_get_methods(device) != LIBINPUT_CONFIG_CLICK_METHOD_NONE
			&& s.click_method) {
		enum libinput_config_click_method method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
		if (strcmp(s.click_method, "none") == 0)
			method = LIBINPUT_CONFIG_CLICK_METHOD_NONE;
		else if (strcmp(s.click_method, "button_areas") == 0)
			method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
		else if (strcmp(s.click_method, "clickfinger") == 0)
			method = LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER;
		libinput_device_config_click_set_method(device, method);
	}

#ifdef LIBINPUT_CONFIG_CLICKFINGER_MAP_LRM
	if (s.clickfinger_button_map) {
		enum libinput_config_clickfinger_button_map map = LIBINPUT_CONFIG_CLICKFINGER_MAP_LRM;
		if (strcmp(s.clickfinger_button_map, "lmr") == 0)
			map = LIBINPUT_CONFIG_CLICKFINGER_MAP_LMR;
		libinput_device_config_click_set_clickfinger_button_map(device, map);
	}
#endif

	if (libinput_device_config_send_events_get_modes(device)
			&& s.send_events_mode) {
		uint32_t mode = LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;
		if (strcmp(s.send_events_mode, "disabled") == 0)
			mode = LIBINPUT_CONFIG_SEND_EVENTS_DISABLED;
		else if (strcmp(s.send_events_mode, "disabled_on_external_mouse") == 0)
			mode = LIBINPUT_CONFIG_SEND_EVENTS_DISABLED_ON_EXTERNAL_MOUSE;
		libinput_device_config_send_events_set_mode(device, mode);
	}

	if (libinput_device_config_accel_is_available(device)) {
		if (s.accel_profile) {
			enum libinput_config_accel_profile profile = LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
			if (strcmp(s.accel_profile, "flat") == 0)
				profile = LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT;
			libinput_device_config_accel_set_profile(device, profile);
		}
		if (s.accel_speed_set)
			libinput_device_config_accel_set_speed(device, s.accel_speed);
	}
}

/* Apply input settings to all tracked pointer devices */
void
apply_input_settings_to_all_devices(void)
{
	TrackedPointer *tp;
	wl_list_for_each(tp, &tracked_pointers, link) {
		apply_input_settings_to_device(tp->libinput_dev);
	}
}

void
createpointer(struct wlr_pointer *pointer)
{
	struct libinput_device *device;
	TrackedPointer *tp;

	if (wlr_input_device_is_libinput(&pointer->base)
			&& (device = wlr_libinput_get_device_handle(&pointer->base))) {

		/* Apply settings from globalconf */
		apply_input_settings_to_device(device);

		/* Track this device for runtime reconfiguration */
		tp = ecalloc(1, sizeof(*tp));
		tp->libinput_dev = device;
		wl_list_insert(&tracked_pointers, &tp->link);
		LISTEN(&pointer->base.events.destroy, &tp->destroy, destroytrackedpointer);
	}

	wlr_cursor_attach_input_device(cursor, &pointer->base);
}

static void
destroytrackedpointer(struct wl_listener *listener, void *data)
{
	TrackedPointer *tp = wl_container_of(listener, tp, destroy);
	wl_list_remove(&tp->destroy.link);
	wl_list_remove(&tp->link);
	free(tp);
}

void
virtualkeyboard(struct wl_listener *listener, void *data)
{
	struct wlr_virtual_keyboard_v1 *kb = data;
	/* virtual keyboards shouldn't share keyboard group */
	KeyboardGroup *group = createkeyboardgroup();
	/* Set the keymap to match the group keymap */
	wlr_keyboard_set_keymap(&kb->keyboard, group->wlr_group->keyboard.keymap);
	LISTEN(&kb->keyboard.base.events.destroy, &group->destroy, destroykeyboardgroup);

	/* Add the new keyboard to the group */
	wlr_keyboard_group_add_keyboard(group->wlr_group, &kb->keyboard);
}

void
virtualpointer(struct wl_listener *listener, void *data)
{
	struct wlr_virtual_pointer_v1_new_pointer_event *event = data;
	struct wlr_input_device *device = &event->new_pointer->pointer.base;

	wlr_cursor_attach_input_device(cursor, device);
	if (event->suggested_output)
		wlr_cursor_map_input_to_output(cursor, device, event->suggested_output);
}

/** Check if a drawin accepts input at a given point (relative to drawin).
 * Returns true if input should be accepted, false if it should pass through.
 * Used for implementing click-through regions via shape_input and shape_bounding.
 *
 * In X11/AwesomeWM, shape_bounding affects both visual AND input regions.
 * shape_input takes precedence if set; otherwise shape_bounding is used.
 */
bool
drawin_accepts_input_at(drawin_t *d, double local_x, double local_y)
{
	cairo_surface_t *shape;
	int width, height;
	unsigned char *data;
	int stride;
	int px, py;
	int byte_offset, bit_offset;

	if (!d)
		return true;

	/* shape_input takes precedence over shape_bounding */
	shape = d->shape_input;

	/* If no shape_input, fall back to shape_bounding (X11 compatibility) */
	if (!shape)
		shape = d->shape_bounding;

	/* No shape = accept all input */
	if (!shape)
		return true;

	/* Verify surface is valid before accessing (fixes issue #197) */
	if (cairo_surface_status(shape) != CAIRO_STATUS_SUCCESS)
		return true;

	/* Get shape dimensions */
	width = cairo_image_surface_get_width(shape);
	height = cairo_image_surface_get_height(shape);

	/* 0x0 surface means pass through ALL input (AwesomeWM convention) */
	if (width == 0 || height == 0)
		return false;

	/* Convert coordinates to integers */
	px = (int)local_x;
	py = (int)local_y;

	/* Bounds check - outside shape = don't accept */
	if (px < 0 || py < 0 || px >= width || py >= height)
		return false;

	/* Get pixel data (A1 format: 1 bit per pixel, packed) */
	cairo_surface_flush(shape);
	data = cairo_image_surface_get_data(shape);
	stride = cairo_image_surface_get_stride(shape);

	/* A1 format: pixels packed 8 per byte, LSB first */
	byte_offset = (py * stride) + (px / 8);
	bit_offset = px % 8;

	return (data[byte_offset] >> bit_offset) & 1;
}

/* WAYLAND-DEVIATION: pdrawable parameter for titlebar hit-testing
 * AwesomeWM: Uses client_get_drawable_offset() to iterate titlebar geometries
 * after receiving a frame_window event (objects/client.c:3501).
 * somewm: The wlroots scene graph already knows which node is at (x,y), so we
 * extract the drawable directly from node->data during the scene walk. This
 * achieves the same result (titlebar clicks emit signals on the drawable) but
 * uses scene graph spatial queries instead of post-hoc geometry iteration.
 */
void
xytonode(double x, double y, struct wlr_surface **psurface,
		Client **pc, LayerSurface **pl, drawin_t **pd, drawable_t **pdrawable, double *nx, double *ny)
{
	struct wlr_scene_node *node, *pnode;
	struct wlr_surface *surface = NULL;
	Client *c = NULL;
	LayerSurface *l = NULL;
	drawin_t *d = NULL;
	drawable_t *titlebar_drawable = NULL;
	int layer;

	/* Safety check: scene must be initialized */
	if (!scene) {
		if (psurface) *psurface = NULL;
		if (pc) *pc = NULL;
		if (pl) *pl = NULL;
		if (pd) *pd = NULL;
		if (pdrawable) *pdrawable = NULL;
		return;
	}

	for (layer = NUM_LAYERS - 1; !surface && layer >= 0; layer--) {
		/* Safety check: layer tree must exist */
		if (!layers[layer])
			continue;
		if (!(node = wlr_scene_node_at(&layers[layer]->node, x, y, nx, ny)))
			continue;


		if (node->type == WLR_SCENE_NODE_BUFFER) {
			struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(node);
			struct wlr_scene_surface *scene_surface = wlr_scene_surface_try_from_buffer(buffer);


			if (scene_surface) {
				surface = scene_surface->surface;
			} else {
				/* Check if this buffer belongs to a drawin or titlebar */

				/* node->data now stores drawable pointer (AwesomeWM pattern) */
				if (node->data) {
					drawable_t *drawable = (drawable_t *)node->data;

					if (drawable->owner_type == DRAWABLE_OWNER_DRAWIN) {
						/* This is a drawin's drawable */
						drawin_t *candidate = drawable->owner.drawin;
						/* Check shape_input to see if input passes through */
						if (drawin_accepts_input_at(candidate, x - candidate->x, y - candidate->y)) {
							d = candidate;
							/* For drawins, we found what we need - skip client check */
							goto found;
						}
						/* Input passes through this drawin, continue searching */
					} else if (drawable->owner_type == DRAWABLE_OWNER_CLIENT) {
						/* This is a titlebar drawable - store it and set client
						 * Matches AwesomeWM event.c:76-77 client_get_drawable_offset() */
						c = drawable->owner.client;
						titlebar_drawable = drawable;
						/* Continue to found label with client and titlebar_drawable set */
					}
				}
			}
		} else {
			/* Skip parent walk for non-buffer nodes (e.g., scene rects) -
			 * these are background elements that shouldn't intercept input */
			continue;
		}
		/* Walk the tree to find a node that knows the client */
		for (pnode = node; pnode && !c && !d; ) {
			/* Check if this node has a drawin */
			if (pnode->data && layer == LyrWibox) {
				drawin_t *candidate = (drawin_t *)pnode->data;
				/* Check shape_input to see if input passes through */
				if (drawin_accepts_input_at(candidate, x - candidate->x, y - candidate->y)) {
					d = candidate;
					break;
				}
				/* Input passes through, continue searching to parent (don't set c) */
			} else {
				/* Not a drawin - could be a client */
				c = pnode->data;
			}
			/* Safely traverse to parent - stop if we reach root */
			if (!pnode->parent)
				break;
			pnode = &pnode->parent->node;
		}
		/* Check type at offset 0 - LayerSurface has 'type' as first field,
		 * but Client has WINDOW_OBJECT_HEADER before client_type.
		 * LayerSurface.type is at offset 0 and set to LayerShell. */
		if (c && *((unsigned int *)c) == LayerShell) {
			l = (LayerSurface *)c;
			c = NULL;
		}
	}

found:
	/* Validate client pointer - ensure it's still in globalconf.clients
	 * to avoid returning stale pointers from scene graph data fields */
	if (c && pc) {
		bool valid = false;
		foreach(elem, globalconf.clients) {
			if (*elem == c) {
				valid = true;
				break;
			}
		}
		if (!valid) {
			c = NULL;  /* Stale pointer - don't return it */
		}
	}

	if (psurface) *psurface = surface;
	if (pc) *pc = c;
	if (pl) *pl = l;
	if (pd) *pd = d;
	if (pdrawable) *pdrawable = titlebar_drawable;
}

void
setcursor(struct wl_listener *listener, void *data)
{
	/* This event is raised by the seat when a client provides a cursor image */
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	/* If we're "grabbing" the cursor, don't use the client's image, we will
	 * restore it after "grabbing" sending a leave event, followed by a enter
	 * event, which will result in the client requesting set the cursor surface */
	if (cursor_mode != CurNormal && cursor_mode != CurPressed)
		return;
	/* This can be sent by any client, so we check to make sure this one
	 * actually has pointer focus first. If so, we can tell the cursor to
	 * use the provided surface as the cursor image. It will set the
	 * hardware cursor on the output that it's currently on and continue to
	 * do so as the cursor moves between outputs. */
	if (event->seat_client == seat->pointer_state.focused_client)
		wlr_cursor_set_surface(cursor, event->surface,
				event->hotspot_x, event->hotspot_y);
}

void
setcursorshape(struct wl_listener *listener, void *data)
{
	struct wlr_cursor_shape_manager_v1_request_set_shape_event *event = data;
	if (cursor_mode != CurNormal && cursor_mode != CurPressed)
		return;
	/* This can be sent by any client, so we check to make sure this one
	 * actually has pointer focus first. If so, we can tell the cursor to
	 * use the provided cursor shape. */
	if (event->seat_client == seat->pointer_state.focused_client)
		wlr_cursor_set_xcursor(cursor, cursor_mgr,
				wlr_cursor_shape_v1_name(event->shape));
}

void
setpsel(struct wl_listener *listener, void *data)
{
	/* This event is raised by the seat when a client wants to set the selection,
	 * usually when the user copies something. wlroots allows compositors to
	 * ignore such requests if they so choose, but in somewm we always honor them
	 */
	struct wlr_seat_request_set_primary_selection_event *event = data;
	wlr_seat_set_primary_selection(seat, event->source, event->serial);
}

void
setsel(struct wl_listener *listener, void *data)
{
	/* This event is raised by the seat when a client wants to set the selection,
	 * usually when the user copies something. wlroots allows compositors to
	 * ignore such requests if they so choose, but in somewm we always honor them
	 */
	struct wlr_seat_request_set_selection_event *event = data;
	wlr_seat_set_selection(seat, event->source, event->serial);
}

void
requeststartdrag(struct wl_listener *listener, void *data)
{
	struct wlr_seat_request_start_drag_event *event = data;

	if (wlr_seat_validate_pointer_grab_serial(seat, event->origin,
			event->serial)) {
		wlr_seat_start_pointer_drag(seat, event->drag, event->serial);

		/* Remember source client where drag started.  */
		Client *c = NULL;
		LayerSurface *l = NULL;
		toplevel_from_wlr_surface(event->origin, &c, &l);

		drag_source_client = c;
	}
	else {
		drag_source_client = NULL;
		wlr_data_source_destroy(event->drag->source);
	}
}

void
destroydrag(struct wl_listener *listener, void *data)
{
	Client *c = focustop(selmon);

	/* seat->drag is already NULL at this point (wlroots clears it before
	 * emitting destroy). Re-focus so border colors are properly updated.
	 *
	 * focusclient() skips border color updates when the same client is
	 * already focused (early return at surface == old check), so explicitly
	 * apply the focus color here for the common case where the focused
	 * client didn't change during the drag. */
	if (c && !client_is_unmanaged(c))
		client_set_border_color(c, get_focuscolor());
	focusclient(c, 0);
	motionnotify(0, NULL, 0, 0, 0, 0);
	wl_list_remove(&listener->link);
	free(listener);

	drag_source_client = NULL;
}

void
destroydragicon(struct wl_listener *listener, void *data)
{
	wl_list_remove(&listener->link);
	free(listener);
}

void
startdrag(struct wl_listener *listener, void *data)
{
	struct wlr_drag *drag = data;

	/* Listen for drag destroy to refocus after drag ends.
	 * wlroots clears seat->drag BEFORE emitting this signal,
	 * so focusclient() will properly update border colors. */
	LISTEN_STATIC(&drag->events.destroy, destroydrag);

	if (!drag->icon)
		return;

	drag->icon->data = &wlr_scene_drag_icon_create(drag_icon, drag->icon)->node;
	LISTEN_STATIC(&drag->icon->events.destroy, destroydragicon);
}
