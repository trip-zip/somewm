/*
 * luaobject.c - useful functions for handling Lua objects
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
 * Adapted for somewm:
 * - Removed backtrace dependencies
 * - Added missing luaa.h helper functions
 * - Integrated with somewm's signal system
 */

/** Handling of signals.
 *
 * This can not be used as a standalone class, but is instead referenced
 * explicitely in the classes, where it can be used. In the respective classes,
 * it then can be used via `classname:connect_signal(...)` etc.
 * @classmod signals
 */

#include "common/luaobject.h"
#include "common/lualib.h"
#include "objects/signal.h"
#include "util.h"
#include <stdio.h>
#include <string.h>

/* Undefine simple macros from luaa.h so we can use proper class-based functions */
#ifdef luaA_checkudata
#undef luaA_checkudata
#endif
#ifdef luaA_toudata
#undef luaA_toudata
#endif

/* Helper functions missing from somewm's luaa.h */

/** Call a Lua function with error handling (AwesomeWM pattern)
 * \param L Lua state
 * \param nargs Number of arguments
 * \param nresults Number of results
 * \return 0 on success, non-zero on error
 *
 * Expects stack: [args...] [function at TOP]
 * Rearranges to: [function] [args...] then calls
 */
int
luaA_dofunction(lua_State *L, int nargs, int nresults)
{
    int ret;

    /* Move function before arguments (AwesomeWM pattern) */
    lua_insert(L, - nargs - 1);

    /* Now function is at -(nargs+1), args above it */
    ret = lua_pcall(L, nargs, nresults, 0);
    if (ret != 0) {
        fprintf(stderr, "somewm: error in Lua function: %s\n",
                lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    return ret;
}

/* Signal helper functions for per-object signals */

/** Find a signal by name in an array
 * \param arr Signal array to search
 * \param name Signal name to find
 * \return Pointer to signal, or NULL if not found
 */
signal_t *
signal_array_getbyname(signal_array_t *arr, const char *name)
{
    size_t i;
    signal_t *result = NULL;

    /* Debug: print all signals in array when looking for one */
    if (arr->count > 0) {
        fprintf(stderr, "[SIGNAL_GETBYNAME] Searching for '%s' in array with %zu signals:\n",
                name, arr->count);
        for (i = 0; i < arr->count; i++) {
            fprintf(stderr, "[SIGNAL_GETBYNAME]   [%zu]: name='%s' refs=%zu\n",
                    i, arr->signals[i].name ? arr->signals[i].name : "NULL",
                    arr->signals[i].ref_count);
        }
    }

    for (i = 0; i < arr->count; i++) {
        if (strcmp(arr->signals[i].name, name) == 0) {
            result = &arr->signals[i];
            break;
        }
    }
    fprintf(stderr, "[SIGNAL_GETBYNAME] arr=%p signal='%s' found=%s (count=%zu)\n",
            (void*)arr, name, result ? "YES" : "NO", arr->count);
    return result;
}

/** Create a new signal in an array
 * \param arr Signal array
 * \param name Signal name
 * \return Pointer to newly created signal, or NULL on error
 */
static signal_t *
signal_create_in_array(signal_array_t *arr, const char *name)
{
    signal_t *sig;

    fprintf(stderr, "[SIGNAL_CREATE] arr=%p name='%s' count_before=%zu cap=%zu\n",
            (void*)arr, name, arr->count, arr->capacity);

    /* SAFETY: Detect uninitialized signal arrays (garbage pointer + zero capacity)
     * This can happen when objects are created before proper initialization.
     * AwesomeWM compatibility fix: reset to NULL so realloc() acts like malloc() */
    if (arr->capacity == 0 && arr->signals != NULL) {
        arr->signals = NULL;
        arr->count = 0;
    }

    /* Grow array if needed */
    if (arr->count >= arr->capacity) {
        size_t new_cap = arr->capacity == 0 ? 4 : arr->capacity * 2;
        signal_t *new_signals = realloc(arr->signals, new_cap * sizeof(signal_t));
        if (!new_signals) {
            fprintf(stderr, "somewm: failed to allocate signal array\n");
            return NULL;
        }
        fprintf(stderr, "[SIGNAL_CREATE] Grew array from cap=%zu to cap=%zu\n",
                arr->capacity, new_cap);
        arr->signals = new_signals;
        arr->capacity = new_cap;
    }

    /* Initialize new signal */
    sig = &arr->signals[arr->count++];
    sig->name = strdup(name);
    sig->refs = NULL;
    sig->ref_count = 0;
    sig->ref_capacity = 0;

    fprintf(stderr, "[SIGNAL_CREATE] Created signal '%s' at index %zu, count_after=%zu sig=%p\n",
            name, arr->count - 1, arr->count, (void*)sig);

    return sig;
}

/** Connect a signal handler to an object's signal array
 * \param arr Signal array
 * \param name Signal name
 * \param ref Lua registry reference (lightuserdata pointer)
 */
void
signal_connect_awm(signal_array_t *arr, const char *name, const void *ref)
{
    signal_t *sig;

    fprintf(stderr, "[SIGNAL_CONNECT] START arr=%p signal='%s' handler_ref=%p\n",
            (void*)arr, name, ref);

    sig = signal_array_getbyname(arr, name);
    if (!sig) {
        fprintf(stderr, "[SIGNAL_CONNECT] Signal '%s' not found, creating new signal\n", name);
        sig = signal_create_in_array(arr, name);
    } else {
        fprintf(stderr, "[SIGNAL_CONNECT] Signal '%s' already exists at sig=%p with %zu handlers\n",
                name, (void*)sig, sig->ref_count);
    }

    if (!sig) {
        fprintf(stderr, "[SIGNAL_CONNECT] ERROR: Failed to create signal '%s'\n", name);
        return;
    }

    /* SAFETY: Detect uninitialized refs array (garbage pointer + zero capacity) */
    if (sig->ref_capacity == 0 && sig->refs != NULL) {
        sig->refs = NULL;
        sig->ref_count = 0;
    }

    /* Grow refs array if needed */
    if (sig->ref_count >= sig->ref_capacity) {
        size_t new_cap = sig->ref_capacity == 0 ? 2 : sig->ref_capacity * 2;
        intptr_t *new_refs = realloc(sig->refs, new_cap * sizeof(intptr_t));
        if (!new_refs) {
            fprintf(stderr, "somewm: failed to allocate signal refs\n");
            return;
        }
        sig->refs = new_refs;
        sig->ref_capacity = new_cap;
    }

    /* Store the pointer as intptr_t to avoid truncation */
    sig->refs[sig->ref_count++] = (intptr_t)ref;

    fprintf(stderr, "[SIGNAL_CONNECT] DONE arr=%p signal='%s' handler_ref=%p sig=%p (count now=%zu)\n",
            (void*)arr, name, ref, (void*)sig, sig->ref_count);
}

/** Disconnect a signal handler from an object's signal array
 * \param arr Signal array
 * \param name Signal name
 * \param ref Lua registry reference (lightuserdata pointer)
 * \return 1 if found and removed, 0 if not found
 */
int
signal_disconnect_awm(signal_array_t *arr, const char *name, const void *ref)
{
    signal_t *sig;
    size_t i;
    intptr_t ref_intptr;

    sig = signal_array_getbyname(arr, name);
    if (!sig)
        return 0;

    /* Store ref as intptr_t to match how it was stored during connect */
    ref_intptr = (intptr_t)ref;

    for (i = 0; i < sig->ref_count; i++) {
        if (sig->refs[i] == ref_intptr) {
            /* Remove from array by shifting */
            for (; i < sig->ref_count - 1; i++) {
                sig->refs[i] = sig->refs[i + 1];
            }
            sig->ref_count--;
            return 1;
        }
    }

    return 0;
}

/* AwesomeWM object system implementation */

/** Setup the object system at startup.
 * \param L The Lua VM state.
 */
void
luaA_object_setup(lua_State *L)
{
    /* Push identification string */
    lua_pushliteral(L, LUAA_OBJECT_REGISTRY_KEY);
    /* Create an empty table */
    lua_newtable(L);
    /* Create an empty metatable */
    lua_newtable(L);
    /* Set this empty table as the registry metatable.
     * It's used to store the number of reference on stored objects. */
    lua_setmetatable(L, -2);
    /* Register table inside registry */
    lua_rawset(L, LUA_REGISTRYINDEX);
}

/** Increment a object reference in its store table.
 * \param L The Lua VM state.
 * \param tud The table index on the stack.
 * \param oud The object index on the stack.
 * \return A pointer to the object.
 */
void *
luaA_object_incref(lua_State *L, int tud, int oud)
{
    void *pointer;
    int count;

    /* Get pointer value of the item */
    pointer = (void *) lua_topointer(L, oud);

    /* Not reference able. */
    if(!pointer)
    {
        lua_remove(L, oud);
        return NULL;
    }

    /* Push the pointer (key) */
    lua_pushlightuserdata(L, pointer);
    /* Push the data (value) */
    lua_pushvalue(L, oud < 0 ? oud - 1 : oud);
    /* table.lightudata = data */
    lua_rawset(L, tud < 0 ? tud - 2 : tud);

    /* refcount++ */

    /* Get the metatable */
    lua_getmetatable(L, tud);
    /* Push the pointer (key) */
    lua_pushlightuserdata(L, pointer);
    /* Get the number of references */
    lua_rawget(L, -2);
    /* Get the number of references and increment it */
    count = lua_tointeger(L, -1) + 1;
    lua_pop(L, 1);
    /* Push the pointer (key) */
    lua_pushlightuserdata(L, pointer);
    /* Push count (value) */
    lua_pushinteger(L, count);
    /* Set metatable[pointer] = count */
    lua_rawset(L, -3);
    /* Pop metatable */
    lua_pop(L, 1);

    /* Remove referenced item */
    lua_remove(L, oud);

    return pointer;
}

/** Decrement a object reference in its store table.
 * \param L The Lua VM state.
 * \param tud The table index on the stack.
 * \param oud The object index on the stack.
 * \return A pointer to the object.
 */
void
luaA_object_decref(lua_State *L, int tud, const void *pointer)
{
    int count;

    if(!pointer)
        return;

    /* First, refcount-- */
    /* Get the metatable */
    lua_getmetatable(L, tud);
    /* Push the pointer (key) */
    lua_pushlightuserdata(L, (void *) pointer);
    /* Get the number of references */
    lua_rawget(L, -2);
    /* Get the number of references and decrement it */
    count = lua_tointeger(L, -1) - 1;
    /* Did we find the item in our table? (tointeger(nil)-1) is -1 */
    if (count < 0)
    {
        fprintf(stderr, "somewm: BUG: Reference not found: %d %p\n", tud, pointer);

        /* Pop reference count and metatable */
        lua_pop(L, 2);
        return;
    }
    lua_pop(L, 1);
    /* Push the pointer (key) */
    lua_pushlightuserdata(L, (void *) pointer);
    /* Hasn't the ref reached 0? */
    if(count)
        lua_pushinteger(L, count);
    else
        /* Yup, delete it, set nil as value */
        lua_pushnil(L);
    /* Set meta[pointer] = count/nil */
    lua_rawset(L, -3);
    /* Pop metatable */
    lua_pop(L, 1);

    /* Wait, no more ref? */
    if(!count)
    {
        /* Yes? So remove it from table */
        lua_pushlightuserdata(L, (void *) pointer);
        /* Push nil as value */
        lua_pushnil(L);
        /* table[pointer] = nil */
        lua_rawset(L, tud < 0 ? tud - 2 : tud);
    }
}

/** Store an item in the environment table of an object.
 * \param L The Lua VM state.
 * \param ud The index of the object on the stack.
 * \param iud The index of the item on the stack.
 * \return The item reference.
 */
void *
luaA_object_ref_item(lua_State *L, int ud, int iud)
{
    void *pointer;

    /* Get the env table from the object */
    luaA_getuservalue(L, ud);

    pointer = luaA_object_incref(L, -1, iud < 0 ? iud - 1 : iud);

    /* Remove env table */
    lua_pop(L, 1);
    return pointer;
}

/** Push an object item on the stack.
 * \param L The Lua VM state.
 * \param ud The object index on the stack.
 * \param pointer The item pointer.
 * \return The number of element pushed on stack.
 */
int
luaA_object_push_item(lua_State *L, int ud, const void *pointer)
{

    /* Get env table of the object */
    luaA_getuservalue(L, ud);

    /* Push key */
    lua_pushlightuserdata(L, (void *) pointer);
    /* Get env.pointer */
    lua_rawget(L, -2);

    /* Remove env table */
    lua_remove(L, -2);
    return 1;
}

int
luaA_settype(lua_State *L, lua_class_t *lua_class)
{
    lua_pushlightuserdata(L, lua_class);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_setmetatable(L, -2);
    return 1;
}

/** Add a signal.
 * @tparam string name A signal name.
 * @tparam func func A function to call when the signal is emitted.
 * @function connect_signal
 */
void
luaA_object_connect_signal(lua_State *L, int oud,
                           const char *name, lua_CFunction fn)
{
    lua_pushcfunction(L, fn);
    luaA_object_connect_signal_from_stack(L, oud, name, -1);
}

/** Remove a signal.
 * @tparam string name A signal name.
 * @tparam func func A function to remove.
 * @function disconnect_signal
 */
void
luaA_object_disconnect_signal(lua_State *L, int oud,
                              const char *name, lua_CFunction fn)
{
    lua_pushcfunction(L, fn);
    luaA_object_disconnect_signal_from_stack(L, oud, name, -1);
}

/** Add a signal to an object.
 * \param L The Lua VM state.
 * \param oud The object index on the stack.
 * \param name The name of the signal.
 * \param ud The index of function to call when signal is emitted.
 */
void
luaA_object_connect_signal_from_stack(lua_State *L, int oud,
                                      const char *name, int ud)
{
    lua_object_t *obj;
    void *func_ref;
    lua_class_t *lua_class;

    luaA_checkfunction(L, ud);
    obj = lua_touserdata(L, oud);
    func_ref = luaA_object_ref_item(L, oud, ud);

    lua_class = luaA_class_get(L, oud);

    /* Debug: log button signal connections */
    if (lua_class && strcmp(lua_class->name, "button") == 0) {
        fprintf(stderr, "[BUTTON_SIGNAL_CONNECT] obj=%p signal='%s' func_ref=%p\n",
                (void *)obj, name, func_ref);
    }

    signal_connect_awm(&obj->signals, name, func_ref);

    /* Debug: verify signal was stored */
    if (lua_class && strcmp(lua_class->name, "button") == 0) {
        signal_t *sig = signal_array_getbyname(&obj->signals, name);
        fprintf(stderr, "[BUTTON_SIGNAL_CONNECT] After connect: signal='%s' has %d refs\n",
                name, sig ? (int)sig->ref_count : -1);
    }
}

/** Remove a signal to an object.
 * \param L The Lua VM state.
 * \param oud The object index on the stack.
 * \param name The name of the signal.
 * \param ud The index of function to call when signal is emitted.
 */
void
luaA_object_disconnect_signal_from_stack(lua_State *L, int oud,
                                         const char *name, int ud)
{
    lua_object_t *obj;
    void *ref;

    luaA_checkfunction(L, ud);
    obj = lua_touserdata(L, oud);
    ref = (void *) lua_topointer(L, ud);
    if (signal_disconnect_awm(&obj->signals, name, ref))
        luaA_object_unref_item(L, oud, ref);
    lua_remove(L, ud);
}

void
signal_object_emit(lua_State *L, signal_array_t *arr, const char *name, int nargs)
{
    signal_t *sigfound;
    int nbfunc, i, j;

    sigfound = signal_array_getbyname(arr, name);

    if(sigfound)
    {
        nbfunc = sigfound->ref_count;
        luaL_checkstack(L, nbfunc + nargs + 1, "too much signal");
        /* Push all functions and then execute, because this list can change
         * while executing funcs. */
        for(i = 0; i < nbfunc; i++)
        {
            /* Convert stored int back to pointer */
            void *func = (void *)(intptr_t)sigfound->refs[i];
            luaA_object_push(L, func);
        }

        for(i = 0; i < nbfunc; i++)
        {
            /* push all args */
            for(j = 0; j < nargs; j++)
            {
                int idx = - nargs - nbfunc + i;
                lua_pushvalue(L, idx);
            }
            /* push first function */
            lua_pushvalue(L, - nargs - nbfunc + i);
            if (nargs >= 1) {
            }
            /* remove this first function */
            lua_remove(L, - nargs - nbfunc - 1 + i);
            /* REMOVED lua_insert - luaA_dofunction now does this internally (AwesomeWM pattern)
             * OLD: lua_insert(L, -(nargs + 1));  <- Would cause DOUBLE INSERT bug
             * NEW: luaA_dofunction handles moving function before args */
            luaA_dofunction(L, nargs, 0);
        }
    }

    /* remove args */
    lua_pop(L, nargs);
}

/** Emit a signal.
 * @tparam string name A signal name.
 * @param[opt] ... Various arguments.
 * @function emit_signal
 */
void
luaA_awm_object_emit_signal(lua_State *L, int oud,
                            const char *name, int nargs)
{
    int oud_abs;
    lua_class_t *lua_class;
    lua_object_t *obj;
    signal_t *sigfound;

    oud_abs = luaA_absindex(L, oud);
    lua_class = luaA_class_get(L, oud);
    obj = luaA_toudata(L, oud, lua_class);

    if(!obj) {
        luaA_warn(L, "Trying to emit signal '%s' on non-object", name);
        return;
    }
    else if(lua_class->checker && !lua_class->checker(obj)) {
        luaA_warn(L, "Trying to emit signal '%s' on invalid object", name);
        return;
    }

    fprintf(stderr, "[SIGNAL_EMIT] obj=%p arr=%p signal='%s' nargs=%d class=%s\n",
            (void*)obj, (void*)&obj->signals, name, nargs, lua_class ? lua_class->name : "NULL");

    sigfound = signal_array_getbyname(&obj->signals, name);

    if(sigfound)
    {
        int nbfunc = sigfound->ref_count;
        int func_idx;
        int i, j;
        void *func;

        fprintf(stderr, "[SIGNAL_HANDLER_CALL] Found signal '%s' with %d handlers, calling them now...\n",
                name, nbfunc);

        luaL_checkstack(L, nbfunc + nargs + 2, "too much signal");

        /* Push all functions and then execute, because this list can change
         * while executing funcs. */
        for(i = 0; i < nbfunc; i++)
        {
            func = (void *)(intptr_t)sigfound->refs[i];
            fprintf(stderr, "[SIGNAL_HANDLER_CALL] Pushing handler %d: func=%p\n", i, func);
            luaA_object_push_item(L, oud_abs, func);
        }

        for(i = 0; i < nbfunc; i++)
        {
            int pos, remove_idx;

            fprintf(stderr, "[SIGNAL_HANDLER_CALL] Calling handler %d for signal '%s'\n", i, name);
            fprintf(stderr, "[SIGNAL_HANDLER_CALL]   Stack before pushing: top=%d\n", lua_gettop(L));

            /* push object (AwesomeWM pattern: object first) */
            lua_pushvalue(L, oud_abs);
            fprintf(stderr, "[SIGNAL_HANDLER_CALL]   Pushed object from oud_abs=%d, top=%d, type=%s\n",
                    oud_abs, lua_gettop(L), lua_typename(L, lua_type(L, -1)));

            /* push all args (AwesomeWM pattern) */
            pos = - nargs - nbfunc - 1 + i;
            for(j = 0; j < nargs; j++) {
                fprintf(stderr, "[SIGNAL_HANDLER_CALL]   Pushing arg %d from pos=%d (i=%d, nargs=%d, nbfunc=%d)\n",
                        j, pos, i, nargs, nbfunc);
                lua_pushvalue(L, pos);
                fprintf(stderr, "[SIGNAL_HANDLER_CALL]     After push: top=%d, type=%s\n",
                        lua_gettop(L), lua_typename(L, lua_type(L, -1)));
            }

            /* push first function (AwesomeWM pattern) */
            func_idx = - nargs - nbfunc - 1 + i;
            lua_pushvalue(L, func_idx);
            fprintf(stderr, "[SIGNAL_HANDLER_CALL]   Pushed function from idx=%d, top=%d\n", func_idx, lua_gettop(L));

            /* remove this first function from original position (AwesomeWM pattern) */
            remove_idx = - nargs - nbfunc - 2 + i;
            fprintf(stderr, "[SIGNAL_HANDLER_CALL]   Removing original function from idx=%d\n", remove_idx);
            lua_remove(L, remove_idx);
            fprintf(stderr, "[SIGNAL_HANDLER_CALL]   After remove: top=%d\n", lua_gettop(L));

            /* luaA_dofunction will insert function before args (AwesomeWM pattern) */
            fprintf(stderr, "[SIGNAL_HANDLER_CALL]   Calling luaA_dofunction with nargs+1=%d\n", nargs + 1);
            luaA_dofunction(L, nargs + 1, 0);
            fprintf(stderr, "[SIGNAL_HANDLER_CALL] Handler %d completed\n", i);
        }
        /* NOTE: No lua_pop needed - lua_remove() inside loop already removed all functions */
        fprintf(stderr, "[SIGNAL_HANDLER_CALL] All handlers for '%s' completed\n", name);
    }

    /* Then emit signal on the class */
    lua_pushvalue(L, oud);
    lua_insert(L, - nargs - 1);
    luaA_class_emit_signal(L, luaA_class_get(L, - nargs - 1), name, nargs + 1);
}

int
luaA_object_connect_signal_simple(lua_State *L)
{
    luaA_object_connect_signal_from_stack(L, 1, luaL_checkstring(L, 2), 3);
    return 0;
}

int
luaA_object_disconnect_signal_simple(lua_State *L)
{
    luaA_object_disconnect_signal_from_stack(L, 1, luaL_checkstring(L, 2), 3);
    return 0;
}

int
luaA_awm_object_emit_signal_simple(lua_State *L)
{
    luaA_awm_object_emit_signal(L, 1, luaL_checkstring(L, 2), lua_gettop(L) - 2);
    return 0;
}

int
luaA_object_tostring(lua_State *L)
{
    lua_class_t *lua_class;
    lua_object_t *object;
    int offset;

    lua_class = luaA_class_get(L, 1);
    object = luaA_toudata(L, 1, lua_class);

    /* Handle invalid objects gracefully - return "invalid <classname>" */
    if (!object || (lua_class->checker && !lua_class->checker(object))) {
        lua_pushfstring(L, "invalid %s: %p", lua_class->name, object);
        return 1;
    }

    offset = 0;

    for(; lua_class; lua_class = lua_class->parent)
    {
        if(offset)
        {
            lua_pushliteral(L, "/");
            lua_insert(L, -++offset);
        }
        lua_pushstring(L, NONULL(lua_class->name));
        lua_insert(L, -++offset);

        if (lua_class->tostring) {
            int k, n;

            lua_pushliteral(L, "(");
            n = 2 + lua_class->tostring(L, object);
            lua_pushliteral(L, ")");

            for (k = 0; k < n; k++)
                lua_insert(L, -offset);
            offset += n;
        }
    }

    lua_pushfstring(L, ": %p", object);

    lua_concat(L, offset + 1);

    return 1;
}

/** Generic signal emission for any lua object type (client, tag, screen, etc.)
 * This replaces the type-specific implementations and works with the class system.
 * \param L The Lua VM state
 * \param oud Object index on stack (can be negative)
 * \param name Signal name to emit
 * \param nargs Number of arguments to pass to signal handlers
 */
void
luaA_object_emit_signal(lua_State *L, int oud, const char *name, int nargs)
{
    int oud_abs;
    lua_class_t *lua_class;
    lua_object_t *obj;

    oud_abs = luaA_absindex(L, oud);
    lua_class = luaA_class_get(L, oud);
    obj = luaA_toudata(L, oud, lua_class);


    if(!obj) {
        return;
    }
    else if(lua_class->checker && !lua_class->checker(obj)) {
        return;
    }

    /* Use luaA_awm_object_emit_signal which properly handles the signal emission
     * including calling handlers registered on the object. We need to use the
     * AwesomeWM emission system, not the simplified signal_object_emit(). */
    luaA_awm_object_emit_signal(L, oud_abs, name, nargs);

}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
