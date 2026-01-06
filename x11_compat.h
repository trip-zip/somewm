/*
 * x11_compat.h - X11 compatibility stubs for Wayland
 *
 * This provides stub implementations of X11-specific functions and macros
 * used by AwesomeWM's client.c. These are no-ops for native Wayland clients
 * and will need proper implementation when XWayland support is added.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef SOMEWM_X11_COMPAT_H
#define SOMEWM_X11_COMPAT_H

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <wlr/util/box.h>  /* For struct wlr_box */
#include <lua.h>
#include <lauxlib.h>

/* Forward declare area_t - defined as typedef struct wlr_box area_t in client.h */
typedef struct wlr_box area_t;
/* lua_object_t is typedef'd in common/luaclass.h - don't redeclare it here */

/* Forward declarations for screen functions (defined in objects/screen.h and objects/luaa.h) */
typedef struct screen_t screen_t;
screen_t *luaA_screen_getbycoord(lua_State *L, int x, int y);

/* Include real XCB headers if available (wlroots includes them) */
#ifdef XWAYLAND
#include <xcb/xcb.h>
#include <cairo.h>
#include <limits.h>
#else
/* X11 constants (only if not using XWayland) */
#define XCB_NONE 0
#define XCB_COPY_FROM_PARENT 0
#define XCB_GET_PROPERTY_TYPE_ANY 0
#define UINT_MAX 0xFFFFFFFF
#endif

/* X11 event masks - always needed */
#ifndef CLIENT_SELECT_INPUT_EVENT_MASK
#define CLIENT_SELECT_INPUT_EVENT_MASK 0
#endif
#ifndef FRAME_SELECT_INPUT_EVENT_MASK
#define FRAME_SELECT_INPUT_EVENT_MASK 0
#endif
#ifndef ROOT_WINDOW_EVENT_MASK
#define ROOT_WINDOW_EVENT_MASK 0
#endif

#ifndef XWAYLAND

/* X11 type stubs (only if not using XWayland) */
typedef uint32_t xcb_window_t;
typedef uint32_t xcb_atom_t;
typedef uint32_t xcb_timestamp_t;
typedef uint32_t xcb_connection_t;

/* Void cookie stub */
typedef struct {
    uint32_t sequence;
} xcb_void_cookie_t;

/* Cairo stub */
typedef struct cairo_surface_t cairo_surface_t;
#endif

/* Sequence pair for enter/leave event tracking */
typedef struct {
    uint32_t begin;
    uint32_t end;
} sequence_pair_t;

/* X11 shape kinds (for window shaping) */
#ifndef XCB_SHAPE_SK_BOUNDING
#define XCB_SHAPE_SK_BOUNDING 0
#endif
#ifndef XCB_SHAPE_SK_INPUT
#define XCB_SHAPE_SK_INPUT 1
#endif
#ifndef XCB_SHAPE_SK_CLIP
#define XCB_SHAPE_SK_CLIP 2
#endif

/* X11 size/coordinate limits */
#define MAX_X11_SIZE 32767
#define MIN_X11_SIZE 0
#define MIN_X11_COORDINATE -32768
#define MAX_X11_COORDINATE 32767

/* warn(), fatal(), check() macros are now in util.h */
#include "common/util.h"

/* Area comparison macro */
#define AREA_EQUAL(a, b) \
    ((a).x == (b).x && (a).y == (b).y && \
     (a).width == (b).width && (a).height == (b).height)

/* Area boundary macros */
#define AREA_LEFT(a) ((a).x)
#define AREA_RIGHT(a) ((a).x + (a).width)
#define AREA_TOP(a) ((a).y)
#define AREA_BOTTOM(a) ((a).y + (a).height)

/* Utility macros */
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif

/* Forward declarations for client and window types */
typedef struct client_t client_t;

/* X11 function stubs - XCB functions are already defined if XWAYLAND is set.
 * We only need wrapper/utility functions here. */

#ifndef XWAYLAND
/** Stub for xcb_no_operation (returns empty cookie for Wayland) */
static inline xcb_void_cookie_t xcb_no_operation(void *connection) {
    (void)connection;
    xcb_void_cookie_t cookie = {0};
    return cookie;
}

/** Stub for xcb_ungrab_server */
static inline void xcb_ungrab_server(void *connection) {
    (void)connection;
}
#endif

/** Utility wrapper for ungrab_server */
static inline void xutil_ungrab_server(void *connection) {
    xcb_ungrab_server(connection);
}

/** Get window shape (stub - returns NULL for Wayland) */
static inline cairo_surface_t *xwindow_get_shape(xcb_window_t window, int kind) {
    (void)window;
    (void)kind;
    return NULL;  /* No shape support for Wayland clients */
}

