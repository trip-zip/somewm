/*
 * selection_getter.c - selection content getter
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

#include "objects/selection_getter.h"
#include "objects/luaa.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "globalconf.h"

#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wayland-server-core.h>

/* Access global compositor state from somewm.c */
extern struct wlr_seat *seat;
extern struct wl_display *dpy;

#define REGISTRY_GETTER_TABLE_INDEX "somewm_selection_getters"
#define READ_BUFFER_SIZE 4096

typedef enum {
    SELECTION_CLIPBOARD,
    SELECTION_PRIMARY
} selection_type_t;

typedef struct selection_getter_t
{
    LUA_OBJECT_HEADER
    /** Lua registry reference to keep object alive during async read */
    int ref;
    /** Which selection: CLIPBOARD or PRIMARY */
    selection_type_t selection_type;
    /** Target MIME type to request */
    char *target;
    /** Read end of pipe */
    int read_fd;
    /** Event source for async reading */
    struct wl_event_source *event_source;
    /** Accumulated data buffer */
    char *data;
    size_t data_len;
    size_t data_capacity;
} selection_getter_t;

static lua_class_t selection_getter_class;
LUA_OBJECT_FUNCS(selection_getter_class, selection_getter_t, selection_getter)

/** Check if a MIME type is available in the data source.
 * \param source The data source to check.
 * \param mime_type The MIME type to look for.
 * \return true if the MIME type is available.
 */
static bool
source_has_mime_type(struct wlr_data_source *source, const char *mime_type)
{
    char **mime;
    wl_array_for_each(mime, &source->mime_types) {
        if (strcmp(*mime, mime_type) == 0)
            return true;
    }
    return false;
}

/** Check if a MIME type is available in the primary selection source.
 * \param source The primary selection source to check.
 * \param mime_type The MIME type to look for.
 * \return true if the MIME type is available.
 */
static bool
primary_source_has_mime_type(struct wlr_primary_selection_source *source, const char *mime_type)
{
    char **mime;
    wl_array_for_each(mime, &source->mime_types) {
        if (strcmp(*mime, mime_type) == 0)
            return true;
    }
    return false;
}

/** Cleanup getter after read completes or fails.
 * \param getter The getter to cleanup.
 */
static void
selection_getter_cleanup(selection_getter_t *getter)
{
    if (getter->event_source) {
        wl_event_source_remove(getter->event_source);
        getter->event_source = NULL;
    }
    if (getter->read_fd >= 0) {
        close(getter->read_fd);
        getter->read_fd = -1;
    }
    if (getter->data) {
        free(getter->data);
        getter->data = NULL;
        getter->data_len = 0;
        getter->data_capacity = 0;
    }

    /* Unreference the object */
    if (getter->ref != LUA_NOREF) {
        lua_State *L = globalconf_get_lua_State();
        lua_pushliteral(L, REGISTRY_GETTER_TABLE_INDEX);
        lua_rawget(L, LUA_REGISTRYINDEX);
        luaL_unref(L, -1, getter->ref);
        lua_pop(L, 1);
        getter->ref = LUA_NOREF;
    }
}

/** Handle readable event on the pipe.
 * \param fd The file descriptor that is readable.
 * \param mask Event mask.
 * \param data The selection_getter_t.
 * \return 0 to continue, 1 to remove source.
 */
static int
selection_getter_read_handler(int fd, uint32_t mask, void *data)
{
    selection_getter_t *getter = data;
    lua_State *L = globalconf_get_lua_State();
    char buffer[READ_BUFFER_SIZE];
    ssize_t nread;
    size_t new_capacity;
    char *new_data;

    if (mask & WL_EVENT_READABLE) {
        nread = read(fd, buffer, sizeof(buffer));
        if (nread > 0) {
            /* Append to data buffer */
            if (getter->data_len + (size_t)nread > getter->data_capacity) {
                new_capacity = getter->data_capacity * 2;
                if (new_capacity < getter->data_len + (size_t)nread)
                    new_capacity = getter->data_len + (size_t)nread;
                if (new_capacity < 1024)
                    new_capacity = 1024;
                new_data = realloc(getter->data, new_capacity);
                if (!new_data) {
                    /* Out of memory, emit what we have */
                    goto emit_data;
                }
                getter->data = new_data;
                getter->data_capacity = new_capacity;
            }
            memcpy(getter->data + getter->data_len, buffer, (size_t)nread);
            getter->data_len += (size_t)nread;
            return 0; /* Continue reading */
        } else if (nread == 0) {
            /* EOF - transfer complete */
            goto emit_data;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            /* Read error */
            goto emit_data;
        }
        return 0;
    }

    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) {
        goto emit_data;
    }

    return 0;

emit_data:
    /* Push the getter object */
    luaA_object_push(L, getter);

    /* Emit "data" signal with content */
    if (getter->data && getter->data_len > 0) {
        lua_pushlstring(L, getter->data, getter->data_len);
        luaA_object_emit_signal(L, -2, "data", 1);
    }

    /* Emit "data_end" signal */
    luaA_object_emit_signal(L, -1, "data_end", 0);

    lua_pop(L, 1);

    /* Cleanup */
    selection_getter_cleanup(getter);
    return 0;
}

/** Create a new selection getter object.
 * \param L The Lua VM state.
 * \return The number of elements pushed on the stack.
 */
