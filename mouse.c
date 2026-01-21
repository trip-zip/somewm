/*
 * mouse.c - mouse managing
 *
 * Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
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

/** Manipulate and inspect the mouse cursor.
 *
 * The mouse buttons are represented as index. The common ones are:
 *
 * ![Client geometry](../images/mouse.svg)
 *
 * It is possible to be notified of mouse events by connecting to various
 * `client`, `widget`s and `wibox` signals:
 *
 *  * `mouse::enter`
 *  * `mouse::leave`
 *  * `mouse::press`
 *  * `mouse::release`
 *  * `mouse::move`
 *
 * See also `mousegrabber`
 *
 * @author Julien Danjou &lt;julien@danjou.info&gt;
 * @copyright 2008-2009 Julien Danjou
 * @inputmodule mouse
 */

#include "objects/mouse.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <math.h>
#include <string.h>

#include "somewm_api.h"
#include "somewm_types.h"
#include "common/lualib.h"
#include "common/util.h"
#include "luaa.h"
#include "globalconf.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/screen.h"

static int miss_index_handler    = LUA_REFNIL;
static int miss_newindex_handler = LUA_REFNIL;

/**
 * The `screen` under the cursor
 * @property screen
 * @tparam screen|nil screen
 */

/** Get the pointer position.
 * \param x will be set to the Pointer-x-coordinate relative to root
 * \param y will be set to the Pointer-y-coordinate relative to root
 * \param mask will be set to the current buttons state (5 buttons)
 * \return true on success, false if an error occurred
 **/
bool
mouse_query_pointer(int16_t *x, int16_t *y, uint16_t *mask)
{
    double dx, dy;
    int button_states[5];

    some_get_cursor_position(&dx, &dy);
    *x = (int16_t)dx;
    *y = (int16_t)dy;

    if (mask) {
        some_get_button_states(button_states);
        /* Convert button array to X11-style mask for API compatibility */
        *mask = 0;
        for (int i = 0; i < 5; i++) {
            if (button_states[i])
                *mask |= (1 << (8 + i)); /* XCB_BUTTON_MASK_1 = 1<<8, etc. */
        }
    }

    return true;
}

/** Get the pointer position on the screen.
 * \param x This will be set to the Pointer-x-coordinate relative to root.
 * \param y This will be set to the Pointer-y-coordinate relative to root.
 * \param mask This will be set to the current buttons state.
 * \return True on success, false if an error occurred.
 */
static bool
mouse_query_pointer_root(int16_t *x, int16_t *y, uint16_t *mask)
{
    return mouse_query_pointer(x, y, mask);
}

/** Set the pointer position.
 * \param x X-coordinate.
 * \param y Y-coordinate.
 */
static inline void
mouse_warp_pointer(int16_t x, int16_t y)
{
    some_set_cursor_position((double)x, (double)y, 0);
}

/** Push a table with mouse status.
 * \param L The Lua VM state.
 * \param x The x coordinate.
 * \param y The y coordinate.
 * \param mask The button mask.
 */
int
luaA_mouse_pushstatus(lua_State *L, int x, int y, uint16_t mask)
{
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, x);
    lua_setfield(L, -2, "x");
    lua_pushinteger(L, y);
    lua_setfield(L, -2, "y");

    lua_createtable(L, 5, 0);

    int i = 1;
    /* Convert X11-style mask to button array */
    for (uint16_t maski = (1 << 8); maski <= (1 << 12); maski <<= 1) {
        if (mask & maski)
            lua_pushboolean(L, true);
        else
            lua_pushboolean(L, false);
        lua_rawseti(L, -2, i++);
    }
    lua_setfield(L, -2, "buttons");
    return 1;
}

/* documented in lib/awful/mouse/init.lua */
static int
luaA_mouse_coords(lua_State *L)
{
    uint16_t mask;
    int x, y;
    int16_t mouse_x, mouse_y;

    if (lua_gettop(L) >= 1)
    {
        luaA_checktable(L, 1);
        bool ignore_enter_notify = (lua_gettop(L) == 2 && luaA_checkboolean(L, 2));

        if (!mouse_query_pointer_root(&mouse_x, &mouse_y, &mask))
            return 0;

        x = round(luaA_getopt_number_range(L, 1, "x", mouse_x, MIN_X11_COORDINATE, MAX_X11_COORDINATE));
        y = round(luaA_getopt_number_range(L, 1, "y", mouse_y, MIN_X11_COORDINATE, MAX_X11_COORDINATE));

        if (ignore_enter_notify) {
            /* X11/XWayland: use server grab to suppress events */
            if (globalconf.connection)
                client_ignore_enterleave_events();
            /* Wayland: use flag to ignore next enter/leave */
            globalconf.mouse_under.ignore_next_enter_leave = true;
        }

        mouse_warp_pointer(x, y);

        if (ignore_enter_notify && globalconf.connection)
            client_restore_enterleave_events();

        lua_pop(L, 1);
    }

    if (!mouse_query_pointer_root(&mouse_x, &mouse_y, &mask))
        return 0;

    return luaA_mouse_pushstatus(L, mouse_x, mouse_y, mask);
}

