/*
 * selection_acquire.c - selection ownership acquisition
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

#include "objects/selection_acquire.h"
#include "objects/selection_transfer.h"
#include "objects/luaa.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "globalconf.h"

#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wayland-server-core.h>

/* Access global compositor state from somewm.c */
extern struct wlr_seat *seat;
extern struct wl_display *dpy;

#define REGISTRY_ACQUIRE_TABLE_INDEX "somewm_selection_acquires"

typedef enum {
    SELECTION_CLIPBOARD,
    SELECTION_PRIMARY
} selection_type_t;

/* Forward declaration */
typedef struct selection_acquire_t selection_acquire_t;

/* Custom data source that calls back to Lua */
struct lua_data_source {
    struct wlr_data_source base;
    selection_acquire_t *acquire;
};

/* Custom primary selection source that calls back to Lua */
struct lua_primary_source {
    struct wlr_primary_selection_source base;
    selection_acquire_t *acquire;
};

struct selection_acquire_t
{
    LUA_OBJECT_HEADER
    /** Lua registry reference to keep object alive */
    int ref;
    /** Which selection: CLIPBOARD or PRIMARY */
    selection_type_t selection_type;
    /** Our data source (for CLIPBOARD) */
    struct lua_data_source *source;
    /** Our primary source (for PRIMARY) */
    struct lua_primary_source *primary_source;
    /** Listener for source destroy */
    struct wl_listener destroy;
    /** Whether we still own the selection */
    bool active;
};

static lua_class_t selection_acquire_class;
LUA_OBJECT_FUNCS(selection_acquire_class, selection_acquire_t, selection_acquire)

/* Data source implementation */
static void
lua_data_source_send(struct wlr_data_source *wlr_source, const char *mime_type, int fd)
{
    struct lua_data_source *source = wl_container_of(wlr_source, source, base);
    selection_acquire_t *acquire = source->acquire;
    lua_State *L;

    if (!acquire || !acquire->active) {
        close(fd);
        return;
    }

    L = globalconf_get_lua_State();

    /* Push the acquire object */
    luaA_object_push(L, acquire);

    /* Create transfer object */
    selection_transfer_create(L, mime_type, fd);

    /* Emit "request" signal with target and transfer */
    lua_pushstring(L, mime_type);
    lua_pushvalue(L, -2); /* transfer object */
    luaA_object_emit_signal(L, -4, "request", 2);

    lua_pop(L, 2); /* pop transfer and acquire */
}

static void
lua_data_source_destroy(struct wlr_data_source *wlr_source)
{
    struct lua_data_source *source = wl_container_of(wlr_source, source, base);
    /* Just free the source, acquire handles cleanup via listener */
    free(source);
}

static const struct wlr_data_source_impl lua_data_source_impl = {
    .send = lua_data_source_send,
    .destroy = lua_data_source_destroy,
};

/* Primary selection source implementation */
static void
lua_primary_source_send(struct wlr_primary_selection_source *wlr_source,
                        const char *mime_type, int fd)
{
    struct lua_primary_source *source = wl_container_of(wlr_source, source, base);
    selection_acquire_t *acquire = source->acquire;
    lua_State *L;

    if (!acquire || !acquire->active) {
        close(fd);
        return;
    }

    L = globalconf_get_lua_State();

    /* Push the acquire object */
    luaA_object_push(L, acquire);

    /* Create transfer object */
    selection_transfer_create(L, mime_type, fd);

    /* Emit "request" signal with target and transfer */
    lua_pushstring(L, mime_type);
    lua_pushvalue(L, -2); /* transfer object */
    luaA_object_emit_signal(L, -4, "request", 2);

    lua_pop(L, 2); /* pop transfer and acquire */
}

static void
lua_primary_source_destroy(struct wlr_primary_selection_source *wlr_source)
{
    struct lua_primary_source *source = wl_container_of(wlr_source, source, base);
    free(source);
}

static const struct wlr_primary_selection_source_impl lua_primary_source_impl = {
    .send = lua_primary_source_send,
    .destroy = lua_primary_source_destroy,
};

