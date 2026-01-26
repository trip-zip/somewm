/*
 * globalconf.h - global configuration structure
 *
 * Adapted from AwesomeWM's globalconf.h for somewm (Wayland compositor)
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 */

#ifndef SOMEWM_GLOBALCONF_H
#define SOMEWM_GLOBALCONF_H

#include <lua.h>
#include <stdbool.h>
#include <stdint.h>
#include <xkbcommon/xkbcommon.h>
#include "common/array.h"
#include "common/buffer.h"
#include "x11_compat.h"
#include "shadow.h"
#include <wayland-server-core.h>
#include <cairo.h>

/* Forward declarations */
struct wlr_scene_buffer;
typedef struct client_t client_t;
typedef struct tag_t tag_t;
typedef struct screen_t screen_t;
typedef struct drawin_t drawin_t;
typedef struct drawable_t drawable_t;
typedef struct keyb_t keyb_t;

/** Wallpaper cache entry for instant switching */
typedef struct wallpaper_cache_entry {
    struct wl_list link;
    char *path;                          /* Filepath as cache key */
    struct wlr_scene_buffer *scene_node; /* Hidden when not active */
    cairo_surface_t *surface;            /* For getter compatibility */
} wallpaper_cache_entry_t;

#define WALLPAPER_CACHE_MAX 16

/* Forward declare button types */
typedef struct button_t button_t;

/* Define array types using ARRAY_TYPE macro (AwesomeWM pattern)
 * ARRAY_TYPE creates complete typedef - functions defined in respective headers */
#ifndef BUTTON_ARRAY_T_DEFINED
#define BUTTON_ARRAY_T_DEFINED
ARRAY_TYPE(button_t *, button)
#endif
#ifndef CLIENT_ARRAY_T_DEFINED
#define CLIENT_ARRAY_T_DEFINED
ARRAY_TYPE(client_t *, client)
#endif
#ifndef TAG_ARRAY_T_DEFINED
#define TAG_ARRAY_T_DEFINED
ARRAY_TYPE(tag_t *, tag)
#endif
ARRAY_TYPE(screen_t *, screen)
ARRAY_TYPE(drawin_t *, drawin)

/* Layer surface array for layer shell surfaces */
typedef struct layer_surface_t layer_surface_t;
#ifndef LAYER_SURFACE_ARRAY_T_DEFINED
#define LAYER_SURFACE_ARRAY_T_DEFINED
ARRAY_TYPE(layer_surface_t *, layer_surface)
#endif

/* Key bindings array - replaces x11_compat.h stub */
#ifndef KEY_ARRAY_T_DEFINED
#define KEY_ARRAY_T_DEFINED
ARRAY_TYPE(keyb_t *, key)
#endif

/* Note: button_array_t is defined in objects/button.h */

/* Declare array functions - definitions will be inline in headers */
/* For client and tag, functions are defined in their respective headers */
/* For key, functions are defined in objects/key.h */
/* For screen and drawin, define them here since they're only used in globalconf */
ARRAY_FUNCS(screen_t *, screen, DO_NOTHING)
ARRAY_FUNCS(drawin_t *, drawin, DO_NOTHING)
/* Note: button_array functions are defined in objects/button.c */

/** Main configuration structure
 *
 * This is adapted from AwesomeWM's globalconf structure.
 *
 * Fields are categorized:
 * - CRITICAL: Required for client.c and core functionality
 * - IMPORTANT: Needed for screen/tag management
 * - STUB: X11-specific fields kept as stubs for XWayland compatibility
 */
