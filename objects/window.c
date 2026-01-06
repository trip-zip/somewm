/* window.c - window object
 *
 * Copyright © 2009 Julien Danjou <julien@danjou.info>
 * Copyright © 2024 somewm contributors
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

/**
 * @signal property::border_color
 */

/**
 * @signal property::border_width
 */

/**
 * @signal property::buttons
 */

/**
 * @signal property::opacity
 */

/**
 * @signal property::struts
 */

/**
 * @signal property::type
 */

#include "objects/window.h"
#include "objects/button.h"
#include "objects/screen.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "common/util.h"
#include "strut.h"
#include "color.h"
#include "x11_compat.h"
#include "globalconf.h"
#include "luaa.h"
#include <lua.h>
#include <lauxlib.h>
#include <math.h>

/* Define the window_class - lua_class_t for window objects */
lua_class_t window_class;
LUA_CLASS_FUNCS(window, window_class)

/** Cleanup window resources.
 * \param window The window to wipe.
 */
static void
window_wipe(window_t *window)
{
    button_array_wipe(&window->buttons);
}

/** Get or set mouse buttons bindings on a window.
 * \param L The Lua VM state.
 * \return The number of elements pushed on the stack.
 */
static int
luaA_window_buttons(lua_State *L)
{
    window_t *window = luaA_checkudata(L, 1, &window_class);

    if(lua_gettop(L) == 2)
    {
        luaA_button_array_set(L, 1, 2, &window->buttons);
        luaA_object_emit_signal(L, 1, "property::buttons", 0);
        xwindow_buttons_grab(window->window, &window->buttons);
    }

    return luaA_button_array_get(L, 1, &window->buttons);
}

/** Return window struts (reserved space at the edge of the screen).
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_struts(lua_State *L)
{
    window_t *window = luaA_checkudata(L, 1, &window_class);

    if(lua_gettop(L) == 2)
    {
        luaA_tostrut(L, 2, &window->strut);
        luaA_object_emit_signal(L, 1, "property::struts", 0);
        /* We don't know the correct screen, update them all */
        foreach(s, globalconf.screens)
            screen_update_workarea(*s);
    }

    return luaA_pushstrut(L, window->strut);
}

/** Get the window opacity.
 * \param L The Lua VM state.
 * \param window The window object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_get_opacity(lua_State *L, window_t *window)
{
    if(window->opacity >= 0)
        lua_pushnumber(L, window->opacity);
    else
        /* Let's always return some "good" value */
        lua_pushnumber(L, 1);
    return 1;
}

/** Set a window opacity.
 * \param L The Lua VM state.
 * \param window The window object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_set_opacity(lua_State *L, window_t *window)
{
    if(lua_isnil(L, -1))
        window_set_opacity(L, -3, -1);
    else
    {
        double d = luaL_checknumber(L, -1);
        if(d >= 0 && d <= 1)
            window_set_opacity(L, -3, d);
    }
    return 0;
}

/** Set the window type.
 * \param L The Lua VM state.
 * \param w The window object.
 * \return The number of elements pushed on stack.
 */
int
luaA_window_set_type(lua_State *L, window_t *w)
{
    window_type_t type;
    const char *buf = luaL_checkstring(L, -1);

    if (A_STREQ(buf, "desktop"))
        type = WINDOW_TYPE_DESKTOP;
    else if(A_STREQ(buf, "dock"))
        type = WINDOW_TYPE_DOCK;
    else if(A_STREQ(buf, "splash"))
        type = WINDOW_TYPE_SPLASH;
    else if(A_STREQ(buf, "dialog"))
        type = WINDOW_TYPE_DIALOG;
    else if(A_STREQ(buf, "menu"))
        type = WINDOW_TYPE_MENU;
    else if(A_STREQ(buf, "toolbar"))
        type = WINDOW_TYPE_TOOLBAR;
    else if(A_STREQ(buf, "utility"))
        type = WINDOW_TYPE_UTILITY;
    else if(A_STREQ(buf, "dropdown_menu"))
        type = WINDOW_TYPE_DROPDOWN_MENU;
    else if(A_STREQ(buf, "popup_menu"))
        type = WINDOW_TYPE_POPUP_MENU;
    else if(A_STREQ(buf, "tooltip"))
        type = WINDOW_TYPE_TOOLTIP;
    else if(A_STREQ(buf, "notification"))
        type = WINDOW_TYPE_NOTIFICATION;
    else if(A_STREQ(buf, "combo"))
        type = WINDOW_TYPE_COMBO;
    else if(A_STREQ(buf, "dnd"))
        type = WINDOW_TYPE_DND;
    else if(A_STREQ(buf, "normal"))
        type = WINDOW_TYPE_NORMAL;
    else
    {
        luaA_warn(L, "Unknown window type '%s'", buf);
        return 0;
    }

    if(w->type != type)
    {
        w->type = type;
        /* Note: Wayland doesn't have EWMH atoms, so we skip ewmh_update_window_type */
        luaA_object_emit_signal(L, -3, "property::type", 0);
    }

    return 0;
}

