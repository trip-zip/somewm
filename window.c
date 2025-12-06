/* window.c - window class for AwesomeWM compatibility
 *
 * This file provides the window class required by client.c
 * In AwesomeWM, the window class is the base class for drawable windows (clients, etc.)
 * The window class provides common properties like border_width, border_color, opacity, buttons.
 * In somewm, this is a minimal implementation for Wayland.
 *
 * Note: In somewm, window_t is typedef'd but not a complete type.
 * We use client_t (which contains the window fields) for the implementation.
 */

#include "common/luaclass.h"
#include "x11_compat.h"
#include "objects/client.h"  /* For client_t which contains window fields */
#include <lua.h>

/* Define the window_class - lua_class_t for window objects */
lua_class_t window_class;

/* Minimal window_wipe for cleanup (no-op for now) */
static void
window_wipe(client_t *window)
{
    (void)window;
    /* TODO: Implement window cleanup if needed */
}

/** Get border width property.
 * \param L The Lua VM state.
 * \param window The window object (client_t contains window fields).
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_get_border_width(lua_State *L, client_t *window)
{
    lua_pushinteger(L, window->border_width);
    return 1;
}

/** Set opacity property (C API version).
 * \param L The Lua VM state.
 * \param idx The window object index on stack.
 * \param opacity The opacity value (0.0 to 1.0, or -1 for unset).
 */
void
window_set_opacity(lua_State *L, int idx, double opacity)
{
    window_t *window;
    double old_opacity;

    window = (window_t *)lua_touserdata(L, idx);
    if (!window)
        return;

    old_opacity = window->opacity;
    if (old_opacity == opacity)
        return;

    window->opacity = opacity;
    luaA_object_emit_signal(L, idx, "property::opacity", 0);
}

/** Set border width property (C API version).
 * \param L The Lua VM state.
 * \param idx The window object index on stack.
 * \param width The border width.
 */
void
window_set_border_width(lua_State *L, int idx, uint16_t width)
{
    client_t *window = luaA_checkudata(L, idx, &window_class);
    uint16_t old_width = window->border_width;

    if(width == window->border_width)
        return;

    window->border_need_update = true;
    window->border_width = width;

    if(window->border_width_callback)
        (*window->border_width_callback)(window, old_width, width);

    luaA_object_emit_signal(L, idx, "property::border_width", 0);
}

/** Refresh window borders (C API).
 * \param window The window object.
 */
void
window_border_refresh(window_t *window)
{
    if (!window || !window->border_need_update)
        return;

    /* Border refresh is implementation-specific (client vs drawin) */
    /* Actual rendering update happens in client.c or drawin.c */
    window->border_need_update = false;
}

/** Set border width property (Lua property setter).
 * \param L The Lua VM state.
 * \param window The window object (client_t contains window fields).
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_set_border_width(lua_State *L, client_t *window)
{
    int width = luaL_checkinteger(L, -1);

    if(width < 0)
        return 0;

    /* Call the C API version (window object is at index -3 from property setter) */
    window_set_border_width(L, -3, (uint16_t)width);
    return 0;
}

/** Get border color property.
 * \param L The Lua VM state.
 * \param window The window object (client_t contains window fields).
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_get_border_color(lua_State *L, client_t *window)
{
    /* Use luaA_pushcolor() to convert color_t to hex string */
    return luaA_pushcolor(L, &window->border_color);
}

/** Set border color property.
 * \param L The Lua VM state.
 * \param window The window object (client_t contains window fields).
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_set_border_color(lua_State *L, client_t *window)
{
    /* Parse color from Lua string (e.g., "#ff0000") */
    if(luaA_tocolor(L, -1, &window->border_color))
    {
        /* Mark border for update (triggers client_border_refresh()) */
        window->border_need_update = true;

        /* Emit property change signal (AwesomeWM pattern) */
        luaA_object_emit_signal(L, -3, "property::border_color", 0);
    }

    return 0;
}

/** Get a window type (as string).
 * \param L The Lua VM state.
 * \param window The window object (cast from client_t*).
 * \return The number of elements pushed on stack (1 string).
 */
int
luaA_window_get_type(lua_State *L, client_t *w)
{

    if (!w) {
        lua_pushnil(L);
        return 1;
    }
    switch(w->type)
    {
      case WINDOW_TYPE_DESKTOP:
        lua_pushliteral(L, "desktop");
        break;
      case WINDOW_TYPE_DOCK:
        lua_pushliteral(L, "dock");
        break;
      case WINDOW_TYPE_SPLASH:
        lua_pushliteral(L, "splash");
        break;
      case WINDOW_TYPE_DIALOG:
        lua_pushliteral(L, "dialog");
        break;
      case WINDOW_TYPE_MENU:
        lua_pushliteral(L, "menu");
        break;
      case WINDOW_TYPE_TOOLBAR:
        lua_pushliteral(L, "toolbar");
        break;
      case WINDOW_TYPE_UTILITY:
        lua_pushliteral(L, "utility");
        break;
      case WINDOW_TYPE_DROPDOWN_MENU:
        lua_pushliteral(L, "dropdown_menu");
        break;
      case WINDOW_TYPE_POPUP_MENU:
        lua_pushliteral(L, "popup_menu");
        break;
      case WINDOW_TYPE_TOOLTIP:
        lua_pushliteral(L, "tooltip");
        break;
      case WINDOW_TYPE_NOTIFICATION:
        lua_pushliteral(L, "notification");
        break;
      case WINDOW_TYPE_COMBO:
        lua_pushliteral(L, "combo");
        break;
      case WINDOW_TYPE_DND:
        lua_pushliteral(L, "dnd");
        break;
      case WINDOW_TYPE_NORMAL:
      default:
        lua_pushliteral(L, "normal");
        break;
    }
    return 1;
}

/** Setup the window class.
 * \param L The Lua VM state.
 */
void
window_class_setup(lua_State *L)
{
    static const struct luaL_Reg window_methods[] =
    {
        { NULL, NULL }
    };

    static const struct luaL_Reg window_meta[] =
    {
        /* TODO: Add window methods as needed (struts, buttons, xproperty, etc.) */
        { NULL, NULL }
    };

    /* Setup window class with no parent (it's the base class for client) */
    luaA_class_setup(L, &window_class, "window", NULL,
                     NULL, (lua_class_collector_t) window_wipe, NULL,
                     luaA_class_index_miss_property, luaA_class_newindex_miss_property,
                     window_methods, window_meta);

    /* Register border_width property (AwesomeWM pattern) */
    luaA_class_add_property(&window_class, "border_width",
                            (lua_class_propfunc_t) luaA_window_set_border_width,
                            (lua_class_propfunc_t) luaA_window_get_border_width,
                            (lua_class_propfunc_t) luaA_window_set_border_width);

    /* Register border_color property (AwesomeWM pattern) */
    luaA_class_add_property(&window_class, "border_color",
                            (lua_class_propfunc_t) luaA_window_set_border_color,
                            (lua_class_propfunc_t) luaA_window_get_border_color,
                            (lua_class_propfunc_t) luaA_window_set_border_color);

    /* TODO: Add more window properties (opacity, etc.) */
}
