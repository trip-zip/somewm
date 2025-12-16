/*
 * selection_watcher.c - selection change watcher
 *
 * Copyright 2019 Uli Schlachter <psychon@znc.in>
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

#include "objects/selection_watcher.h"
#include "objects/luaa.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "globalconf.h"

#include <string.h>
#include <stdlib.h>
#include <wlr/types/wlr_seat.h>

/* Access global compositor state from somewm.c */
extern struct wlr_seat *seat;

#define REGISTRY_WATCHER_TABLE_INDEX "somewm_selection_watchers"

typedef enum {
    SELECTION_CLIPBOARD,
    SELECTION_PRIMARY
} selection_type_t;

typedef struct selection_watcher_t
{
    LUA_OBJECT_HEADER
    /** Is this watcher currently active? Used as reference with luaL_ref */
    int active_ref;
    /** Which selection to watch: CLIPBOARD or PRIMARY */
    selection_type_t selection_type;
    /** Name of the selection ("CLIPBOARD" or "PRIMARY") */
    char *selection_name;
    /** Listener for set_selection event */
    struct wl_listener set_selection;
    /** Listener for set_primary_selection event */
    struct wl_listener set_primary_selection;
} selection_watcher_t;

static lua_class_t selection_watcher_class;
LUA_OBJECT_FUNCS(selection_watcher_class, selection_watcher_t, selection_watcher)

/** Handle selection change event from seat.
 * \param listener The wl_listener
 * \param data The seat (unused, we use globalconf)
 */
static void
handle_set_selection(struct wl_listener *listener, void *data)
{
    selection_watcher_t *watcher = wl_container_of(listener, watcher, set_selection);
    lua_State *L = globalconf_get_lua_State();

    /* Only emit if this watcher is active */
    if (watcher->active_ref == LUA_NOREF)
        return;

    /* Push the watcher object */
    luaA_object_push(L, watcher);

    /* Push whether selection has data (source != NULL) */
    lua_pushboolean(L, seat->selection_source != NULL);

    /* Emit signal */
    luaA_object_emit_signal(L, -2, "selection_changed", 1);

    lua_pop(L, 1);
}

/** Handle primary selection change event from seat.
 * \param listener The wl_listener
 * \param data The seat (unused, we use globalconf)
 */
static void
handle_set_primary_selection(struct wl_listener *listener, void *data)
{
    selection_watcher_t *watcher = wl_container_of(listener, watcher, set_primary_selection);
    lua_State *L = globalconf_get_lua_State();

    /* Only emit if this watcher is active */
    if (watcher->active_ref == LUA_NOREF)
        return;

    /* Push the watcher object */
    luaA_object_push(L, watcher);

    /* Push whether selection has data (source != NULL) */
    lua_pushboolean(L, seat->primary_selection_source != NULL);

    /* Emit signal */
    luaA_object_emit_signal(L, -2, "selection_changed", 1);

    lua_pop(L, 1);
}

/** Create a new selection watcher object.
 * \param L The Lua VM state.
 * \return The number of elements pushed on the stack.
 */
static int
luaA_selection_watcher_new(lua_State *L)
{
    size_t name_length;
    const char *name;
    selection_watcher_t *watcher;

    name = luaL_checklstring(L, 2, &name_length);
    watcher = (void *) selection_watcher_class.allocator(L);
    watcher->active_ref = LUA_NOREF;
    watcher->selection_name = strdup(name);

    /* Initialize listeners but don't connect yet */
    wl_list_init(&watcher->set_selection.link);
    wl_list_init(&watcher->set_primary_selection.link);

    /* Determine selection type */
    if (strcasecmp(name, "CLIPBOARD") == 0) {
        watcher->selection_type = SELECTION_CLIPBOARD;
    } else if (strcasecmp(name, "PRIMARY") == 0) {
        watcher->selection_type = SELECTION_PRIMARY;
    } else {
        /* Default to clipboard for unknown selection names */
        watcher->selection_type = SELECTION_CLIPBOARD;
    }

    return 1;
}

