/*
 * luaclass.c - useful functions for handling Lua classes
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

#include "common/luaclass.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "objects/luaa.h"
#include "util.h"
#include <string.h>

/* Undefine simple macros from luaa.h so we can use proper class-based functions */
#ifdef luaA_checkudata
#undef luaA_checkudata
#endif
#ifdef luaA_toudata
#undef luaA_toudata
#endif

#define CONNECTED_SUFFIX "::connected"

/* Compatibility macros - A_STREQ and a_strcmp are defined in util.h */

/* Note: luaA_getuservalue and luaA_setuservalue are defined in awm_luaobject.h */
/* Note: a_strlen is defined in util.h */

/* Forward declarations for helper functions */
static void luaA_setfuncs(lua_State *L, const struct luaL_Reg *l);
static void luaA_deprecate(lua_State *L, const char *message);

/* Forward declarations for signal functions (will be in signal.c or awm_luaobject.c) */
extern void signal_connect_awm(signal_array_t *arr, const char *name, const void *ref);
extern int signal_disconnect_awm(signal_array_t *arr, const char *name, const void *ref);

struct lua_class_property
{
    /** Name of the property */
    const char *name;
    /** Callback function called when the property is found in object creation. */
    lua_class_propfunc_t new;
    /** Callback function called when the property is found in object __index. */
    lua_class_propfunc_t index;
    /** Callback function called when the property is found in object __newindex. */
    lua_class_propfunc_t newindex;
};

DO_ARRAY(lua_class_t *, lua_class, DO_NOTHING)

static lua_class_array_t luaA_classes;

/** Set functions in a table (Lua 5.1/5.2 compat).
 * \param L The Lua VM state.
 * \param l The functions to set.
 */
static void
luaA_setfuncs(lua_State *L, const struct luaL_Reg *l)
{
#if LUA_VERSION_NUM >= 502
    luaL_setfuncs(L, l, 0);
#else
    luaL_register(L, NULL, l);
#endif
}

/** Register a library (Lua 5.1/5.2 compat).
 * \param L The Lua VM state.
 * \param libname Library name.
 * \param l The functions to register.
 */
void
luaA_registerlib(lua_State *L, const char *libname, const struct luaL_Reg *l)
{
#if LUA_VERSION_NUM >= 502
    lua_newtable(L);
    luaL_setfuncs(L, l, 0);
    lua_pushvalue(L, -1);
    lua_setglobal(L, libname);
#else
    luaL_register(L, libname, l);
#endif
}

/** Deprecation warning (stub).
 * \param L The Lua VM state.
 * \param message Warning message.
 */
static void
luaA_deprecate(lua_State *L, const char *message)
{
    /* In somewm, we can just print to stderr or ignore */
    (void)L;
    (void)message;
}

/** Convert a object to a udata if possible.
 * \param L The Lua VM state.
 * \param ud The index.
 * \param class The wanted class.
 * \return A pointer to the object, NULL otherwise.
 */
void *
luaA_toudata(lua_State *L, int ud, lua_class_t *class)
{
    void *p;
    lua_class_t *metatable_class;

    p = lua_touserdata(L, ud);
    if(p && lua_getmetatable(L, ud)) /* does it have a metatable? */
    {
        /* Get the lua_class_t that matches this metatable */
        lua_rawget(L, LUA_REGISTRYINDEX);
        metatable_class = lua_touserdata(L, -1);

        /* remove lightuserdata (lua_class pointer) */
        lua_pop(L, 1);

        /* Now, check that the class given in argument is the same as the
         * metatable's object, or one of its parent (inheritance) */
        for(; metatable_class; metatable_class = metatable_class->parent)
            if(metatable_class == class)
                return p;
    }
    return NULL;
}

/** Check for a udata class.
 * \param L The Lua VM state.
 * \param ud The object index on the stack.
 * \param class The wanted class.
 */
void *
luaA_checkudata(lua_State *L, int ud, lua_class_t *class)
{
    void *p = luaA_toudata(L, ud, class);
    if(!p)
        luaA_typerror(L, ud, class->name);
    else if(class->checker && !class->checker(p))
        luaL_error(L, "invalid object");
    return p;
}

