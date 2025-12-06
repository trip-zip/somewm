/*
 * tag.h - tag management header
 *
 * Adapted from AwesomeWM for somewm (Wayland compositor)
 * Copyright © 2007-2008 Julien Danjou <julien@danjou.info>
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

#ifndef SOMEWM_OBJECTS_TAG_H
#define SOMEWM_OBJECTS_TAG_H

#include <lua.h>
#include <stdbool.h>
#include "common/luaclass.h"
#include "common/luaobject.h"

/* Forward declarations */
typedef struct client_t client_t;
typedef struct screen_t screen_t;

/* Include array support */
#include "common/array.h"

/* Forward declare client_array_t - full definition in client.h */
typedef struct client_array_t {
    client_t **tab;
    int len, size;
} client_array_t;

/** Tag type - represents a workspace/desktop
 *
 * Tags in AwesomeWM (and somewm) are workspaces/virtual desktops.
 * Clients can be tagged with one or more tags, and viewing a tag
 * shows all clients that have that tag.
 *
 * IMPORTANT: This typedef must come BEFORE ARRAY_TYPE and function declarations
 * that use tag_t, otherwise the compiler sees incomplete type.
 */
typedef struct tag_t
{
    LUA_OBJECT_HEADER
    /** Tag name (user-visible label) */
    char *name;
    /** true if tag is activated (available for use) */
    bool activated;
    /** true if tag is currently selected/visible */
    bool selected;
    /** Array of clients that have this tag */
    client_array_t clients;

    /* AwesomeWM-compatible per-tag properties */
    /** Which screen this tag belongs to */
    screen_t *screen;
    /** Master width factor (0.0-1.0, 0.0 = use monitor default) */
    float mfact;
    /** Number of master windows (0 = use monitor default) */
    int nmaster;
} tag_t;

/* Declare tag_array_t type - must come AFTER tag_t typedef */
ARRAY_TYPE(tag_t *, tag)

/* Helper function declarations */
int tags_get_current_or_first_selected_index(void);
void tag_client(lua_State *, client_t *);
void untag_client(client_t *, tag_t *);
bool is_client_tagged(client_t *, tag_t *);
void tag_unref_simplified(tag_t **);

/* Define tag_array_t functions with DO_NOTHING destructor.
 * Tag objects are freed by Lua GC when lua_close() is called,
 * so we don't call tag_unref_simplified() during cleanup to avoid
 * accessing the closed Lua state. */
ARRAY_FUNCS(tag_t *, tag, DO_NOTHING)

/* Tag class for Lua object system */
extern lua_class_t tag_class;

/* Tag class setup (AwesomeWM pattern) */
void tag_class_setup(lua_State *L);

/* Tag initialization (creates tag_t objects and populates globalconf.tags) */
void luaA_tags_init(lua_State *L, int tagcount, const char **tagnames);

/* Property accessors (AwesomeWM compatibility) */
bool tag_get_selected(tag_t *);
char *tag_get_name(tag_t *);

#endif /* SOMEWM_OBJECTS_TAG_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
