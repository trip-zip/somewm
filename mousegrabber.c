/*
 * mousegrabber.c - mouse pointer grabbing
 *
 * Adapted from AwesomeWM's mousegrabber.c for somewm (Wayland compositor)
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

/** Set a callback to process all mouse events.
 * @author Julien Danjou &lt;julien@danjou.info&gt;
 * @copyright 2008-2009 Julien Danjou
 * @coreclassmod mousegrabber
 */

#include "objects/mousegrabber.h"
#include "objects/luaa.h"
#include "globalconf.h"
#include "somewm_api.h"

#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <string.h>

/* External cursor manager from somewm.c */
extern struct wlr_xcursor_manager *cursor_mgr;

/* Track mousegrabber state */
static bool mousegrabber_active = false;
static char *mousegrabber_cursor_name = NULL;

/** Check if mousegrabber is currently active.
 * \return true if mousegrabber is running, false otherwise
 */
bool
mousegrabber_isrunning(void)
{
    return mousegrabber_active && globalconf.mousegrabber != LUA_REFNIL;
}

/** Handle pointer motion events during grab.
 * Routes motion events to Lua callback when mousegrabber is active.
 * \param L The Lua VM state
 * \param x The mouse X coordinate
 * \param y The mouse Y coordinate
 * \param button_states Array of 5 button states (pressed/not pressed)
 */
void
mousegrabber_handleevent(lua_State *L, double x, double y, int *button_states)
{
    int i;

    /* Create coords table: {x=, y=, buttons={}} */
    lua_newtable(L);

    /* Set x coordinate */
    lua_pushnumber(L, x);
    lua_setfield(L, -2, "x");

    /* Set y coordinate */
    lua_pushnumber(L, y);
    lua_setfield(L, -2, "y");

    /* Create buttons sub-table */
    lua_newtable(L);
    for (i = 0; i < 5; i++) {
        lua_pushboolean(L, button_states[i]);
        lua_rawseti(L, -2, i + 1); /* Lua uses 1-based indexing */
    }
    lua_setfield(L, -2, "buttons");

    /* The table is now on top of the stack, ready for the callback */
}

/** Stop grabbing the mouse pointer.
 *
 * @staticfct stop
 * @noreturn
 */
int
luaA_mousegrabber_stop(lua_State *L)
{
    struct wlr_cursor *cursor;

    /* Restore default cursor */
    cursor = some_get_cursor();
    if (cursor && cursor_mgr) {
        wlr_cursor_set_xcursor(cursor, cursor_mgr, "default");
    }

    /* Free cursor name if set */
    if (mousegrabber_cursor_name) {
        free(mousegrabber_cursor_name);
        mousegrabber_cursor_name = NULL;
    }

    /* Unregister Lua callback */
    if (globalconf.mousegrabber != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);
        globalconf.mousegrabber = LUA_REFNIL;
    }

    /* Mark as inactive */
    mousegrabber_active = false;

    return 0;
}

/** Grab the mouse pointer and list motions, calling callback function at each
 * motion. The callback function must return a boolean value: true to
 * continue grabbing, false to stop.
 * The function is called with one argument:
 * a table containing modifiers pointer coordinates.
 *
 * The list of valid cursors includes standard X cursor names like:
 *   "default", "crosshair", "pointer", "move", "text",
 *   "wait", "help", "progress", "all-scroll",
 *   "nw-resize", "n-resize", "ne-resize",
 *   "w-resize", "e-resize",
 *   "sw-resize", "s-resize", "se-resize"
 *
 * @tparam function func A callback function as described above.
 * @tparam string|nil cursor The name of a cursor to use while grabbing or `nil`
 * to not change the cursor.
 * @noreturn
 * @staticfct run
 */
static int
luaA_mousegrabber_run(lua_State *L)
{
    struct wlr_cursor *cursor;
    const char *cursor_name = NULL;

    fprintf(stderr, "[MOUSEGRABBER_RUN] Called!\n");

    /* Check if mousegrabber already running */
    if (globalconf.mousegrabber != LUA_REFNIL) {
        fprintf(stderr, "[MOUSEGRABBER_RUN] Already running, error!\n");
        return luaL_error(L, "mousegrabber already running");
    }

    /* Verify first argument is a function */
    luaL_checktype(L, 1, LUA_TFUNCTION);

    /* Get optional cursor name */
    if (!lua_isnil(L, 2)) {
        cursor_name = luaL_checkstring(L, 2);
    }

    /* Register Lua callback */
    luaA_registerfct(L, 1, &globalconf.mousegrabber);

    /* Set cursor if specified */
    cursor = some_get_cursor();
    if (cursor && cursor_mgr && cursor_name) {
        /* Store cursor name for cleanup */
        if (mousegrabber_cursor_name) {
            free(mousegrabber_cursor_name);
        }
        mousegrabber_cursor_name = strdup(cursor_name);

        /* Set the cursor */
        wlr_cursor_set_xcursor(cursor, cursor_mgr, cursor_name);
    }

    /* Mark mousegrabber as active */
    mousegrabber_active = true;

    fprintf(stderr, "[MOUSEGRABBER_RUN] Started successfully, ref=%d\n", globalconf.mousegrabber);

    return 0;
}

/** Check if mousegrabber is running.
 *
 * @treturn boolean True if running, false otherwise.
 * @staticfct isrunning
 */
static int
luaA_mousegrabber_isrunning_lua(lua_State *L)
{
    lua_pushboolean(L, mousegrabber_isrunning());
    return 1;
}

/** Initialize the mousegrabber Lua module
 * \param L The Lua VM state
 */
void
luaA_mousegrabber_setup(lua_State *L)
{
    static const struct luaL_Reg mousegrabber_methods[] = {
        { "run", luaA_mousegrabber_run },
        { "stop", luaA_mousegrabber_stop },
        { "isrunning", luaA_mousegrabber_isrunning_lua },
        { NULL, NULL }
    };

    /* Register the methods on the table at the top of the stack */
    luaL_register(L, NULL, mousegrabber_methods);
}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
