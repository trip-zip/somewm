/*
 * luaobject.h - useful functions for handling Lua objects
 *
 * Copyright © 2009 Julien Danjou <julien@danjou.info>
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

#ifndef AWESOME_COMMON_LUAOBJECT_H
#define AWESOME_COMMON_LUAOBJECT_H

#include "common/luaclass.h"
#include "objects/luaa.h"

/* Undefine simple macros from luaa.h so we can use proper class-based functions */
#ifdef luaA_checkudata
#undef luaA_checkudata
#endif
#ifdef luaA_toudata
#undef luaA_toudata
#endif

#define LUAA_OBJECT_REGISTRY_KEY "awesome.object.registry"

/* Lua 5.1/5.2 compatibility macros */
#if LUA_VERSION_NUM >= 502
#define luaA_setuservalue lua_setuservalue
#define luaA_getuservalue lua_getuservalue
#else
#define luaA_setuservalue lua_setfenv
#define luaA_getuservalue lua_getfenv
#endif

int luaA_settype(lua_State *, lua_class_t *);
void luaA_object_setup(lua_State *);
void * luaA_object_incref(lua_State *, int, int);
void luaA_object_decref(lua_State *, int, const void *);

/** Store an item in the environment table of an object.
 * \param L The Lua VM state.
 * \param ud The index of the object on the stack.
 * \param iud The index of the item on the stack.
 * \return The item reference.
 */
void *luaA_object_ref_item(lua_State *L, int ud, int iud);

/** Unref an item from the environment table of an object.
 * \param L The Lua VM state.
 * \param ud The index of the object on the stack.
 * \param ref item.
 */
static inline void
luaA_object_unref_item(lua_State *L, int ud, void *pointer)
{
    /* Get the env table from the object */
    luaA_getuservalue(L, ud);
    /* Decrement */
    luaA_object_decref(L, -1, pointer);
    /* Remove env table */
    lua_pop(L, 1);
}

/** Push an object item on the stack.
 * \param L The Lua VM state.
 * \param ud The object index on the stack.
 * \param pointer The item pointer.
 * \return The number of element pushed on stack.
 */
int luaA_object_push_item(lua_State *L, int ud, const void *pointer);

static inline void
luaA_object_registry_push(lua_State *L)
{
    lua_pushliteral(L, LUAA_OBJECT_REGISTRY_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
}

/** Reference an object and return a pointer to it.
 * That only works with userdata, table, thread or function.
 * \param L The Lua VM state.
 * \param oud The object index on the stack.
 * \return The object reference, or NULL if not referenceable.
 */
static inline void *
luaA_object_ref(lua_State *L, int oud)
{
    void *p;
    luaA_object_registry_push(L);
    p = luaA_object_incref(L, -1, oud < 0 ? oud - 1 : oud);
    lua_pop(L, 1);
    return p;
}

/** Reference an object and return a pointer to it checking its type.
 * That only works with userdata.
 * \param L The Lua VM state.
 * \param oud The object index on the stack.
 * \param class The class of object expected
 * \return The object reference, or NULL if not referenceable.
 */
static inline void *
luaA_object_ref_class(lua_State *L, int oud, lua_class_t *class)
{
    luaA_checkudata(L, oud, class);
    return luaA_object_ref(L, oud);
}

/** Unreference an object and return a pointer to it.
 * That only works with userdata, table, thread or function.
 * \param L The Lua VM state.
 * \param oud The object index on the stack.
 */
static inline void
luaA_object_unref(lua_State *L, const void *pointer)
{
    luaA_object_registry_push(L);
    luaA_object_decref(L, -1, pointer);
    lua_pop(L, 1);
}

/** Push a referenced object onto the stack.
 * \param L The Lua VM state.
 * \param pointer The object to push.
 * \return The number of element pushed on stack.
 */
static inline int
luaA_object_push(lua_State *L, const void *pointer)
{
    luaA_object_registry_push(L);
    lua_pushlightuserdata(L, (void *) pointer);
    lua_rawget(L, -2);
    lua_remove(L, -2);
    return 1;
}

int luaA_dofunction(lua_State *, int, int);

void signal_object_emit(lua_State *, signal_array_t *, const char *, int);
signal_t *signal_array_getbyname(signal_array_t *, const char *);

void luaA_object_emit_signal(lua_State *, int, const char *, int);
void luaA_object_connect_signal(lua_State *, int, const char *, lua_CFunction);
void luaA_object_disconnect_signal(lua_State *, int, const char *, lua_CFunction);
void luaA_object_connect_signal_from_stack(lua_State *, int, const char *, int);
void luaA_object_disconnect_signal_from_stack(lua_State *, int, const char *, int);
void luaA_awm_object_emit_signal(lua_State *, int, const char *, int);

int luaA_object_connect_signal_simple(lua_State *);
int luaA_object_disconnect_signal_simple(lua_State *);
int luaA_awm_object_emit_signal_simple(lua_State *);

#define LUA_OBJECT_FUNCS(lua_class, type, prefix)                              \
    LUA_CLASS_FUNCS(prefix, lua_class)                                         \
    static inline type *                                                       \
    prefix##_new(lua_State *L)                                                 \
    {                                                                          \
        type *p = lua_newuserdata(L, sizeof(type));                            \
        p_clear(p, 1);                                                         \
        (lua_class).instances++;                                               \
        luaA_settype(L, &(lua_class));                                         \
        lua_newtable(L);                                                       \
        lua_newtable(L);                                                       \
        lua_setmetatable(L, -2);                                               \
        lua_newtable(L);                                                       \
        lua_setfield(L, -2, "data");                                           \
        luaA_setuservalue(L, -2);                                              \
        lua_pushvalue(L, -1);                                                  \
        luaA_class_emit_signal(L, &(lua_class), "new", 1);                     \
        return p;                                                              \
    }

#define OBJECT_EXPORT_PROPERTY(pfx, type, field) \
    fieldtypeof(type, field) \
    pfx##_get_##field(type *object) \
    { \
        return object->field; \
    }

#define LUA_OBJECT_EXPORT_PROPERTY(pfx, type, field, pusher) \
    static int \
    luaA_##pfx##_get_##field(lua_State *L, type *object) \
    { \
        pusher(L, object->field); \
        return 1; \
    }

#define LUA_OBJECT_EXPORT_OPTIONAL_PROPERTY(pfx, type, field, pusher, empty_value) \
    static int \
    luaA_##pfx##_get_##field(lua_State *L, type *object) \
    { \
        if (object->field == empty_value) \
            return 0; \
        pusher(L, object->field); \
        return 1; \
    }

int luaA_object_tostring(lua_State *);

#define LUA_OBJECT_META(prefix) \
    { "__tostring", luaA_object_tostring }, \
    { "connect_signal", luaA_object_connect_signal_simple }, \
    { "disconnect_signal", luaA_object_disconnect_signal_simple }, \
    { "emit_signal", luaA_awm_object_emit_signal_simple },

#endif

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