typedef struct
{
    /* ========== CRITICAL FIELDS ========== */

    /** Lua VM state */
    lua_State *L;

    /** Command line arguments (for restart) */
    int argc;
    char **argv;

    /** All managed clients */
    client_array_t clients;

    /** Client stacking order (bottom to top) */
    client_array_t stack;

    /** Input focus information */
    struct
    {
        /** Currently focused client */
        client_t *client;
        /** Is there a focus change pending? */
        bool need_update;
        /** Window to focus when client doesn't want input (X11/XWayland) */
        xcb_window_t window_no_focus;
    } focus;

    /** Global tag list */
    tag_array_t tags;

    /** Global key bindings (AwesomeWM-compatible) */
    key_array_t keys;

    /** Global button bindings (AwesomeWM-compatible) */
    button_array_t buttons;

    /* ========== IMPORTANT FIELDS ========== */

    /** Logical screens (monitors) */
    screen_array_t screens;

    /** The primary screen */
    screen_t *primary_screen;

    /** Drawable windows (wibox/panels) */
    drawin_array_t drawins;

    /** Layer shell surfaces (panels, launchers, lock screens) */
    layer_surface_array_t layer_surfaces;

    /** Do we need to refresh client visibility? */
    bool need_lazy_banning;

    /* ========== RUNTIME STATE ========== */

    /** Accumulated error messages from rc.lua loading (AwesomeWM-compatible) */
    buffer_t startup_errors;

    /** X11 pattern that caused config fallback (for actionable user feedback) */
    struct {
        char *config_path;    /* Path to the config that was skipped */
        int line_number;      /* Line where pattern was found */
        char *pattern_desc;   /* Human-readable description (e.g., "io.popen with xrandr") */
        char *suggestion;     /* Migration suggestion */
        char *line_content;   /* The actual line of code (truncated) */
    } x11_fallback;

    /** The key grabber function (Lua registry ref) */
    int keygrabber;

    /** The mouse pointer grabber function (Lua registry ref) */
    int mousegrabber;

    /** Mouse state tracking for enter/leave events */
    struct {
        enum { UNDER_NONE, UNDER_CLIENT, UNDER_DRAWIN } type;
        union {
            client_t *client;
            drawin_t *drawin;
        } ptr;
        bool ignore_next_enter_leave;  /* For silent cursor warping */
    } mouse_under;

    /** Button state tracking for mousegrabber
     * Wayland compositors implicitly own all input, so we track button states
     * ourselves rather than relying on wlr_seat (which only tracks when focused).
     * This is the Wayland equivalent of X11's passive button grab state.
     */
    struct {
        bool buttons[5];  /* Button 1-5 pressed states (true = pressed) */
    } button_state;

    /** The exit code that main() will return with */
    int exit_code;

    /** The Global API level */
    int api_level;

    /** Preferred icon size for clients */
    uint32_t preferred_icon_size;

    /* ========== RUNTIME CONFIGURATION ========== */
    /* These replace compile-time config.h settings with runtime Lua configuration.
     * C defaults are set during initialization, then overridden by Lua rc.lua.
     * This achieves 100% AwesomeWM compatibility: no recompilation for config changes. */

    /** Appearance settings (beautiful theme integration) */
    struct {
        unsigned int border_width;    /* Window border thickness in pixels */
        float rootcolor[4];           /* Background color RGBA */
        float bordercolor[4];         /* Unfocused border color RGBA */
        float focuscolor[4];          /* Focused border color RGBA */
        float urgentcolor[4];         /* Urgent border color RGBA */
        float fullscreen_bg[4];       /* Fullscreen background RGBA */
        int bypass_surface_visibility; /* 0=idle inhibitors only when visible, 1=always */
    } appearance;

    /** Shadow settings (compositor-level, replaces picom shadows) */
    shadow_defaults_t shadow;

    /** Keyboard settings (XKB configuration) */
    struct {
        char *xkb_layout;     /* Keyboard layout(s), e.g., "us,ru" */
        char *xkb_variant;    /* Layout variants, e.g., "dvorak," */
        char *xkb_options;    /* XKB options, e.g., "ctrl:nocaps,grp:alt_shift_toggle" */
        int repeat_rate;      /* Key repeat rate (repeats per second) */
        int repeat_delay;     /* Key repeat delay (milliseconds) */
    } keyboard;

    /** XKB state tracking (for deferred signal emission) */
    struct {
        bool update_pending;           /* Deferred signal emission scheduled? */
        bool group_changed;            /* Layout group changed flag */
        bool map_changed;              /* Keymap changed flag */
        xkb_layout_index_t last_group; /* Last known layout group for change detection */
    } xkb;

    /** Input device settings (libinput configuration) */
    struct {
        int tap_to_click;           /* -1=device default, 0=disabled, 1=enabled */
        int tap_and_drag;           /* -1=device default, 0=disabled, 1=enabled */
        int drag_lock;              /* -1=device default, 0=disabled, 1=enabled */
        int tap_3fg_drag;           /* -1=device default, 0=disabled, 1=enabled */
        int natural_scrolling;      /* -1=device default, 0=disabled, 1=enabled */
        int disable_while_typing;   /* -1=device default, 0=disabled, 1=enabled */
        int dwtp;                   /* -1=device default, 0=disabled, 1=enabled (disable while trackpoint) */
        int left_handed;            /* -1=device default, 0=disabled, 1=enabled */
        int middle_button_emulation;/* -1=device default, 0=disabled, 1=enabled */
        char *scroll_method;        /* String: "no_scroll", "two_finger", "edge", "button" */
        int scroll_button;          /* Button for scroll-on-button mode, 0=default */
        int scroll_button_lock;     /* -1=device default, 0=disabled, 1=enabled */
        char *click_method;         /* String: "none", "button_areas", "clickfinger" */
        char *send_events_mode;     /* String: "enabled", "disabled", "disabled_on_external_mouse" */
        char *accel_profile;        /* String: "flat", "adaptive" */
        double accel_speed;         /* -1.0 to 1.0 */
        char *tap_button_map;       /* String: "lrm", "lmr" */
        char *clickfinger_button_map; /* String: "lrm", "lmr" */
    } input;

    /** Logging configuration */
    int log_level;  /* wlroots log level: WLR_SILENT, WLR_ERROR, WLR_INFO, WLR_DEBUG */

    /* ========== WALLPAPER SUPPORT ========== */

    /** Cached wallpaper surface (AwesomeWM compatibility)
     * This is a cairo_surface_t* that stores the current wallpaper pattern.
     * Matches AwesomeWM's globalconf.wallpaper exactly.
     */
    cairo_surface_t *wallpaper;

    /** Wallpaper scene graph node
     * Wayland-specific: wlr_scene_buffer in LyrBg layer for display
     */
    struct wlr_scene_buffer *wallpaper_buffer_node;

    /* ========== WALLPAPER CACHE ========== */

    /** Wallpaper cache for instant switching (toggle visibility vs destroy/recreate)
     * Cache entries are keyed by filepath. When switching to a cached wallpaper,
     * we just toggle scene node visibility instead of re-creating the buffer.
     */
    struct wl_list wallpaper_cache;

    /** Currently visible wallpaper cache entry (or NULL) */
    struct wallpaper_cache_entry *current_wallpaper;

    /* ========== SYSTRAY SUPPORT ========== */

    /** System tray state (StatusNotifierItem protocol)
     * Unlike AwesomeWM's X11 XEmbed approach, we use D-Bus SNI protocol
     * and render icons as scene graph nodes within the parent drawin.
     */
    struct {
        /** Parent drawin where systray is rendered */
        drawin_t *parent;
        /** Scene tree containing icon buffer nodes (child of drawin's scene) */
        struct wlr_scene_tree *scene_tree;
        /** Background color (ARGB pixel value) */
        uint32_t background_pixel;
        /** Current layout parameters (cached from last render call) */
        struct {
            int x, y;           /* Position within parent drawin */
            int base_size;      /* Icon size */
            bool horizontal;    /* Layout direction */
            bool reverse;       /* Reverse order */
            int spacing;        /* Spacing between icons */
            int rows;           /* Max rows in grid */
        } layout;
        /** Textures for rendered icons (lazily created, keyed by item pointer) */
        void *icon_textures;  /* TODO: hash table of wlr_texture* */
    } systray;

    /* ========== X11 COMPATIBILITY STUBS ========== */
    /* These are kept as stubs for XWayland compatibility
     * and to maintain API compatibility with AwesomeWM's C code.
     * Most will be NULL/0 in pure Wayland mode. */

    /** X11 connection (NULL for pure Wayland, set for XWayland) */
    void *connection;

    /** Latest timestamp (for XWayland protocol operations) */
    uint32_t timestamp;

    /** X11 enter/leave event tracking (stubs for Wayland) */
    xcb_void_cookie_t pending_enter_leave_begin;
    sequence_pair_array_t ignore_enter_leave_events;

    /** X11 visual/depth information (stubs for Wayland) */
    struct {
        uint32_t visual_id;
    } *visual;
    void *default_visual;
    uint8_t default_depth;

    /** X11 screen (stub for XWayland) */
    struct {
        uint32_t root;
        uint32_t black_pixel;
        uint8_t root_depth;
        uint32_t root_visual;  /* For EWMH initialization */
    } *screen;

#ifdef XWAYLAND
    /** EWMH (Extended Window Manager Hints) state tracking
     * This maintains the EWMH support window and advertised capabilities
     * for XWayland clients. Matches AwesomeWM's ewmh tracking exactly.
     */
    struct {
        xcb_window_t window;              /* _NET_SUPPORTING_WM_CHECK window */
        xcb_atom_t *supported_atoms;      /* List of supported atoms */
        size_t supported_atoms_count;     /* Number of atoms (46 EWMH atoms) */
    } ewmh;
#endif

    /** Drawable under mouse for enter/leave signals */
    drawable_t *drawable_under_mouse;

    /** X11 colormap (stub for XWayland) */
    uint32_t default_cmap;

    /** Shape extension available */
    bool have_shape;

    /** Event loop (stub for XWayland) */
    void *loop;

    /** X11 graphics context (stub) */
    uint32_t gc;

    /** Windows to destroy later (X11/XWayland specific) */
    /* TODO: Define xcb_window_array_t */
    struct {
        xcb_window_t *tab;
        int len, size;
    } destroy_later_windows;

} awesome_t;