/** Set window shape (stub - does nothing for Wayland) */
static inline void xwindow_set_shape(xcb_window_t window, int width, int height,
                                     int kind, cairo_surface_t *surf, int offset) {
    (void)window;
    (void)width;
    (void)height;
    (void)kind;
    (void)surf;
    (void)offset;
    /* No-op for Wayland */
}

/** Grab keys on window (stub - Wayland uses compositor keybindings) */
static inline void xwindow_grabkeys(xcb_window_t window, void *keys) {
    (void)window;
    (void)keys;
    /* No-op for Wayland - key handling is done through compositor */
}

/** Set window border (stub - Wayland uses server-side decorations) */
static inline void xwindow_set_border_width(void *connection, xcb_window_t window, uint32_t width) {
    (void)connection;
    (void)window;
    (void)width;
    /* No-op for Wayland */
}

/** Set client border attributes (stub) */
static inline void client_set_border_width_commit(client_t *c) {
    (void)c;
    /* TODO: Update wlr scene graph border */
}

/** Emit X11 events to Lua (stub) */
static inline void event_emit_refresh(void) {
    /* No-op for Wayland */
}

/* Sequence pair array stubs - for enter/leave event tracking */
typedef struct {
    sequence_pair_t *tab;
    int len, size;
} sequence_pair_array_t;

static inline void sequence_pair_array_init(sequence_pair_array_t *arr) {
    arr->tab = NULL;
    arr->len = 0;
    arr->size = 0;
}

static inline void sequence_pair_array_wipe(sequence_pair_array_t *arr) {
    if (arr->tab) {
        free(arr->tab);
        arr->tab = NULL;
    }
    arr->len = 0;
    arr->size = 0;
}

static inline void sequence_pair_array_append(sequence_pair_array_t *arr, sequence_pair_t pair) {
    (void)arr;
    (void)pair;
    /* Stub for Wayland - X11 enter/leave event tracking not needed */
}

/* Spawn module stubs */
static inline void spawn_init(void) {
    /* TODO: Initialize spawn tracking */
}

static inline void spawn_start_notify(client_t *c, const char *startup_id) {
    (void)c;
    (void)startup_id;
    /* TODO: Implement startup notification */
}

/* Screen/monitor helper stubs */
typedef struct screen_t screen_t;

/* screen_client_moveto() now implemented in objects/screen.c */

static inline void screen_update_workarea(screen_t *screen) {
    (void)screen;
    /* TODO: Recalculate workarea based on struts */
}

/* Client property functions */
static inline void client_set_border_width_callback(void *ctx, uint16_t old_width, uint16_t new_width) {
    (void)ctx;
    (void)old_width;
    (void)new_width;
    /* TODO: Implement border width change handling */
}

/* Key/button array functions - now implemented in objects/key.c */
/* See objects/key.h for declarations of luaA_key_array_set and luaA_key_array_get */

/* Missing class/object stubs */
typedef struct lua_class_t lua_class_t;
extern lua_class_t window_class;  /* Declare but don't define - will link error if actually used */

/* Stub functions for missing property handlers */
/* Note: These need the lua_object_t type, which is defined in common/luaclass.h.
 * We can't include that header here due to circular dependencies, so we
 * use inline function definitions that will work when this header is included
 * after common/luaclass.h (which happens in client.c). */
#ifndef SOMEWM_LUACLASS_INCLUDED
/* Forward declare for when this is included before common/luaclass.h */
struct lua_object_t;
static inline int luaA_class_index_miss_property(lua_State *L, struct lua_object_t *obj) {
    (void)L; (void)obj;
    return 0;
}
static inline int luaA_class_newindex_miss_property(lua_State *L, struct lua_object_t *obj) {
    (void)L; (void)obj;
    return 0;
}
#else
/* When included after common/luaclass.h, we have the real typedef */
static inline int luaA_class_index_miss_property(lua_State *L, lua_object_t *obj) {
    (void)L; (void)obj;
    return 0;
}
static inline int luaA_class_newindex_miss_property(lua_State *L, lua_object_t *obj) {
    (void)L; (void)obj;
    return 0;
}
#endif

/* Forward declaration for luaA_window_get_type */
typedef struct client_t client_t;

/* Implemented in window.c - uses client_t* instead of window_t* for simplicity */
int luaA_window_get_type(lua_State *L, client_t *w);

/* X11 atoms (stubs for Wayland) */
extern xcb_atom_t WM_TAKE_FOCUS;
extern xcb_atom_t _NET_STARTUP_ID;
extern xcb_atom_t WM_DELETE_WINDOW;
extern xcb_atom_t WM_PROTOCOLS;

