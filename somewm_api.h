/*
 * somewm_api.h - Public API for somewm compositor
 *
 * This file declares the public interface for interacting with the somewm
 * compositor. These functions can be called from external modules such
 * as Lua bindings to control clients, monitors, tags, and layouts.
 *
 * All functions are designed to be safe to call from extension code.
 */
#ifndef SOMEWM_API_H
#define SOMEWM_API_H

#include "somewm_types.h"
#include <wayland-server-core.h>
#include <wlr/util/box.h>
#include <wlr/types/wlr_output.h>
#include <xkbcommon/xkbcommon.h>

/* Forward declarations */
typedef struct drawin_t drawin_t;

/*
 * Client API
 */

int some_client_get_floating(Client *c);

/* Focus synchronization API - internal use */
void some_set_seat_keyboard_focus(Client *c);
Client *some_client_from_surface(struct wlr_surface *surface);

/* Client queries */
Client *some_get_focused_client(void);
Client *some_client_at(double lx, double ly);
int some_client_has_keyboard_focus(Client *c);  /* Check actual wlroots seat keyboard focus */
int some_client_get_floating(Client *c);
struct wlr_surface *some_client_get_surface(Client *c);

/*
 * Monitor API
 */

/* Get monitor properties */
void some_monitor_get_geometry(Monitor *m, struct wlr_box *geom);

/* Monitor actions */
void some_monitor_arrange(Monitor *m);

/* Monitor queries */
Monitor *some_get_focused_monitor(void);
struct wl_list *some_get_monitors(void);
Monitor *some_monitor_at(double lx, double ly);
Monitor *some_monitor_by_name(const char *name);
const char *some_get_monitor_name(Monitor *m);
Monitor *some_monitor_at_cursor(void);

/*
 * Settings API
 */
int some_get_new_client_placement(void);
void some_set_new_client_placement(int placement);

/*
 * Layout API
 */

/* Layouts now managed in Lua - no C layout API needed */

/*
 * Compositor control
 */
void some_compositor_quit(void);

/*
 * Global compositor state access
 * These return pointers to internal state - use carefully
 */
struct wlr_seat *some_get_seat(void);
int some_has_exclusive_focus(void);

/*
 * Cursor Theme API
 * Runtime cursor theme and size configuration
 */
const char *some_get_cursor_theme(void);
uint32_t some_get_cursor_size(void);
void some_update_cursor_theme(const char *theme_name, uint32_t size);
void some_get_cursor_position(double *x, double *y);
void some_set_cursor_position(double x, double y, int silent);
uint16_t some_button_state_mask(void);
Client *some_object_under_cursor(void);
drawin_t *some_drawin_under_cursor(void);
void some_fake_motion(double dx, double dy);

struct wl_display *some_get_display(void);
struct wl_event_loop *some_get_event_loop(void);

/*
 * XKB Keyboard Layout API
 * AwesomeWM-compatible keyboard layout switching and querying
 */
struct xkb_state *some_xkb_get_state(void);
struct xkb_keymap *some_xkb_get_keymap(void);
int some_xkb_set_layout_group(xkb_layout_index_t group);
const char *some_xkb_get_group_names(void);
void some_rebuild_keyboard_keymap(void);
void some_apply_keyboard_repeat_info(void);
void some_set_numlock(int enabled);

/*
 * Layer Surface Focus API
 * Called from objects/layer_surface.c when Lua sets has_keyboard_focus property
 */
void layer_surface_grant_keyboard(LayerSurface *ls);
void layer_surface_revoke_keyboard(LayerSurface *ls);

/*
 * Lock surface lifecycle
 */
void some_notify_drawin_destroyed(drawin_t *w);

/*
 * Lock / Idle / DPMS API
 * Cross-module interface between luaa.c (Lua bindings) and somewm.c (compositor).
 */

/* Lock state - defined in luaa.c, called from somewm.c */
int some_is_lua_locked(void);
drawin_t *some_get_lua_lock_surface(void);
drawin_t **some_get_lua_lock_covers(int *count);
bool some_is_lock_drawin(drawin_t *d);
int some_is_ext_session_locked(void);

/* Lock activation/deactivation - defined in somewm.c, called from luaa.c */
void some_activate_lua_lock(void);
void some_deactivate_lua_lock(void);
void some_deactivate_lua_lock_no_focus(void);
void some_promote_lock_cover(drawin_t *d);
void some_clear_pre_lock_client(client_t *c);

/* Idle/activity - defined in somewm.c */
void some_idle_timers_set_inhibit(bool inhibit);
void some_notify_activity(void);
bool some_is_lua_idle_inhibited(void);

/** Check if the session is locked by any mechanism (ext-session-lock or Lua lock).
 * Use this instead of repeating `locked || some_is_lua_locked()` everywhere. */
static inline bool session_is_locked(void) {
	return some_is_ext_session_locked() || some_is_lua_locked();
}

/*
 * Hot-reload support
 */
void some_refresh(void);
void somewm_pin_lgi_libs(void);

/*
 * Test helpers - headless output hotplug simulation
 */
const char *some_test_add_output(unsigned int width, unsigned int height);

#endif /* SOMEWM_API_H */