/** Get the client or any object which is under the pointer.
 *
 * @treturn client|wibox|nil A client, wibox or nil.
 * @staticfct object_under_pointer
 */
static int
luaA_mouse_object_under_pointer(lua_State *L)
{
    int16_t mouse_x, mouse_y;

    if (!mouse_query_pointer_root(&mouse_x, &mouse_y, NULL))
        return 0;

    drawin_t *drawin;
    client_t *client;

    if ((drawin = some_drawin_under_cursor()))
        return luaA_object_push(L, drawin);

    if ((client = some_object_under_cursor()))
        return luaA_object_push(L, client);

    return 0;
}

/** Mouse library.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 * \luastack
 * \lfield coords Mouse coordinates.
 * \lfield screen Mouse screen.
 */
static int
luaA_mouse_index(lua_State *L)
{
    const char *attr = luaL_checkstring(L, 2);
    int16_t mouse_x, mouse_y;

    /* attr is not "screen"?! */
    if (A_STRNEQ(attr, "screen")) {
        if (miss_index_handler != LUA_REFNIL) {
            return luaA_call_handler(L, miss_index_handler);
        }
        else
            return luaA_default_index(L);
    }

    if (!mouse_query_pointer_root(&mouse_x, &mouse_y, NULL))
    {
        /* Nothing ever handles mouse.screen being nil. Lying is better than
         * having lots of lua errors in this case.
         */
        if (globalconf.focus.client)
            luaA_object_push(L, globalconf.focus.client->screen);
        else
            luaA_object_push(L, luaA_screen_get_primary_screen(L));
        return 1;
    }

    luaA_object_push(L, luaA_screen_getbycoord(L, mouse_x, mouse_y));
    return 1;
}

/** Newindex for mouse.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_mouse_newindex(lua_State *L)
{
    const char *attr = luaL_checkstring(L, 2);
    screen_t *screen;

    if (A_STRNEQ(attr, "screen")) {
        /* Call the lua mouse property handler */
        if (miss_newindex_handler != LUA_REFNIL) {
            return luaA_call_handler(L, miss_newindex_handler);
        }
        else
            return luaA_default_newindex(L);
    }

    screen = luaA_checkscreen(L, 3);
    mouse_warp_pointer(screen->geometry.x, screen->geometry.y);
    return 0;
}

/**
 * Add a custom property handler (getter).
 * @staticfct set_index_miss_handler
 */
static int
luaA_mouse_set_index_miss_handler(lua_State *L)
{
    return luaA_registerfct(L, 1, &miss_index_handler);
}

/**
 * Add a custom property handler (setter).
 * @staticfct set_newindex_miss_handler
 */
static int
luaA_mouse_set_newindex_miss_handler(lua_State *L)
{
    return luaA_registerfct(L, 1, &miss_newindex_handler);
}

const struct luaL_Reg awesome_mouse_methods[] =
{
    { "__index", luaA_mouse_index },
    { "__newindex", luaA_mouse_newindex },
    { "coords", luaA_mouse_coords },
    { "object_under_pointer", luaA_mouse_object_under_pointer },
    { "set_index_miss_handler", luaA_mouse_set_index_miss_handler},
    { "set_newindex_miss_handler", luaA_mouse_set_newindex_miss_handler},
    { NULL, NULL }
};

const struct luaL_Reg awesome_mouse_meta[] =
{
    { NULL, NULL }
};

/** Initialize the mouse object for Lua.
 * Creates global 'mouse' object using AwesomeWM's luaA_openlib pattern.
 */
void
luaA_mouse_setup(lua_State *L)
{
    luaA_openlib(L, "mouse", awesome_mouse_methods, awesome_mouse_meta);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