/* X11 window functions */
static inline void xwindow_takefocus(xcb_window_t w) {
    (void)w;
    /* TODO: Implement for XWayland - send WM_TAKE_FOCUS client message */
}

#ifndef XWAYLAND

static inline xcb_void_cookie_t xcb_create_window(void *conn, uint8_t depth, xcb_window_t wid,
                                                   xcb_window_t parent, int16_t x, int16_t y,
                                                   uint16_t width, uint16_t height, uint16_t border_width,
                                                   uint16_t _class, uint32_t visual, uint32_t value_mask,
                                                   const void *value_list) {
    xcb_void_cookie_t cookie = {0};
    (void)conn; (void)depth; (void)wid; (void)parent; (void)x; (void)y;
    (void)width; (void)height; (void)border_width; (void)_class; (void)visual;
    (void)value_mask; (void)value_list;
    return cookie;
}
#endif /* XWAYLAND */

/* X11 window gravity translation */
static inline void xwindow_translate_for_gravity(int gravity, int16_t change_width, int16_t change_height,
                                                  int16_t change_width2, int16_t change_height2,
                                                  int *dest_x, int *dest_y) {
    (void)gravity; (void)change_width; (void)change_height;
    (void)change_width2; (void)change_height2; (void)dest_x; (void)dest_y;
    /* TODO: Implement gravity calculation for X11 clients */
}

/* X11 property getters - all return empty cookies for now */
#ifndef XWAYLAND
typedef struct { uint32_t sequence; } xcb_get_property_cookie_t;
#endif