/** Get an object lua_class.
 * \param L The Lua VM state.
 * \param idx The index of the object on the stack.
 */
lua_class_t *
luaA_class_get(lua_State *L, int idx)
{
    int type;
    lua_class_t *class;

    type = lua_type(L, idx);

    if(type == LUA_TUSERDATA && lua_getmetatable(L, idx))
    {
        /* Use the metatable has key to get the class from registry */
        lua_rawget(L, LUA_REGISTRYINDEX);
        class = lua_touserdata(L, -1);
        lua_pop(L, 1);
        return class;
    }

    return NULL;
}

/** Enhanced version of lua_typename that recognizes setup Lua classes.
 * \param L The Lua VM state.
 * \param idx The index of the object on the stack.
 */
const char *
luaA_typename(lua_State *L, int idx)
{
    int type = lua_type(L, idx);

    if(type == LUA_TUSERDATA)
    {
        lua_class_t *lua_class = luaA_class_get(L, idx);
        if(lua_class)
            return lua_class->name;
    }

    return lua_typename(L, type);
}

/* Note: luaA_openlib is provided by luaa.c, not needed here */

static int
lua_class_property_cmp(const void *a, const void *b)
{
    const lua_class_property_t *x = a, *y = b;
    return a_strcmp(x->name, y->name);
}

BARRAY_FUNCS(lua_class_property_t, lua_class_property, DO_NOTHING, lua_class_property_cmp)

void
luaA_class_add_property(lua_class_t *lua_class,
                        const char *name,
                        lua_class_propfunc_t cb_new,
                        lua_class_propfunc_t cb_index,
                        lua_class_propfunc_t cb_newindex)
{
    lua_class_property_array_insert(&lua_class->properties, (lua_class_property_t)
                                    {
                                        .name = name,
                                        .new = cb_new,
                                        .index = cb_index,
                                        .newindex = cb_newindex
                                    });
}

/** Newindex meta function for objects after they were GC'd.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_class_newindex_invalid(lua_State *L)
{
    return luaL_error(L, "attempt to index an object that was already garbage collected");
}

/** Index meta function for objects after they were GC'd.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_class_index_invalid(lua_State *L)
{
    const char *attr = luaL_checkstring(L, 2);
    if (A_STREQ(attr, "valid"))
    {
        lua_pushboolean(L, false);
        return 1;
    }
    return luaA_class_newindex_invalid(L);
}

/** Helper to wipe signal arrays for AwesomeWM compatibility.
 * Uses somewm's signal_array_t structure.
 */
extern void signal_array_wipe(signal_array_t *arr);

/** Garbage collect a Lua object.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_class_gc(lua_State *L)
{
    lua_object_t *item;
    lua_class_t *class;

    item = lua_touserdata(L, 1);
    signal_array_wipe(&item->signals);
    /* Get the object class */
    class = luaA_class_get(L, 1);
    class->instances--;
    /* Call the collector function of the class, and all its parent classes */
    for(; class; class = class->parent)
        if(class->collector)
            class->collector(item);
    /* Unset its metatable so that e.g. luaA_toudata() will no longer accept
     * this object. This is needed since other __gc methods can still use this.
     * We also make sure that `item.valid == false`.
     */
    lua_newtable(L);
    lua_pushcfunction(L, luaA_class_index_invalid);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, luaA_class_newindex_invalid);
    lua_setfield(L, -2, "__newindex");
    lua_setmetatable(L, 1);
    return 0;
}

/** Setup a new Lua class.
 * \param L The Lua VM state.
 * \param name The class name.
 * \param parent The parent class (inheritance).
 * \param allocator The allocator function used when creating a new object.
 * \param Collector The collector function used when garbage collecting an
 * object.
 * \param checker The check function to call when using luaA_checkudata().
 * \param index_miss_property Function to call when an object of this class
 * receive a __index request on an unknown property.
 * \param newindex_miss_property Function to call when an object of this class
 * receive a __newindex request on an unknown property.
 * \param methods The methods to set on the class table.
 * \param meta The meta-methods to set on the class objects.
 */