/* Translate a window_type_t into the corresponding EWMH atom value.
 * Note: In Wayland, this is a no-op stub. Kept for API compatibility.
 * @param type The type to translate.
 * @return A constant representing the type (no actual EWMH atoms in Wayland).
 */
uint32_t
window_translate_type(window_type_t type)
{
    /* Wayland doesn't use EWMH atoms, return the type value directly */
    return (uint32_t)type;
}

/** Get border width property.
 * \param L The Lua VM state.
 * \param window The window object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_get_border_width(lua_State *L, window_t *window)
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
window_set_border_width(lua_State *L, int idx, int width)
{
    window_t *window = luaA_checkudata(L, idx, &window_class);
    uint16_t old_width = window->border_width;

    if(width == window->border_width || width < 0)
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
 * \param window The window object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_set_border_width(lua_State *L, window_t *window)
{
    (void)window;
    window_set_border_width(L, -3, round(luaA_checknumber_range(L, -1, 0, MAX_X11_SIZE)));
    return 0;
}

/** Get border color property.
 * \param L The Lua VM state.
 * \param window The window object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_get_border_color(lua_State *L, window_t *window)
{
    return luaA_pushcolor(L, &window->border_color);
}

/** Set border color property.
 * \param L The Lua VM state.
 * \param window The window object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_window_set_border_color(lua_State *L, window_t *window)
{
    const char *color_name = luaL_checkstring(L, -1);

    if(color_name && color_init_from_string(&window->border_color, color_name))
    {
        window->border_need_update = true;
        luaA_object_emit_signal(L, -3, "property::border_color", 0);
    }

    return 0;
}

/** Get a window type (as string).
 * \param L The Lua VM state.
 * \param w The window object.
 * \return The number of elements pushed on stack (1 string).
 */
int
luaA_window_get_type(lua_State *L, window_t *w)
{
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

/* Export window property (read-only) */
LUA_OBJECT_EXPORT_PROPERTY(window, window_t, window, lua_pushinteger)

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
        { "struts", luaA_window_struts },
        { "_buttons", luaA_window_buttons },
        { NULL, NULL }
    };

    luaA_class_setup(L, &window_class, "window", NULL,
                     NULL, (lua_class_collector_t) window_wipe, NULL,
                     luaA_class_index_miss_property, luaA_class_newindex_miss_property,
                     window_methods, window_meta);

    luaA_class_add_property(&window_class, "window",
                            NULL,
                            (lua_class_propfunc_t) luaA_window_get_window,
                            NULL);
    luaA_class_add_property(&window_class, "_opacity",
                            (lua_class_propfunc_t) luaA_window_set_opacity,
                            (lua_class_propfunc_t) luaA_window_get_opacity,
                            (lua_class_propfunc_t) luaA_window_set_opacity);
    luaA_class_add_property(&window_class, "_border_color",
                            (lua_class_propfunc_t) luaA_window_set_border_color,
                            (lua_class_propfunc_t) luaA_window_get_border_color,
                            (lua_class_propfunc_t) luaA_window_set_border_color);
    luaA_class_add_property(&window_class, "_border_width",
                            (lua_class_propfunc_t) luaA_window_set_border_width,
                            (lua_class_propfunc_t) luaA_window_get_border_width,
                            (lua_class_propfunc_t) luaA_window_set_border_width);
    luaA_class_add_property(&window_class, "type",
                            (lua_class_propfunc_t) luaA_window_set_type,
                            (lua_class_propfunc_t) luaA_window_get_type,
                            (lua_class_propfunc_t) luaA_window_set_type);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