/** Handle source destroy (we lost ownership). */
static void
handle_source_destroy(struct wl_listener *listener, void *data)
{
    selection_acquire_t *acquire = wl_container_of(listener, acquire, destroy);
    lua_State *L = globalconf_get_lua_State();

    if (!acquire->active)
        return;

    acquire->active = false;
    acquire->source = NULL;
    acquire->primary_source = NULL;

    /* Emit "release" signal */
    luaA_object_push(L, acquire);
    luaA_object_emit_signal(L, -1, "release", 0);
    lua_pop(L, 1);

    /* Remove listener */
    wl_list_remove(&acquire->destroy.link);
    wl_list_init(&acquire->destroy.link);

    /* Unreference the object */
    if (acquire->ref != LUA_NOREF) {
        lua_pushliteral(L, REGISTRY_ACQUIRE_TABLE_INDEX);
        lua_rawget(L, LUA_REGISTRYINDEX);
        luaL_unref(L, -1, acquire->ref);
        lua_pop(L, 1);
        acquire->ref = LUA_NOREF;
    }
}

/** Release selection ownership.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_selection_acquire_release(lua_State *L)
{
    selection_acquire_t *acquire = luaA_checkudata(L, 1, &selection_acquire_class);

    if (!acquire->active)
        return 0;

    /* Clear the selection - this will trigger our destroy listener */
    if (acquire->selection_type == SELECTION_CLIPBOARD) {
        if (seat->selection_source == &acquire->source->base) {
            wlr_seat_set_selection(seat, NULL, wl_display_get_serial(dpy));
        }
    } else {
        if (seat->primary_selection_source == &acquire->primary_source->base) {
            wlr_seat_set_primary_selection(seat, NULL, wl_display_get_serial(dpy));
        }
    }

    return 0;
}

/** Create a new selection acquire object.
 * \param L The Lua VM state.
 * \return The number of elements pushed on the stack.
 *
 * Usage: selection.acquire{selection="CLIPBOARD", mime_types={"text/plain", "text/html"}}
 */
static int
luaA_selection_acquire_new(lua_State *L)
{
    selection_acquire_t *acquire;
    const char *selection_name = "CLIPBOARD";

    /* Parse arguments */
    luaA_checktable(L, 2);

    lua_getfield(L, 2, "selection");
    if (!lua_isnil(L, -1))
        selection_name = luaL_checkstring(L, -1);
    lua_pop(L, 1);

    /* Create the acquire object */
    acquire = (void *) selection_acquire_class.allocator(L);
    acquire->ref = LUA_NOREF;
    acquire->source = NULL;
    acquire->primary_source = NULL;
    acquire->active = false;
    wl_list_init(&acquire->destroy.link);

    /* Determine selection type */
    if (strcasecmp(selection_name, "PRIMARY") == 0) {
        acquire->selection_type = SELECTION_PRIMARY;
    } else {
        acquire->selection_type = SELECTION_CLIPBOARD;
    }

    if (!seat) {
        return 1; /* Return inactive acquire object */
    }

    /* Get MIME types from argument table */
    lua_getfield(L, 2, "mime_types");

    if (acquire->selection_type == SELECTION_CLIPBOARD) {
        /* Create data source */
        struct lua_data_source *source = calloc(1, sizeof(*source));
        if (!source) {
            lua_pop(L, 1);
            return 1;
        }

        wlr_data_source_init(&source->base, &lua_data_source_impl);
        source->acquire = acquire;
        acquire->source = source;

        /* Add MIME types */
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_isstring(L, -1)) {
                    const char *mime = lua_tostring(L, -1);
                    char **p = wl_array_add(&source->base.mime_types, sizeof(*p));
                    if (p)
                        *p = strdup(mime);
                }
                lua_pop(L, 1);
            }
        } else {
            /* Default to text/plain if no MIME types specified */
            char **p = wl_array_add(&source->base.mime_types, sizeof(*p));
            if (p)
                *p = strdup("text/plain");
        }
        lua_pop(L, 1); /* pop mime_types */

        /* Listen for destroy */
        acquire->destroy.notify = handle_source_destroy;
        wl_signal_add(&source->base.events.destroy, &acquire->destroy);

        /* Set as selection owner */
        wlr_seat_set_selection(seat, &source->base,
                               wl_display_get_serial(dpy));
        acquire->active = true;

    } else {
        /* Create primary selection source */
        struct lua_primary_source *source = calloc(1, sizeof(*source));
        if (!source) {
            lua_pop(L, 1);
            return 1;
        }

        wlr_primary_selection_source_init(&source->base, &lua_primary_source_impl);
        source->acquire = acquire;
        acquire->primary_source = source;

        /* Add MIME types */
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_isstring(L, -1)) {
                    const char *mime = lua_tostring(L, -1);
                    char **p = wl_array_add(&source->base.mime_types, sizeof(*p));
                    if (p)
                        *p = strdup(mime);
                }
                lua_pop(L, 1);
            }
        } else {
            /* Default to text/plain if no MIME types specified */
            char **p = wl_array_add(&source->base.mime_types, sizeof(*p));
            if (p)
                *p = strdup("text/plain");
        }
        lua_pop(L, 1); /* pop mime_types */

        /* Listen for destroy */
        acquire->destroy.notify = handle_source_destroy;
        wl_signal_add(&source->base.events.destroy, &acquire->destroy);

        /* Set as selection owner */
        wlr_seat_set_primary_selection(seat, &source->base,
                                       wl_display_get_serial(dpy));
        acquire->active = true;
    }

    /* Reference the acquire object to keep it alive */
    lua_pushliteral(L, REGISTRY_ACQUIRE_TABLE_INDEX);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_pushvalue(L, -2);
    acquire->ref = luaL_ref(L, -2);
    lua_pop(L, 1);

    return 1;
}

