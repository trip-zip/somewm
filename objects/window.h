/* window.h - window class for AwesomeWM compatibility */

#ifndef SOMEWM_WINDOW_H
#define SOMEWM_WINDOW_H

#include <lua.h>
#include <stdint.h>
#include <stdbool.h>
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "color.h"
#include "strut.h"
#include "somewm_types.h"  /* For window_type_t */

/* Forward declarations */
typedef struct button_t button_t;

#ifndef BUTTON_ARRAY_T_DEFINED
#define BUTTON_ARRAY_T_DEFINED
#include "common/array.h"
ARRAY_TYPE(button_t *, button)
#endif

/** Window object header - base fields for all window-like objects
 *
 * This macro defines the common fields shared by drawin_t and client_t,
 * matching AwesomeWM's WINDOW_OBJECT_HEADER pattern exactly.
 *
 * Differences from AwesomeWM:
 * - window/frame_window are uint32_t instead of xcb_window_t (Wayland compatibility)
 * - window is 0 for native Wayland windows (no X11 window ID)
 */
#define WINDOW_OBJECT_HEADER \
    LUA_OBJECT_HEADER \
    /** Wayland surface ID (replaces X window number, 0 for Wayland) */ \
    uint32_t window; \
    /** Frame window (always 0 on Wayland, kept for API compat) */ \
    uint32_t frame_window; \
    /** Opacity (0.0 to 1.0, or -1 for unset) */ \
    double opacity; \
    /** Strut - reserved screen space */ \
    strut_t strut; \
    /** Button bindings */ \
    button_array_t buttons; \
    /** Do we have pending border changes? */ \
    bool border_need_update; \
    /** Border color */ \
    color_t border_color; \
    /** Border width */ \
    uint16_t border_width; \
    /** The window type */ \
    window_type_t type; \
    /** The border width callback */ \
    void (*border_width_callback)(void *, uint16_t old, uint16_t new);

/** Window structure (base class) */
typedef struct {
    WINDOW_OBJECT_HEADER
} window_t;

/** Window class (global) */
extern lua_class_t window_class;

/** Setup the window class.
 * \param L The Lua VM state.
 */
void window_class_setup(lua_State *L);

/** Set window opacity (C API).
 * \param L The Lua VM state.
 * \param idx The window object index on stack.
 * \param opacity The opacity value (0.0 to 1.0, or -1 for unset).
 */
void window_set_opacity(lua_State *L, int idx, double opacity);

/** Set window border width (C API).
 * \param L The Lua VM state.
 * \param idx The window object index on stack.
 * \param width The border width.
 */
void window_set_border_width(lua_State *L, int idx, uint16_t width);

/** Refresh window borders (C API).
 * \param window The window object.
 */
void window_border_refresh(window_t *window);

#endif /* SOMEWM_WINDOW_H */