static inline xcb_get_property_cookie_t property_get_wm_normal_hints(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_hints(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_transient_for(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_client_leader(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_client_machine(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_window_role(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_net_wm_pid(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_net_wm_icon(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_name(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_net_wm_name(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_icon_name(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_net_wm_icon_name(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_class(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_wm_protocols(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t property_get_motif_wm_hints(client_t *c) {
    xcb_get_property_cookie_t cookie = {0};
    (void)c;
    return cookie;
}

static inline xcb_get_property_cookie_t xwindow_get_opacity_unchecked(xcb_window_t w) {
    xcb_get_property_cookie_t cookie = {0};
    (void)w;
    return cookie;
}

/* X11 property update functions - process the replies from property_get_* */
static inline void property_update_wm_normal_hints(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_NORMAL_HINTS reply and update size_hints */
}

static inline void property_update_wm_hints(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_HINTS reply */
}

static inline void property_update_wm_transient_for(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_TRANSIENT_FOR reply */
}

static inline void property_update_wm_client_leader(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_CLIENT_LEADER reply */
}

static inline void property_update_wm_client_machine(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_CLIENT_MACHINE reply */
}

static inline void property_update_wm_window_role(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_WINDOW_ROLE reply */
}

static inline void property_update_net_wm_pid(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse _NET_WM_PID reply */
}

static inline void property_update_net_wm_icon(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse _NET_WM_ICON reply */
}

static inline void property_update_wm_name(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_NAME reply */
}

static inline void property_update_net_wm_name(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse _NET_WM_NAME reply */
}

static inline void property_update_wm_icon_name(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_ICON_NAME reply */
}

static inline void property_update_net_wm_icon_name(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse _NET_WM_ICON_NAME reply */
}

static inline void property_update_wm_class(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_CLASS reply */
}

static inline void property_update_wm_protocols(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_PROTOCOLS reply */
}

static inline void property_update_motif_wm_hints(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse _MOTIF_WM_HINTS reply */
}

static inline void property_update_wm_transient_for_window(client_t *c, xcb_get_property_cookie_t cookie) {
    (void)c; (void)cookie;
    /* TODO: Parse WM_TRANSIENT_FOR window reply */
}

static inline void xwindow_set_opacity(xcb_window_t w, double opacity) {
    (void)w; (void)opacity;
    /* TODO: Set _NET_WM_WINDOW_OPACITY property */
}

/* EWMH functions removed - now implemented in ewmh.c */

static inline double xwindow_get_opacity_from_cookie(xcb_get_property_cookie_t cookie) {
    (void)cookie;
    return 1.0;  /* Default: fully opaque */
}

static inline bool systray_iskdedockapp(xcb_window_t w) {
    (void)w;
    return false;  /* No systray support yet */
}

static inline void systray_request_handle(xcb_window_t w) {
    (void)w;
    /* TODO: Handle systray embed request */
}

static inline void *draw_find_visual(void *screen, uint32_t visual_id) {
    (void)screen; (void)visual_id;
    return NULL;  /* TODO: Find visual by ID */
}

/* screen_getbycoord - forward to luaA_screen_getbycoord
 * Implementation in screen.c to avoid header ordering issues */
screen_t *screen_getbycoord(int x, int y);

/* Shape extension stub - always use stub even with XWAYLAND */
static inline void xcb_shape_select_input(void *conn, xcb_window_t w, uint8_t enable) {
    (void)conn; (void)w; (void)enable;
    /* Stub for shape extension - not needed for Wayland */
}

/* window_set_border_width() now implemented in window.c - see window.h */

static inline void xwindow_set_state(xcb_window_t w, uint32_t state) {
    (void)w; (void)state;
    /* TODO: Set WM_STATE property */
}

/* ewmh_client_check_hints() removed - now implemented in ewmh.c */

static inline char *xutil_get_text_property_from_reply(void *reply) {
    (void)reply;
    return NULL;  /* TODO: Extract text from property reply */
}

static inline void event_handle(void *event) {
    (void)event;
    /* TODO: Handle X11 event */
}

static inline void xwindow_configure(xcb_window_t w, area_t geom, uint16_t border) {
    (void)w; (void)geom; (void)border;
    /* TODO: Send ConfigureNotify */
}

static inline unsigned int unsigned_subtract(unsigned int a, unsigned int b) {
    return a > b ? a - b : 0;
}

/* screen_area_in_screen() now implemented in objects/screen.c */

/* drawable_set_geometry() now implemented in objects/drawable.c (AwesomeWM pattern) */

/* Add globalconf.loop field stub */
static inline void *globalconf_get_loop(void) {
    return NULL;  /* TODO: Return event loop */
}

static inline void xwindow_buttons_grab(xcb_window_t w, void *buttons) {
    (void)w; (void)buttons;
    /* TODO: Grab mouse buttons on window */
}

static inline void window_array_append(void *arr, xcb_window_t w) {
    (void)arr; (void)w;
    /* TODO: Append window to array */
}

static inline bool luaA_checkboolean(void *L_void, int idx) {
    lua_State *L = (lua_State *)L_void;
    luaL_checktype(L, idx, LUA_TBOOLEAN);
    return lua_toboolean(L, idx);
}

/* Cairo surface array stub */
#ifndef CAIRO_SURFACE_ARRAY_T_DEFINED
#define CAIRO_SURFACE_ARRAY_T_DEFINED
typedef struct {
    void **tab;
    int len, size;
} cairo_surface_array_t;
#endif

static inline void cairo_surface_array_init(cairo_surface_array_t *arr) {
    arr->tab = NULL;
    arr->len = 0;
    arr->size = 0;
}

static inline void cairo_surface_array_push(cairo_surface_array_t *arr, void *surf) {
    (void)arr; (void)surf;
    /* TODO: Append surface to array */
}

#ifndef DRAW_H
/* Stub for draw_dup_image_surface when draw.h is not included */
static inline void *draw_dup_image_surface(void *surf) {
    (void)surf;
    return NULL;  /* TODO: Duplicate cairo surface */
}
#endif

/* client_set_icons - real implementation in objects/client.c */

static inline void *cairo_xcb_surface_create_for_bitmap(void *conn, void *screen, uint32_t pixmap, int w, int h) {
    (void)conn; (void)screen; (void)pixmap; (void)w; (void)h;
    return NULL;  /* Stub: Returns NULL on Wayland (X11-only function) */
}

static inline void cairo_surface_array_wipe(cairo_surface_array_t *arr) {
    if (arr->tab) {
        free(arr->tab);
        arr->tab = NULL;
    }
    arr->len = 0;
    arr->size = 0;
}

static inline void *cairo_xcb_surface_create(void *conn, uint32_t drawable, void *visual, int w, int h) {
    (void)conn; (void)drawable; (void)visual; (void)w; (void)h;
    return NULL;  /* Stub: Returns NULL on Wayland (X11-only function) */
}

/* Stub key_array_t - button_array_t is defined in objects/button.h */
#ifndef KEY_ARRAY_T_DEFINED
#define KEY_ARRAY_T_DEFINED
typedef struct {
    void **tab;
    int len, size;
} key_array_t;
#endif

static inline int luaA_pusharea(void *L_void, area_t area) {
    lua_State *L = (lua_State *)L_void;

    /* Create a new table for the geometry */
    lua_newtable(L);

    /* Set x field */
    lua_pushinteger(L, area.x);
    lua_setfield(L, -2, "x");

    /* Set y field */
    lua_pushinteger(L, area.y);
    lua_setfield(L, -2, "y");

    /* Set width field */
    lua_pushinteger(L, area.width);
    lua_setfield(L, -2, "width");

    /* Set height field */
    lua_pushinteger(L, area.height);
    lua_setfield(L, -2, "height");

    return 1;  /* Return the table */
}

#endif /* SOMEWM_X11_COMPAT_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
