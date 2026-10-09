/*
 * x11_compat.h - X11 names AwesomeWM's code expects
 *
 * Includes the XCB headers and holds the X11 event masks, shape kinds and
 * size limits, the area and MIN/MAX macros, and no-op stand-ins for the
 * AwesomeWM X11 helpers (key and button grabs, gravity, WM_STATE).
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

#include <xcb/xcb.h>
#include <cairo.h>
#include <limits.h>

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

/** Utility wrapper for ungrab_server */
static inline void xutil_ungrab_server(void *connection) {
    xcb_ungrab_server(connection);
}

/** Grab keys on window (stub - Wayland uses compositor keybindings) */
static inline void xwindow_grabkeys(xcb_window_t window, void *keys) {
    (void)window;
    (void)keys;
    /* No-op for Wayland - key handling is done through compositor */
}

/* Sequence pair array stubs - for enter/leave event tracking */
typedef struct {
    sequence_pair_t *tab;
    int len, size;
} sequence_pair_array_t;

static inline void sequence_pair_array_append(sequence_pair_array_t *arr, sequence_pair_t pair) {
    (void)arr;
    (void)pair;
    /* Stub for Wayland - X11 enter/leave event tracking not needed */
}

/* Spawn module stubs moved to spawn.c for AwesomeWM API parity */

/* Screen/monitor helper stubs */
typedef struct screen_t screen_t;

/* screen_client_moveto() and screen_update_workarea() now implemented in objects/screen.c */

/* Key/button array functions - now implemented in objects/key.c */
/* See objects/key.h for declarations of luaA_key_array_set and luaA_key_array_get */

/* Missing class/object stubs */
typedef struct lua_class_t lua_class_t;
extern lua_class_t window_class;  /* Declare but don't define - will link error if actually used */

/* Debug miss property handlers moved to luaa.c for AwesomeWM API parity */
#ifndef SOMEWM_LUACLASS_INCLUDED
/* Forward declare for when this is included before common/luaclass.h */
struct lua_object_t;
#endif

/* X11 atoms (stubs for Wayland) */
extern xcb_atom_t WM_TAKE_FOCUS;
extern xcb_atom_t _NET_STARTUP_ID;
extern xcb_atom_t WM_DELETE_WINDOW;
extern xcb_atom_t WM_PROTOCOLS;

/* X11 window gravity translation */
static inline void xwindow_translate_for_gravity(int gravity, int16_t change_width, int16_t change_height,
                                                  int16_t change_width2, int16_t change_height2,
                                                  int *dest_x, int *dest_y) {
    (void)gravity; (void)change_width; (void)change_height;
    (void)change_width2; (void)change_height2; (void)dest_x; (void)dest_y;
    /* TODO: Implement gravity calculation for X11 clients */
}

/* X11 property functions moved to property.c for AwesomeWM API parity */

/* EWMH functions removed - now implemented in ewmh.c */

/* Systray stubs moved to systray.c */

/* draw_find_visual moved to draw.c where it belongs (AwesomeWM parity) */

/* Shape extension stub */
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

static inline unsigned int unsigned_subtract(unsigned int a, unsigned int b) {
    return a > b ? a - b : 0;
}

/* screen_area_in_screen() now implemented in objects/screen.c */

/* drawable_set_geometry() now implemented in objects/drawable.c (AwesomeWM pattern) */

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

static inline void cairo_surface_array_push(cairo_surface_array_t *arr, void *surf) {
    if (arr->len >= arr->size) {
        int new_size = arr->size ? arr->size * 2 : 4;
        void **new_tab = realloc(arr->tab, (size_t)new_size * sizeof(void *));
        if (!new_tab) return;
        arr->tab = new_tab;
        arr->size = new_size;
    }
    arr->tab[arr->len++] = surf;
}

/* draw_dup_image_surface moved to draw.c where it belongs (AwesomeWM parity) */

/* client_set_icons - real implementation in objects/client.c */

static inline void cairo_surface_array_wipe(cairo_surface_array_t *arr) {
    if (arr->tab) {
        for (int i = 0; i < arr->len; i++)
            if (arr->tab[i])
                cairo_surface_destroy((cairo_surface_t *)arr->tab[i]);
        free(arr->tab);
        arr->tab = NULL;
    }
    arr->len = 0;
    arr->size = 0;
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
