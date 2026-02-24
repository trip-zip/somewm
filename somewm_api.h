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

/* Get client properties */
const char *some_client_get_title(Client *c);
const char *some_client_get_appid(Client *c);
int some_client_get_floating(Client *c);
int some_client_get_fullscreen(Client *c);
int some_client_get_urgent(Client *c);
Monitor *some_client_get_monitor(Client *c);
void some_client_get_geometry(Client *c, struct wlr_box *geom);

/* Set client properties */
void some_client_set_floating(Client *c, int floating);
void some_client_set_fullscreen(Client *c, int fullscreen);
void some_client_set_urgent(Client *c, int urgent);
void some_client_set_border_width(Client *c, unsigned int bw);
void some_client_set_border_color(Client *c, const float color[4]);
void some_client_set_ontop(Client *c, int ontop);
void some_client_set_above(Client *c, int above);
void some_client_set_below(Client *c, int below);
void some_client_set_window_type(Client *c, window_type_t window_type);
int some_client_get_ontop(Client *c);
int some_client_get_above(Client *c);
int some_client_get_below(Client *c);
window_type_t some_client_get_window_type(Client *c);
Client *some_client_get_transient_for(Client *c);

/* Focus synchronization API - internal use */
void some_set_seat_keyboard_focus(Client *c);
Client *some_client_from_surface(struct wlr_surface *surface);

/* Window state properties */
void some_client_set_sticky(Client *c, int sticky);
void some_client_set_minimized(Client *c, int minimized);
void some_client_set_hidden(Client *c, int hidden);
void some_client_set_modal(Client *c, int modal);
void some_client_set_skip_taskbar(Client *c, int skip_taskbar);
void some_client_set_focusable(Client *c, int focusable);
void some_client_set_maximized(Client *c, int maximized);
void some_client_set_maximized_horizontal(Client *c, int maximized_horizontal);
void some_client_set_maximized_vertical(Client *c, int maximized_vertical);
int some_client_get_sticky(Client *c);
int some_client_get_minimized(Client *c);
int some_client_get_hidden(Client *c);
int some_client_get_modal(Client *c);
int some_client_get_skip_taskbar(Client *c);
int some_client_get_focusable(Client *c);
int some_client_get_maximized(Client *c);
int some_client_get_maximized_horizontal(Client *c);
int some_client_get_maximized_vertical(Client *c);

/* Metadata properties */
const char *some_client_get_name(Client *c);
const char *some_client_get_class(Client *c);
const char *some_client_get_instance(Client *c);
const char *some_client_get_role(Client *c);
const char *some_client_get_machine(Client *c);
const char *some_client_get_startup_id(Client *c);
const char *some_client_get_icon_name(Client *c);
uint32_t some_client_get_pid(Client *c);
void some_client_update_metadata(Client *c);

/* Client actions */
void some_client_focus(Client *c, int lift);
void some_client_close(Client *c);
void some_client_resize(Client *c, struct wlr_box geom, int interact);
void some_client_kill(Client *c);
void some_client_move_to_monitor(Client *c, Monitor *m, uint32_t tags);
void some_client_set_geometry(Client *c, int x, int y, int w, int h);
void some_client_move(Client *c, int x, int y);
void some_client_raise(Client *c);
void some_client_lower(Client *c);
void some_client_zoom(void);
void some_client_swapstack(int direction);

/* Client queries */
Client *some_get_focused_client(void);
Client *some_client_at(double lx, double ly);
Client *some_client_get_parent(Client *c);
int some_client_has_children(Client *c);
int some_client_is_visible(Client *c, Monitor *m);
int some_client_is_focused(Client *c);
int some_client_has_keyboard_focus(Client *c);  /* Check actual wlroots seat keyboard focus */
int some_client_is_stopped(Client *c);
int some_client_is_float_type(Client *c);
int some_client_get_floating(Client *c);
struct wlr_surface *some_client_get_surface(Client *c);

/*
 * Monitor API
 */

/* Get monitor properties */
void some_monitor_get_geometry(Monitor *m, struct wlr_box *geom);
void some_monitor_get_window_area(Monitor *m, struct wlr_box *geom);

/* Monitor actions */
void some_monitor_arrange(Monitor *m);

/* Monitor queries */
Monitor *some_get_focused_monitor(void);
struct wl_list *some_get_monitors(void);
Monitor *some_monitor_at(double lx, double ly);
Monitor *some_monitor_from_direction(Monitor *from, enum wlr_direction dir);
void some_focus_monitor(Monitor *m);
void some_focus_monitor_direction(enum wlr_direction dir);
void some_move_client_to_monitor_direction(enum wlr_direction dir);
void some_focus_client(Client *c, int lift);
Client *some_focus_top_client(Monitor *m);
const char *some_get_monitor_name(Monitor *m);
Monitor *some_monitor_at_cursor(void);
void some_monitor_apply_drawin_struts(Monitor *m, struct wlr_box *area);

/*
 * Tag API
 */
int some_get_tag_count(void);
uint32_t some_get_tag_mask(void);

/*
 * Spawn API
 */
void some_spawn_command(const char *cmd);

/*
 * Settings API
 */
int some_get_new_client_placement(void);
void some_set_new_client_placement(int placement);

/*
 * Layout API
 */

/* Layouts now managed in Lua - no C layout API needed */

/* Arrange functions */
void some_arrange_all(void);

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
struct wlr_cursor *some_get_cursor(void);
struct wl_list *some_get_keyboard_groups(void);

/*
 * Cursor Theme API
 * Runtime cursor theme and size configuration
 */
const char *some_get_cursor_theme(void);
uint32_t some_get_cursor_size(void);
void some_update_cursor_theme(const char *theme_name, uint32_t size);
void some_get_cursor_position(double *x, double *y);
void some_set_cursor_position(double x, double y, int silent);
void some_get_button_states(int states[5]);
Client *some_object_under_cursor(void);
drawin_t *some_drawin_under_cursor(void);
void some_warp_cursor_to_monitor(Monitor *m);
void some_client_start_move(void);
void some_client_start_resize(void);
void some_client_togglefloating(void);

/*
 * Scene & compositor state access
 * Exposes wlroots internals for advanced Lua features
 */
struct wlr_scene *some_get_scene(void);
struct wlr_scene_tree **some_get_layers(void);
struct wlr_output_layout *some_get_output_layout(void);
struct wl_display *some_get_display(void);
struct wl_event_loop *some_get_event_loop(void);
struct wlr_layer_shell_v1 *some_get_layer_shell(void);
struct wlr_renderer *some_get_renderer(void);
struct wlr_allocator *some_get_allocator(void);

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
 * Input Device Configuration API
 * Re-apply libinput settings to all connected pointer devices
 */
void apply_input_settings_to_all_devices(void);

/*
 * Layer Surface Focus API
 * Called from objects/layer_surface.c when Lua sets has_keyboard_focus property
 */
void layer_surface_grant_keyboard(LayerSurface *ls);
void layer_surface_revoke_keyboard(LayerSurface *ls);

/*
 * Test helpers — headless output hotplug simulation
 */
const char *some_test_add_output(unsigned int width, unsigned int height);

#endif /* SOMEWM_API_H */
