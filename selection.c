/*
 * selection.c - Selection handling
 *
 * Copyright 2009 Julien Danjou <julien@danjou.info>
 * Copyright 2009 Gregor Best <farhaven@googlemail.com>
 * Copyright 2024 somewm contributors
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

/** awesome selection (clipboard) API
 * @author Julien Danjou &lt;julien@danjou.info&gt;
 * @copyright 2008-2009 Julien Danjou
 * @module selection
 */

#include "selection.h"
#include "globalconf.h"
#include "common/lualib.h"

/** Move a global Lua value into a table field.
 * \param L The Lua VM state.
 * \param index Table index (will be converted to absolute).
 * \param global_name Name of the global to move.
 * \param local_name Field name in the table.
 */
static void
move_global_to_table(lua_State *L, int index, const char *global_name, const char *local_name)
{
    index = luaA_absindex(L, index);

    /* Get the global */
    lua_getglobal(L, global_name);
    if (lua_isnil(L, -1)) {
        /* Global doesn't exist yet, skip */
        lua_pop(L, 1);
        return;
    }

    /* Save it locally */
    lua_setfield(L, index, local_name);

    /* Set the global to nil */
    lua_pushnil(L);
    lua_setglobal(L, global_name);
}

/** Deprecated selection getter - returns error directing user to selection.getter
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_selection_get(lua_State *L)
{
    return luaL_error(L, "selection() is deprecated. Use selection.getter{} instead.");
}

/** Setup the selection module.
 * Creates the "selection" global table with metatable that provides:
 * - selection.getter{} - read clipboard content
 * - selection.acquire{} - own clipboard
 * - selection.watcher() - monitor clipboard changes
 * \param L The Lua VM state.
 */
void
selection_setup(lua_State *L)
{
    /* This table will be the "selection" global */
    lua_newtable(L);

    /* Setup a metatable */
    lua_newtable(L);

    /* metatable.__index = metatable */
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    /* Set __call for deprecated API (shows error message) */
    lua_pushcfunction(L, luaA_selection_get);
    lua_setfield(L, -2, "__call");

    /* Move class globals into the table.
     * These are created by *_class_setup() before selection_setup() is called.
     * selection_getter -> selection.getter
     * selection_acquire -> selection.acquire
     * selection_watcher -> selection.watcher
     */
    move_global_to_table(L, -2, "selection_acquire", "acquire");
    move_global_to_table(L, -2, "selection_getter", "getter");
    move_global_to_table(L, -2, "selection_watcher", "watcher");

    /* Set the metatable */
    lua_setmetatable(L, -2);

    /* Set the "selection" global */
    lua_setglobal(L, "selection");
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
