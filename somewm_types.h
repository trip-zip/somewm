/*
 * somewm_types.h - Type definitions for somewm compositor
 *
 * This file contains struct definitions and types that were previously
 * embedded in somewm.c. These are now exposed to allow external modules
 * (like Lua bindings) to reference and manipulate somewm data structures.
 */
#ifndef SOMEWM_TYPES_H
#define SOMEWM_TYPES_H

#include <wayland-server-core.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_keyboard_group.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <xkbcommon/xkbcommon.h>

#ifdef XWAYLAND
#include <wlr/xwayland.h>
#endif

/* Enums */
/* NOTE: CurMove and CurResize removed - move/resize now handled by Lua mousegrabber
 * (awful.mouse.client.move/resize) instead of C-level cursor_mode state machine */
enum { CurNormal, CurPressed }; /* cursor */
enum { XDGShell, LayerShell, X11 }; /* client types */
enum { LyrBg, LyrBottom, LyrTile, LyrFloat, LyrWibox, LyrTop, LyrFS, LyrOverlay, LyrBlock, NUM_LAYERS }; /* scene layers */

/* Window types (for stacking and EWMH) - AwesomeWM compatibility */
typedef enum {
	WINDOW_TYPE_NORMAL,
	WINDOW_TYPE_DESKTOP,
	WINDOW_TYPE_DOCK,
	WINDOW_TYPE_TOOLBAR,
	WINDOW_TYPE_MENU,
	WINDOW_TYPE_UTILITY,
	WINDOW_TYPE_SPLASH,
	WINDOW_TYPE_DIALOG,
	WINDOW_TYPE_DROPDOWN_MENU,
	WINDOW_TYPE_POPUP_MENU,
	WINDOW_TYPE_TOOLTIP,
	WINDOW_TYPE_NOTIFICATION,
	WINDOW_TYPE_COMBO,
	WINDOW_TYPE_DND
} window_type_t;

/* Size hint flags (ICCCM compatibility) */
enum {
	SIZE_HINT_P_MIN_SIZE    = (1 << 0),
	SIZE_HINT_P_MAX_SIZE    = (1 << 1),
	SIZE_HINT_P_RESIZE_INC  = (1 << 2),
	SIZE_HINT_P_ASPECT      = (1 << 3),
	SIZE_HINT_BASE_SIZE     = (1 << 4),
	SIZE_HINT_P_WIN_GRAVITY = (1 << 5)
};

/* Forward declarations */
typedef struct Monitor Monitor;
typedef struct client_t client_t;  /* AwesomeWM client struct */
typedef client_t Client;  /* AwesomeWM client_t is now the primary Client type */
typedef struct Tag Tag;

/* Legacy Arg type - used by some Lua API wrapper functions
 * TODO: Remove this once somewm_api.c is refactored to not use Arg-based functions
 */
typedef union {
	int i;
	uint32_t ui;
	float f;
	const void *v;
} Arg;

/* Configuration data structures */
typedef struct {
	const char *id;
	const char *title;
	uint32_t tags;
	int isfloating;
	int monitor;
} Rule;

typedef struct {
	const char *name;
	float mfact;
	int nmaster;
	float scale;
	enum wl_output_transform rr;
	int x, y;
} MonitorRule;

/* Monitor structure */
struct Monitor {
	struct wl_list link;
	struct wlr_output *wlr_output;
	struct wlr_scene_output *scene_output;
	struct wlr_scene_rect *fullscreen_bg; /* See createmon() for info */
	struct wl_listener frame;
	struct wl_listener destroy;
	struct wl_listener request_state;
	struct wl_listener destroy_lock_surface;
	struct wlr_session_lock_surface_v1 *lock_surface;
	struct wlr_box m; /* monitor area, layout-relative */
	struct wlr_box w; /* window area, layout-relative */
	struct wl_list layers[4]; /* LayerSurface.link */
	/* Tags managed by arrays (tag->selected), AwesomeWM-compatible */
	/* mfact/nmaster are per-tag properties, not per-monitor (AwesomeWM-compatible) */
	int gamma_lut_changed;
	int asleep;
};

/* KeyboardGroup structure */
typedef struct {
	struct wlr_keyboard_group *wlr_group;

	int nsyms;
	const xkb_keysym_t *keysyms; /* invalid if nsyms == 0 */
	uint32_t mods; /* invalid if nsyms == 0 */
	uint32_t keycode; /* keycode for repeat, invalid if nsyms == 0 */
	xkb_keysym_t base_sym; /* base (unshifted) keysym, invalid if nsyms == 0 */
	struct wl_event_source *key_repeat_source;

	struct wl_listener modifiers;
	struct wl_listener key;
	struct wl_listener destroy;
} KeyboardGroup;

/* Forward declaration for Lua layer_surface object */
struct layer_surface_t;

/* LayerSurface structure */
typedef struct LayerSurface {
	/* Must keep this field first */
	unsigned int type; /* LayerShell */

	Monitor *mon;
	struct wlr_scene_tree *scene;
	struct wlr_scene_tree *popups;
	struct wlr_scene_layer_surface_v1 *scene_layer;
	struct wl_list link;
	int mapped;
	struct wlr_layer_surface_v1 *layer_surface;

	struct wl_listener destroy;
	struct wl_listener unmap;
	struct wl_listener surface_commit;

	/* Lua object reference (NULL if not managed by Lua) */
	struct layer_surface_t *lua_object;
} LayerSurface;

/* PointerConstraint structure */
typedef struct {
	struct wlr_pointer_constraint_v1 *constraint;
	struct wl_listener destroy;
} PointerConstraint;

/* SessionLock structure */
typedef struct {
	struct wlr_scene_tree *scene;

	struct wlr_session_lock_v1 *lock;
	struct wl_listener new_surface;
	struct wl_listener unlock;
	struct wl_listener destroy;
} SessionLock;

#endif /* SOMEWM_TYPES_H */
