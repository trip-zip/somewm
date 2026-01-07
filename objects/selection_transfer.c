/*
 * selection_transfer.c - selection data transfer
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

#include "objects/selection_transfer.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "globalconf.h"

#include <string.h>
#include <unistd.h>
#include <xcb/xcb.h>

typedef struct selection_transfer_t
{
    LUA_OBJECT_HEADER
    /** File descriptor to write data to */
    int fd;
    /** MIME type being transferred */
    char *mime_type;
    /** Whether transfer is complete */
    bool finished;
} selection_transfer_t;

static lua_class_t selection_transfer_class;
LUA_OBJECT_FUNCS(selection_transfer_class, selection_transfer_t, selection_transfer)

/** Reject a selection transfer request (X11-only).
 * \param requestor The requesting window.
 * \param selection The selection atom.
 * \param target The target atom.
 * \param time The timestamp.
 */
void
selection_transfer_reject(xcb_window_t requestor, xcb_atom_t selection,
                          xcb_atom_t target, xcb_timestamp_t time)
{
    /* X11-only: Sends SelectionNotify with property=None.
     * Wayland transfer rejection is handled by closing fd. */
    (void)requestor;
    (void)selection;
    (void)target;
    (void)time;
}

/** Begin a selection transfer (X11-only).
 * \param L The Lua VM state.
 * \param ud The selection_acquire userdata index.
 * \param requestor The requesting window.
 * \param selection The selection atom.
 * \param target The target atom.
 * \param property The property to write to.
 * \param time The timestamp.
 */
void
selection_transfer_begin(lua_State *L, int ud, xcb_window_t requestor,
                         xcb_atom_t selection, xcb_atom_t target,
                         xcb_atom_t property, xcb_timestamp_t time)
{
    /* X11-only: Creates transfer object and emits request signal.
     * Wayland transfer is initiated via wlr_data_source send callback. */
    (void)L;
    (void)ud;
    (void)requestor;
    (void)selection;
    (void)target;
    (void)property;
    (void)time;
}

/** Handle X11 property notify for selection transfer.
 * \param ev The property notify event.
 */
void
selection_transfer_handle_propertynotify(xcb_property_notify_event_t *ev)
{
    /* X11-only: Handles incremental transfer via property changes.
     * Wayland uses direct fd writes. */
    (void)ev;
}

/** Send data to the requestor.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 *
 * Usage: transfer:send{data="content"}
 */
static int
luaA_selection_transfer_send(lua_State *L)
{
    selection_transfer_t *transfer = luaA_checkudata(L, 1, &selection_transfer_class);
    const char *data;
    size_t data_len;

    if (transfer->finished || transfer->fd < 0) {
        return luaL_error(L, "Transfer already finished or invalid fd");
    }

    luaA_checktable(L, 2);

    lua_getfield(L, 2, "data");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return luaL_error(L, "Missing 'data' field in send table");
    }

    data = lua_tolstring(L, -1, &data_len);
    lua_pop(L, 1);

    /* Write data to fd */
    if (data && data_len > 0) {
        ssize_t written = 0;
        while ((size_t)written < data_len) {
            ssize_t n = write(transfer->fd, data + written, data_len - written);
            if (n < 0) {
                /* Write error - close and finish */
                break;
            }
            written += n;
        }
    }

    /* Close fd and mark finished */
    close(transfer->fd);
    transfer->fd = -1;
    transfer->finished = true;

    return 0;
}

/** Get the MIME type being transferred.
 * \param L The Lua VM state.
 * \param transfer The transfer object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_selection_transfer_get_mime_type(lua_State *L, selection_transfer_t *transfer)
{
    if (transfer->mime_type)
        lua_pushstring(L, transfer->mime_type);
    else
        lua_pushnil(L);
    return 1;
}

/** Allocator for selection_transfer objects.
 * \param L The Lua VM state.
 * \return The new selection_transfer object.
 */
static selection_transfer_t *
selection_transfer_allocator(lua_State *L)
{
    selection_transfer_t *transfer = lua_newuserdata(L, sizeof(selection_transfer_t));
    memset(transfer, 0, sizeof(selection_transfer_t));
    transfer->fd = -1;

    /* Associate the class metatable */
    luaA_settype(L, &selection_transfer_class);
    lua_newtable(L);
    lua_newtable(L);
    lua_setmetatable(L, -2);
    luaA_setuservalue(L, -2);
    lua_pushvalue(L, -1);

    return transfer;
}

/** GC handler for selection_transfer objects.
 */
static int
luaA_selection_transfer_gc(lua_State *L)
{
    selection_transfer_t *transfer = luaL_checkudata(L, 1, "selection_transfer");

    if (transfer->fd >= 0) {
        close(transfer->fd);
        transfer->fd = -1;
    }

    if (transfer->mime_type) {
        free(transfer->mime_type);
        transfer->mime_type = NULL;
    }

    return 0;
}

/** Create a new transfer object (called internally by selection_acquire).
 * Pushes the new transfer object onto the Lua stack.
 * \param L The Lua VM state.
 * \param mime_type The MIME type being requested.
 * \param fd The file descriptor to write data to.
 */
void
selection_transfer_create(lua_State *L, const char *mime_type, int fd)
{
    selection_transfer_t *transfer = (void *) selection_transfer_class.allocator(L);
    transfer->fd = fd;
    transfer->mime_type = strdup(mime_type);
    transfer->finished = false;
}

void
selection_transfer_class_setup(lua_State *L)
{
    static const struct luaL_Reg selection_transfer_methods[] =
    {
        LUA_CLASS_METHODS(selection_transfer)
        { NULL, NULL }
    };

    static const struct luaL_Reg selection_transfer_meta[] =
    {
        LUA_OBJECT_META(selection_transfer)
        LUA_CLASS_META
        { "__gc", luaA_selection_transfer_gc },
        { "send", luaA_selection_transfer_send },
        { NULL, NULL }
    };

    luaA_class_setup(L, &selection_transfer_class, "selection_transfer",
                     NULL,
                     (lua_class_allocator_t) selection_transfer_allocator,
                     NULL,
                     NULL,
                     luaA_class_index_miss_property, luaA_class_newindex_miss_property,
                     selection_transfer_methods,
                     selection_transfer_meta);

    luaA_class_add_property(&selection_transfer_class, "mime_type",
                            NULL,
                            (lua_class_propfunc_t) luaA_selection_transfer_get_mime_type,
                            NULL);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