/** Global instance of the configuration structure */
extern awesome_t globalconf;

/** Get the Lua state from globalconf.
 *
 * You should always use this as: lua_State *L = globalconf_get_lua_State().
 * This prevents coroutine-related problems and provides a stable API.
 *
 * @return The global Lua state
 *
 * This matches AwesomeWM's pattern for getting the Lua state.
 * Always use this instead of accessing globalconf.L directly.
 */
static inline lua_State *globalconf_get_lua_State(void)
{
    return globalconf.L;
}

/** Initialize the global configuration structure.
 *
 * This should be called early in main() before any other subsystems.
 *
 * @param L The Lua state to use
 */
void globalconf_init(lua_State *L);

/** Cleanup the global configuration structure.
 *
 * This should be called at shutdown to free all allocated resources.
 */
void globalconf_wipe(void);

/** Update wallpaper from root window (X11-only stub).
 * Wayland wallpaper is set via root_set_wallpaper() or root_set_wallpaper_buffer().
 */
void root_update_wallpaper(void);

/** Initialize wallpaper cache (call after scene graph is created) */
void wallpaper_cache_init(void);

/** Cleanup wallpaper cache (call before destroying scene) */
void wallpaper_cache_cleanup(void);

#endif /* SOMEWM_GLOBALCONF_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
