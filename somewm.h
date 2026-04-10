/*
 * somewm.h - Internal shared state for somewm compositor modules
 *
 * This header exposes compositor globals for use by internal C modules
 * (window.c, input.c, output.c, focus.c, protocols.c, xwayland.c).
 *
 * For the public API used by Lua bindings, see somewm_api.h instead.
 */
#ifndef SOMEWM_H
#define SOMEWM_H

#include "somewm_types.h"
#include <stdbool.h>
#include <stdint.h>
#include <wayland-server-core.h>
#include <wlr/util/box.h>

/* Shared utility macros */
#define LENGTH(X)               (sizeof X / sizeof X[0])
#define LISTEN(E, L, H)         wl_signal_add((E), ((L)->notify = (H), (L)))
#define LISTEN_STATIC(E, H)     do { struct wl_listener *_l = ecalloc(1, sizeof(*_l)); \
                                _l->notify = (H); wl_signal_add((E), _l); } while (0)

/* Forward declarations for wlroots types (pointers only, no full headers) */
struct wlr_allocator;
struct wlr_backend;
struct wlr_compositor;
struct wlr_cursor;
struct wlr_cursor_shape_manager_v1;
struct wlr_foreign_toplevel_manager_v1;
struct wlr_idle_inhibit_manager_v1;
struct wlr_idle_notifier_v1;
struct wlr_layer_shell_v1;
struct wlr_output_layout;
struct wlr_output_manager_v1;
struct wlr_output_power_manager_v1;
struct wlr_pointer_constraint_v1;
struct wlr_pointer_constraints_v1;
struct wlr_pointer_gestures_v1;
struct wlr_relative_pointer_manager_v1;
struct wlr_renderer;
struct wlr_scene;
struct wlr_scene_rect;
struct wlr_scene_tree;
struct wlr_seat;
struct wlr_session;
struct wlr_session_lock_manager_v1;
struct wlr_session_lock_v1;
struct wlr_virtual_keyboard_manager_v1;
struct wlr_virtual_pointer_manager_v1;
struct wlr_xcursor_manager;
struct wlr_xdg_activation_v1;
struct wlr_xdg_decoration_manager_v1;
struct wlr_xdg_shell;

#ifdef XWAYLAND
struct wlr_xwayland;
#endif

/* Core compositor state */
extern int running;
extern struct wl_display *dpy;
extern struct wl_event_loop *event_loop;
extern struct wlr_backend *backend;
extern struct wlr_session *session;
extern struct wlr_scene *scene;
extern struct wlr_scene_tree *layers[NUM_LAYERS];
extern struct wlr_renderer *drw;
extern struct wlr_allocator *alloc;
extern struct wlr_compositor *compositor;

/* XDG shell */
extern struct wlr_xdg_shell *xdg_shell;
extern struct wlr_xdg_activation_v1 *activation;
extern struct wlr_xdg_decoration_manager_v1 *xdg_decoration_mgr;

/* Protocol managers */
extern struct wlr_layer_shell_v1 *layer_shell;
extern struct wlr_foreign_toplevel_manager_v1 *foreign_toplevel_mgr;
extern struct wlr_idle_notifier_v1 *idle_notifier;
extern struct wlr_idle_inhibit_manager_v1 *idle_inhibit_mgr;
extern struct wlr_output_manager_v1 *output_mgr;
extern struct wlr_output_power_manager_v1 *power_mgr;
extern struct wlr_virtual_keyboard_manager_v1 *virtual_keyboard_mgr;
extern struct wlr_virtual_pointer_manager_v1 *virtual_pointer_mgr;
extern struct wlr_cursor_shape_manager_v1 *cursor_shape_mgr;

/* Input state */
extern struct wlr_cursor *cursor;
extern struct wlr_xcursor_manager *cursor_mgr;
extern struct wlr_seat *seat;
extern KeyboardGroup *kb_group;
extern void *exclusive_focus;
extern char *selected_root_cursor;

/* Pointer constraints */
extern struct wlr_pointer_constraints_v1 *pointer_constraints;
extern struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
extern struct wlr_pointer_constraint_v1 *active_constraint;

/* Pointer gestures */
extern struct wlr_pointer_gestures_v1 *pointer_gestures;

/* Output/monitor state */
extern struct wlr_output_layout *output_layout;
extern struct wl_list mons;
extern Monitor *selmon;
extern struct wlr_box sgeom;
extern struct wl_list tracked_pointers;

/* Scene elements */
extern struct wlr_scene_tree *drag_icon;
extern struct wlr_scene_rect *root_bg;
extern struct wlr_scene_rect *locked_bg;

/* Session lock state */
extern int locked;
extern struct wlr_session_lock_manager_v1 *session_lock_mgr;
extern struct wlr_session_lock_v1 *cur_lock;

/* Client ID counter */
extern uint32_t next_client_id;

/* Client placement mode: 0 = master, 1 = slave */
extern int new_client_placement;

/* Layer mapping (ZWLR_LAYER_SHELL_* -> Lyr* enum) */
extern const int layermap[];

#ifdef XWAYLAND
extern struct wlr_xwayland *xwayland;
#endif

#endif /* SOMEWM_H */