static int
luaA_selection_watcher_set_active(lua_State *L, selection_watcher_t *watcher)
{
    bool b = luaA_checkboolean(L, -1);
    bool is_active = watcher->active_ref != LUA_NOREF;

    if (b != is_active)
    {
        if (b)
        {
            /* Selection becomes active - connect listener */
            if (watcher->selection_type == SELECTION_CLIPBOARD) {
                watcher->set_selection.notify = handle_set_selection;
                wl_signal_add(&seat->events.set_selection, &watcher->set_selection);
            } else {
                watcher->set_primary_selection.notify = handle_set_primary_selection;
                wl_signal_add(&seat->events.set_primary_selection, &watcher->set_primary_selection);
            }

            /* Reference the selection watcher. For this, first get the tracking
             * table out of the registry. */
            lua_pushliteral(L, REGISTRY_WATCHER_TABLE_INDEX);
            lua_rawget(L, LUA_REGISTRYINDEX);

            /* Then actually get the reference */
            lua_pushvalue(L, -3 - 1);
            watcher->active_ref = luaL_ref(L, -2);

            /* And pop the tracking table again */
            lua_pop(L, 1);
        } else {
            /* Stop watching - disconnect listener */
            if (watcher->selection_type == SELECTION_CLIPBOARD) {
                wl_list_remove(&watcher->set_selection.link);
                wl_list_init(&watcher->set_selection.link);
            } else {
                wl_list_remove(&watcher->set_primary_selection.link);
                wl_list_init(&watcher->set_primary_selection.link);
            }

            /* Unreference the selection object */
            lua_pushliteral(L, REGISTRY_WATCHER_TABLE_INDEX);
            lua_rawget(L, LUA_REGISTRYINDEX);
            luaL_unref(L, -1, watcher->active_ref);
            lua_pop(L, 1);

            watcher->active_ref = LUA_NOREF;
        }
    }
    return 0;
}

static int
luaA_selection_watcher_get_active(lua_State *L, selection_watcher_t *watcher)
{
    lua_pushboolean(L, watcher->active_ref != LUA_NOREF);
    return 1;
}

/** Allocator for selection_watcher objects.
 * \param L The Lua VM state.
 * \return The new selection_watcher object.
 */
static selection_watcher_t *
selection_watcher_allocator(lua_State *L)
{
    selection_watcher_t *watcher = lua_newuserdata(L, sizeof(selection_watcher_t));
    memset(watcher, 0, sizeof(selection_watcher_t));

    /* Associate the class metatable */
    luaA_settype(L, &selection_watcher_class);
    lua_newtable(L);
    lua_newtable(L);
    lua_setmetatable(L, -2);
    luaA_setuservalue(L, -2);
    lua_pushvalue(L, -1);

    return watcher;
}

/** GC handler for selection_watcher objects.
 */
static int
luaA_selection_watcher_gc(lua_State *L)
{
    selection_watcher_t *watcher = luaL_checkudata(L, 1, "selection_watcher");

    /* Remove listener if still connected */
    if (!wl_list_empty(&watcher->set_selection.link))
        wl_list_remove(&watcher->set_selection.link);
    if (!wl_list_empty(&watcher->set_primary_selection.link))
        wl_list_remove(&watcher->set_primary_selection.link);

    /* Free the selection name */
    if (watcher->selection_name) {
        free(watcher->selection_name);
        watcher->selection_name = NULL;
    }

    return 0;
}

void
selection_watcher_class_setup(lua_State *L)
{
    static const struct luaL_Reg selection_watcher_methods[] =
    {
        LUA_CLASS_METHODS(selection_watcher)
        { "__call", luaA_selection_watcher_new },
        { NULL, NULL }
    };

    static const struct luaL_Reg selection_watcher_meta[] =
    {
        LUA_OBJECT_META(selection_watcher)
        LUA_CLASS_META
        { "__gc", luaA_selection_watcher_gc },
        { NULL, NULL }
    };

    /* Create registry table for tracking active watchers */
    lua_pushliteral(L, REGISTRY_WATCHER_TABLE_INDEX);
    lua_newtable(L);
    lua_rawset(L, LUA_REGISTRYINDEX);

    luaA_class_setup(L, &selection_watcher_class, "selection_watcher",
                     NULL,
                     (lua_class_allocator_t) selection_watcher_allocator,
                     NULL,
                     NULL,
                     luaA_class_index_miss_property, luaA_class_newindex_miss_property,
                     selection_watcher_methods,
                     selection_watcher_meta);

    luaA_class_add_property(&selection_watcher_class, "active",
                            (lua_class_propfunc_t) luaA_selection_watcher_set_active,
                            (lua_class_propfunc_t) luaA_selection_watcher_get_active,
                            (lua_class_propfunc_t) luaA_selection_watcher_set_active);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