static int
luaA_selection_getter_new(lua_State *L)
{
    selection_getter_t *getter;
    const char *selection_name = "CLIPBOARD";
    const char *target = "text/plain";
    struct wlr_data_source *source = NULL;
    struct wlr_primary_selection_source *primary_source = NULL;
    int pipe_fds[2];
    int flags;
    struct wl_event_loop *loop;

    /* Parse arguments: selection.getter{selection="CLIPBOARD", target="text/plain"} */
    luaA_checktable(L, 2);

    lua_getfield(L, 2, "selection");
    if (!lua_isnil(L, -1))
        selection_name = luaL_checkstring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "target");
    if (!lua_isnil(L, -1))
        target = luaL_checkstring(L, -1);
    lua_pop(L, 1);

    /* Create the getter object */
    getter = (void *) selection_getter_class.allocator(L);
    getter->ref = LUA_NOREF;
    getter->target = strdup(target);
    getter->read_fd = -1;
    getter->event_source = NULL;
    getter->data = NULL;
    getter->data_len = 0;
    getter->data_capacity = 0;

    /* Determine selection type */
    if (strcasecmp(selection_name, "PRIMARY") == 0) {
        getter->selection_type = SELECTION_PRIMARY;
    } else {
        getter->selection_type = SELECTION_CLIPBOARD;
    }

    /* Check for selection source */
    if (!seat) {
        /* No seat available, emit empty data */
        luaA_object_emit_signal(L, -1, "data_end", 0);
        return 1;
    }

    if (getter->selection_type == SELECTION_CLIPBOARD) {
        source = seat->selection_source;
        if (!source || !source_has_mime_type(source, target)) {
            /* No source or target not available */
            luaA_object_emit_signal(L, -1, "data_end", 0);
            return 1;
        }
    } else {
        primary_source = seat->primary_selection_source;
        if (!primary_source || !primary_source_has_mime_type(primary_source, target)) {
            /* No source or target not available */
            luaA_object_emit_signal(L, -1, "data_end", 0);
            return 1;
        }
    }

    /* Create pipe for data transfer */
    if (pipe(pipe_fds) != 0) {
        luaA_object_emit_signal(L, -1, "data_end", 0);
        return 1;
    }

    /* Set read end to non-blocking */
    flags = fcntl(pipe_fds[0], F_GETFL);
    fcntl(pipe_fds[0], F_SETFL, flags | O_NONBLOCK);

    getter->read_fd = pipe_fds[0];

    /* Reference the getter to keep it alive */
    lua_pushliteral(L, REGISTRY_GETTER_TABLE_INDEX);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_pushvalue(L, -2);
    getter->ref = luaL_ref(L, -2);
    lua_pop(L, 1);

    /* Add event source for reading */
    loop = wl_display_get_event_loop(dpy);
    getter->event_source = wl_event_loop_add_fd(loop, getter->read_fd,
        WL_EVENT_READABLE | WL_EVENT_HANGUP | WL_EVENT_ERROR,
        selection_getter_read_handler, getter);

    /* Request data from source - this sends the write end to the source owner */
    if (getter->selection_type == SELECTION_CLIPBOARD) {
        wlr_data_source_send(source, target, pipe_fds[1]);
    } else {
        wlr_primary_selection_source_send(primary_source, target, pipe_fds[1]);
    }
    /* Source implementation closes pipe_fds[1] after sending */

    return 1;
}

/** Allocator for selection_getter objects.
 * \param L The Lua VM state.
 * \return The new selection_getter object.
 */
static selection_getter_t *
selection_getter_allocator(lua_State *L)
{
    selection_getter_t *getter = lua_newuserdata(L, sizeof(selection_getter_t));
    memset(getter, 0, sizeof(selection_getter_t));
    getter->ref = LUA_NOREF;
    getter->read_fd = -1;

    /* Associate the class metatable */
    luaA_settype(L, &selection_getter_class);
    lua_newtable(L);
    lua_newtable(L);
    lua_setmetatable(L, -2);
    lua_setfenv(L, -2);
    lua_pushvalue(L, -1);

    return getter;
}

/** GC handler for selection_getter objects.
 */
static int
luaA_selection_getter_gc(lua_State *L)
{
    selection_getter_t *getter = luaL_checkudata(L, 1, "selection_getter");

    selection_getter_cleanup(getter);

    if (getter->target) {
        free(getter->target);
        getter->target = NULL;
    }

    return 0;
}

void
selection_getter_class_setup(lua_State *L)
{
    static const struct luaL_Reg selection_getter_methods[] =
    {
        LUA_CLASS_METHODS(selection_getter)
        { "__call", luaA_selection_getter_new },
        { NULL, NULL }
    };

    static const struct luaL_Reg selection_getter_meta[] =
    {
        LUA_OBJECT_META(selection_getter)
        LUA_CLASS_META
        { "__gc", luaA_selection_getter_gc },
        { NULL, NULL }
    };

    /* Create registry table for tracking active getters */
    lua_pushliteral(L, REGISTRY_GETTER_TABLE_INDEX);
    lua_newtable(L);
    lua_rawset(L, LUA_REGISTRYINDEX);

    luaA_class_setup(L, &selection_getter_class, "selection_getter",
                     NULL,
                     (lua_class_allocator_t) selection_getter_allocator,
                     NULL,
                     NULL,
                     luaA_class_index_miss_property, luaA_class_newindex_miss_property,
                     selection_getter_methods,
                     selection_getter_meta);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
