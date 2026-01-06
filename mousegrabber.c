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
#include "objects/mouse.h"
#include "luaa.h"
#include "common/lualib.h"
#include "globalconf.h"
#include "somewm_api.h"

#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>

/* External cursor manager from somewm.c */
extern struct wlr_xcursor_manager *cursor_mgr;

/* Track mousegrabber state */
static bool mousegrabber_active = false;
static char *mousegrabber_cursor_name = NULL;

/** Grab the mouse.
 * \param cursor The cursor to use while grabbing (unused in Wayland).
 * \return True if mouse was grabbed.
 *
 * Note: In Wayland, compositors inherently have pointer access, so this
 * is a no-op that always succeeds. The X11 version uses xcb_grab_pointer.
 */
static bool
mousegrabber_grab(uint32_t cursor)
{
    (void)cursor;
    /* Wayland compositors don't need explicit pointer grabbing like X11.
     * We just track state internally. Always return success. */
    return true;
}

/** Check if mousegrabber is currently active.
 * \return true if mousegrabber is running, false otherwise
 */
bool
mousegrabber_isrunning(void)
{
    return mousegrabber_active && globalconf.mousegrabber != LUA_REFNIL;
}

/** Handle mouse motion events.
 * \param L Lua stack to push the pointer motion.
 * \param x The received mouse event x component.
 * \param y The received mouse event y component.
 * \param mask The received mouse event bit mask.
 */
void
mousegrabber_handleevent(lua_State *L, int x, int y, uint16_t mask)
{
    luaA_mouse_pushstatus(L, x, y, mask);
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

    /* Attempt to grab (always succeeds in Wayland but matches AwesomeWM pattern) */
    if (!mousegrabber_grab(0)) {
        luaA_unregister(L, &globalconf.mousegrabber);
        luaL_error(L, "unable to grab mouse pointer");
    }

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

    return 0;
}

/** Check if mousegrabber is running.
 *
 * @treturn boolean True if running, false otherwise.
 * @staticfct isrunning
 */
static int
luaA_mousegrabber_isrunning(lua_State *L)
{
    lua_pushboolean(L, globalconf.mousegrabber != LUA_REFNIL);
    return 1;
}

const struct luaL_Reg awesome_mousegrabber_lib[] =
{
    { "run", luaA_mousegrabber_run },
    { "stop", luaA_mousegrabber_stop },
    { "isrunning", luaA_mousegrabber_isrunning },
    { "__index", luaA_default_index },
    { "__newindex", luaA_default_newindex },
    { NULL, NULL }
};

/** Initialize the mousegrabber Lua module
 * \param L The Lua VM state
 */
void
luaA_mousegrabber_setup(lua_State *L)
{
    /* Register the methods on the table at the top of the stack */
    luaA_setfuncs(L, awesome_mousegrabber_lib);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