void
luaA_class_setup(lua_State *L, lua_class_t *class,
                 const char *name,
                 lua_class_t *parent,
                 lua_class_allocator_t allocator,
                 lua_class_collector_t collector,
                 lua_class_checker_t checker,
                 lua_class_propfunc_t index_miss_property,
                 lua_class_propfunc_t newindex_miss_property,
                 const struct luaL_Reg methods[],
                 const struct luaL_Reg meta[])
{
    /* Create the object metatable */
    lua_newtable(L);
    /* Register it with class pointer as key in the registry
     * class-pointer -> metatable */
    lua_pushlightuserdata(L, class);
    /* Duplicate the object metatable */
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
    /* Now register class pointer with metatable as key in the registry
     * metatable -> class-pointer */
    lua_pushvalue(L, -1);
    lua_pushlightuserdata(L, class);
    lua_rawset(L, LUA_REGISTRYINDEX);

    /* Duplicate objects metatable */
    lua_pushvalue(L, -1);
    /* Set garbage collector in the metatable */
    lua_pushcfunction(L, luaA_class_gc);
    lua_setfield(L, -2, "__gc");

    lua_setfield(L, -2, "__index"); /* metatable.__index = metatable      1 */

    luaA_setfuncs(L, meta);                                            /* 1 */
    luaA_registerlib(L, name, methods);                                /* 2 */
    lua_pushvalue(L, -1);           /* dup self as metatable              3 */
    lua_setmetatable(L, -2);        /* set self as metatable              2 */
    lua_pop(L, 2);

    class->collector = collector;
    class->allocator = allocator;
    class->name = name;
    class->index_miss_property = index_miss_property;
    class->newindex_miss_property = newindex_miss_property;
    class->checker = checker;
    class->parent = parent;
    class->tostring = NULL;
    class->instances = 0;
    class->index_miss_handler = LUA_REFNIL;
    class->newindex_miss_handler = LUA_REFNIL;

    /* CRITICAL: Initialize class-level signal array to prevent uninitialized memory bugs.
     * Without this, class->signals contains garbage which causes realloc() crashes
     * when Lua code connects signals before objects are created. AwesomeWM compatibility fix. */
    class->signals.signals = NULL;
    class->signals.count = 0;
    class->signals.capacity = 0;

    lua_class_array_append(&luaA_classes, class);
}

void
luaA_class_connect_signal(lua_State *L, lua_class_t *lua_class, const char *name, lua_CFunction fn)
{
    lua_pushcfunction(L, fn);
    luaA_class_connect_signal_from_stack(L, lua_class, name, -1);
}

void
luaA_class_connect_signal_from_stack(lua_State *L, lua_class_t *lua_class,
                                     const char *name, int ud)
{
    char *buf;
    lua_Debug ar;
    void *func_ptr;

    luaA_checkfunction(L, ud);

    /* Duplicate the function in the stack */
    lua_pushvalue(L, ud);

    buf = p_alloca(char, a_strlen(name) + a_strlen(CONNECTED_SUFFIX) + 1);

    /* Create a new signal to notify there is a global connection. */
    sprintf(buf, "%s%s", name, CONNECTED_SUFFIX);

    /* Emit a signal to notify Lua of the global connection.
     *
     * This can useful during initialization where the signal needs to be
     * artificially emitted for existing objects as soon as something connects
     * to it
     */
    luaA_class_emit_signal(L, lua_class, buf, 1);

    /* Register the signal to the CAPI list */
    /* Note: This uses luaobject's signal_connect which we'll implement in awm_luaobject.c */
    fprintf(stderr, "[CLASS_CONNECT] class='%s' registering handler on signal='%s' (emitted='%s')\n",
            lua_class->name, name, buf);

    /* Debug: Show function info */
    lua_pushvalue(L, ud);
    lua_getinfo(L, ">S", &ar);
    fprintf(stderr, "[CLASS_CONNECT] Function being registered: source=%s linedefined=%d\n",
            ar.source ? ar.source : "(null)", ar.linedefined);

    func_ptr = luaA_object_ref(L, ud);
    fprintf(stderr, "[CLASS_CONNECT] Stored function pointer: %p\n", func_ptr);
    signal_connect_awm(&lua_class->signals, name, func_ptr);
    fprintf(stderr, "[CLASS_CONNECT] registration complete for signal='%s'\n", name);
}