/** Get whether the acquire is still active.
 */
static int
luaA_selection_acquire_get_active(lua_State *L, selection_acquire_t *acquire)
{
    lua_pushboolean(L, acquire->active);
    return 1;
}

/** Allocator for selection_acquire objects.
 */
static selection_acquire_t *
selection_acquire_allocator(lua_State *L)
{
    selection_acquire_t *acquire = lua_newuserdata(L, sizeof(selection_acquire_t));
    memset(acquire, 0, sizeof(selection_acquire_t));
    acquire->ref = LUA_NOREF;
    wl_list_init(&acquire->destroy.link);

    /* Associate the class metatable */
    luaA_settype(L, &selection_acquire_class);
    lua_newtable(L);
    lua_newtable(L);
    lua_setmetatable(L, -2);
    lua_setfenv(L, -2);
    lua_pushvalue(L, -1);

    return acquire;
}

/** GC handler for selection_acquire objects.
 */
static int
luaA_selection_acquire_gc(lua_State *L)
{
    selection_acquire_t *acquire = luaL_checkudata(L, 1, "selection_acquire");

    /* Remove listener if connected */
    if (!wl_list_empty(&acquire->destroy.link)) {
        wl_list_remove(&acquire->destroy.link);
        wl_list_init(&acquire->destroy.link);
    }

    /* Note: sources are freed by wlr_data_source_destroy when selection changes */

    return 0;
}

void
selection_acquire_class_setup(lua_State *L)
{
    static const struct luaL_Reg selection_acquire_methods[] =
    {
        LUA_CLASS_METHODS(selection_acquire)
        { "__call", luaA_selection_acquire_new },
        { NULL, NULL }
    };

    static const struct luaL_Reg selection_acquire_meta[] =
    {
        LUA_OBJECT_META(selection_acquire)
        LUA_CLASS_META
        { "__gc", luaA_selection_acquire_gc },
        { "release", luaA_selection_acquire_release },
        { NULL, NULL }
    };

    /* Create registry table for tracking active acquires */
    lua_pushliteral(L, REGISTRY_ACQUIRE_TABLE_INDEX);
    lua_newtable(L);
    lua_rawset(L, LUA_REGISTRYINDEX);

    luaA_class_setup(L, &selection_acquire_class, "selection_acquire",
                     NULL,
                     (lua_class_allocator_t) selection_acquire_allocator,
                     NULL,
                     NULL,
                     luaA_class_index_miss_property, luaA_class_newindex_miss_property,
                     selection_acquire_methods,
                     selection_acquire_meta);

    luaA_class_add_property(&selection_acquire_class, "active",
                            NULL,
                            (lua_class_propfunc_t) luaA_selection_acquire_get_active,
                            NULL);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