void
luaA_class_disconnect_signal_from_stack(lua_State *L, lua_class_t *lua_class,
                                        const char *name, int ud)
{
    void *ref;
    bool disconnected;

    fprintf(stderr, "[CLASS_DISCONNECT] class='%s' signal='%s' arg_type='%s'\n",
            lua_class->name, name, lua_typename(L, lua_type(L, ud)));

    luaA_checkfunction(L, ud);
    ref = (void *) lua_topointer(L, ud);

    disconnected = signal_disconnect_awm(&lua_class->signals, name, ref);
    fprintf(stderr, "[CLASS_DISCONNECT] disconnect %s for signal '%s' on class '%s'\n",
            disconnected ? "SUCCEEDED" : "FAILED", name, lua_class->name);

    if (disconnected)
        luaA_object_unref(L, (void *) ref);
    lua_remove(L, ud);
}

void
luaA_class_emit_signal(lua_State *L, lua_class_t *lua_class,
                       const char *name, int nargs)
{
    signal_t *sig;

    /* Check if there are any handlers */
    sig = signal_array_getbyname(&lua_class->signals, name);
    if (sig && sig->ref_count > 0) {
        fprintf(stderr, "[CLASS_EMIT] Found %zu handlers for '%s' on class '%s'\n",
                sig->ref_count, name, lua_class->name ? lua_class->name : "(null)");
    } else {
        fprintf(stderr, "[CLASS_EMIT] No handlers for '%s' on class '%s', skipping\n",
                name, lua_class->name ? lua_class->name : "(null)");
        /* Remove args from stack that signal_object_emit would have removed */
        lua_pop(L, nargs);
        return;
    }

    signal_object_emit(L, &lua_class->signals, name, nargs);
}

/** Try to use the metatable of an object.
 * \param L The Lua VM state.
 * \param idxobj The index of the object.
 * \param idxfield The index of the field (attribute) to get.
 * \return The number of element pushed on stack.
 */
int
luaA_usemetatable(lua_State *L, int idxobj, int idxfield)
{
    lua_class_t *class = luaA_class_get(L, idxobj);

    for(; class; class = class->parent)
    {
        /* Push the class */
        lua_pushlightuserdata(L, class);
        /* Get its metatable from registry */
        lua_rawget(L, LUA_REGISTRYINDEX);
        /* Push the field */
        lua_pushvalue(L, idxfield);
        /* Get the field in the metatable */
        lua_rawget(L, -2);
        /* Do we have a field like that? */
        if(!lua_isnil(L, -1))
        {
            /* Yes, so remove the metatable and return it! */
            lua_remove(L, -2);
            return 1;
        }
        /* No, so remove the metatable and its value */
        lua_pop(L, 2);
    }

    return 0;
}

static lua_class_property_t *
lua_class_property_array_getbyname(lua_class_property_array_t *arr,
                                   const char *name)
{
    lua_class_property_t lookup_prop = { .name = name };
    return lua_class_property_array_lookup(arr, &lookup_prop);
}

/** Get a property of a object.
 * \param L The Lua VM state.
 * \param lua_class The Lua class.
 * \param fieldidx The index of the field name.
 * \return The object property if found, NULL otherwise.
 */
static lua_class_property_t *
luaA_class_property_get(lua_State *L, lua_class_t *lua_class, int fieldidx)
{
    /* Lookup the property using token */
    const char *attr = luaL_checkstring(L, fieldidx);

    /* Look for the property in the class; if not found, go in the parent class. */
    for(; lua_class; lua_class = lua_class->parent)
    {
        lua_class_property_t *prop =
            lua_class_property_array_getbyname(&lua_class->properties, attr);

        if(prop)
            return prop;
    }

    return NULL;
}

/** Generic index meta function for objects.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
int
luaA_class_index(lua_State *L)
{
    lua_class_t *class;
    const char *attr;
    lua_class_property_t *prop;
    void *p;

    /* Try to use metatable first. */
    if(luaA_usemetatable(L, 1, 2))
        return 1;

    class = luaA_class_get(L, 1);

    /* Is this the special 'valid' property? This is the only property
     * accessible for invalid objects and thus needs special handling. */
    attr = luaL_checkstring(L, 2);
    if (A_STREQ(attr, "valid"))
    {
        p = luaA_toudata(L, 1, class);
        if (class->checker)
            lua_pushboolean(L, p != NULL && class->checker(p));
        else
            lua_pushboolean(L, p != NULL);
        return 1;
    }

    prop = luaA_class_property_get(L, class, 2);

    /* This is the table storing the object private variables.
     */
    if (A_STREQ(attr, "_private"))
    {
        luaA_checkudata(L, 1, class);
        luaA_getuservalue(L, 1);
        lua_getfield(L, -1, "data");
        return 1;
    }
    else if (A_STREQ(attr, "data"))
    {
        luaA_deprecate(L, "Use `._private` instead of `.data`");
        luaA_checkudata(L, 1, class);
        luaA_getuservalue(L, 1);
        lua_getfield(L, -1, "data");
        return 1;
    }

    /* Property does exist and has an index callback */
    if(prop)
    {
        if(prop->index)
            return prop->index(L, luaA_checkudata(L, 1, class));
    }
    else
    {
        if(class->index_miss_handler != LUA_REFNIL)
            return luaA_call_handler(L, class->index_miss_handler);
        if(class->index_miss_property)
            return class->index_miss_property(L, luaA_checkudata(L, 1, class));
    }

    return 0;
}

/** Generic newindex meta function for objects.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
int
luaA_class_newindex(lua_State *L)
{
    lua_class_t *class;
    lua_class_property_t *prop;
    const char *key = luaL_checkstring(L, 2);

    fprintf(stderr, "[CLASS_NEWINDEX] Called with key='%s'\n", key);

    /* Try to use metatable first. */
    if(luaA_usemetatable(L, 1, 2))
    {
        fprintf(stderr, "[CLASS_NEWINDEX] Found '%s' in metatable, returning\n", key);
        return 1;
    }

    class = luaA_class_get(L, 1);
    fprintf(stderr, "[CLASS_NEWINDEX] class=%s\n", class ? class->name : "NULL");

    prop = luaA_class_property_get(L, class, 2);

    /* Property does exist and has a newindex callback */
    if(prop)
    {
        fprintf(stderr, "[CLASS_NEWINDEX] Property '%s' found, has newindex=%d\n",
                key, prop->newindex != NULL);
        if(prop->newindex)
            return prop->newindex(L, luaA_checkudata(L, 1, class));
    }
    else
    {
        fprintf(stderr, "[CLASS_NEWINDEX] Property '%s' NOT found in class\n", key);
        if(class->newindex_miss_handler != LUA_REFNIL)
            return luaA_call_handler(L, class->newindex_miss_handler);
        if(class->newindex_miss_property)
            return class->newindex_miss_property(L, luaA_checkudata(L, 1, class));
    }

    fprintf(stderr, "[CLASS_NEWINDEX] No handler for '%s', returning 0\n", key);
    return 0;
}

/** Generic constructor function for objects.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
int
luaA_class_new(lua_State *L, lua_class_t *lua_class)
{
    void *object;

    /* Check we have a table that should contains some properties */
    luaA_checktable(L, 2);

    /* Create a new object */
    object = lua_class->allocator(L);

    /* Push the first key before iterating */
    lua_pushnil(L);
    /* Iterate over the property keys */
    while(lua_next(L, 2))
    {
        /* Check that the key is a string.
         * We cannot call tostring blindly or Lua will convert a key that is a
         * number TO A STRING, confusing lua_next() */
        if(lua_isstring(L, -2))
        {
            lua_class_property_t *prop = luaA_class_property_get(L, lua_class, -2);

            if(prop && prop->new)
                prop->new(L, object);
        }
        /* Remove value */
        lua_pop(L, 1);
    }

    return 1;
}

#undef CONNECTED_SUFFIX

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
