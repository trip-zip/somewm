/*
 * objects/signal.c - somewm global signal emission helpers
 *
 * This file provides global signal functionality using AwesomeWM's signal system.
 * The core signal_t and signal_array_t types are defined in common/signal.h.
 */

#include "signal.h"
#include "luaa.h"
#include "common/luaobject.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/** Global signal registry for class-level signals */
static signal_array_t global_signals;

/** signal.connect(name, callback) - Connect a callback to a global signal
 * \param name Signal name (string)
 * \param callback Lua function to call when signal is emitted
 */
static int
luaA_signal_connect(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    const void *ref;
    luaL_checktype(L, 2, LUA_TFUNCTION);

    /* Store function in registry and get reference */
    lua_pushvalue(L, 2);  /* Duplicate function on stack */
    ref = luaA_object_ref(L, -1);

    /* Add reference to signal */
    signal_connect(&global_signals, name, ref);

    return 0;
}

/** signal.disconnect(name, callback) - Disconnect a callback from a global signal
 * \param name Signal name (string)
 * \param callback Lua function to disconnect (must be same function object)
 */
static int
luaA_signal_disconnect(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    const void *ref;
    luaL_checktype(L, 2, LUA_TFUNCTION);

    ref = lua_topointer(L, 2);
    if (signal_disconnect(&global_signals, name, ref))
        luaA_object_unref(L, ref);

    return 0;
}

/** signal.emit(name, ...) - Emit a global signal, calling all connected callbacks
 * \param name Signal name (string)
 * \param ... Additional arguments to pass to callbacks
 */
static int
luaA_signal_emit(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    int nargs = lua_gettop(L) - 1;  /* Number of extra arguments */

    signal_object_emit(L, &global_signals, name, nargs);

    return 0;
}

/** signal.list() - List all registered signals (for debugging)
 * \return Table of signal names
 */
static int
luaA_signal_list(lua_State *L)
{
    lua_newtable(L);
    for (int i = 0; i < global_signals.len; i++) {
        lua_pushinteger(L, global_signals.tab[i].id);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

/* Signal module methods */
static const luaL_Reg signal_methods[] = {
    { "connect", luaA_signal_connect },
    { "disconnect", luaA_signal_disconnect },
    { "emit", luaA_signal_emit },
    { "list", luaA_signal_list },
    { NULL, NULL }
};

/** Setup the signal Lua module
 * Registers the global 'signal' table with signal functions
 */
void
luaA_signal_setup(lua_State *L)
{
    /* Initialize global signal array */
    signal_array_init(&global_signals);

    /* Register signal module */
    luaA_openlib(L, "signal", signal_methods, NULL);
}

/** Cleanup signal system (called on shutdown) */
void
luaA_signal_cleanup(void)
{
    signal_array_wipe(&global_signals);
}

/** Emit a global signal from C code
 * This is a convenience function for C code to emit signals without
 * needing to manage the Lua stack directly.
 * \param name Signal name to emit
 */
void
luaA_emit_signal_global(const char *name)
{
    if (!globalconf_L)
        return;  /* Lua not initialized */

    signal_object_emit(globalconf_L, &global_signals, name, 0);
}

/** Emit a global signal with a client object from C code
 * This emits a signal and passes a client userdata to callbacks.
 * \param name Signal name to emit
 * \param c Client object to pass as argument
 */
void
luaA_emit_signal_global_with_client(const char *name, Client *c)
{
    if (!globalconf_L || !c)
        return;

    /* Push client onto stack */
    luaA_object_push(globalconf_L, c);

    /* Emit signal with client as argument */
    signal_object_emit(globalconf_L, &global_signals, name, 1);
}

/* Forward declaration for screen push function */
extern void luaA_screen_push(lua_State *L, struct screen_t *screen);

/** Emit a global signal with a screen object from C code
 * \param name Signal name to emit
 * \param screen Screen object to pass as argument
 */
void
luaA_emit_signal_global_with_screen(const char *name, struct screen_t *screen)
{
    if (!globalconf_L || !screen)
        return;

    /* Push screen object as userdata argument */
    luaA_screen_push(globalconf_L, screen);

    /* Emit signal with screen as argument */
    signal_object_emit(globalconf_L, &global_signals, name, 1);
}

/** Emit a global signal with a table argument
 * This creates a table with the provided key-value pairs and passes it to signal handlers.
 * Used for spawn::* signals that need to pass event data.
 * \param name Signal name to emit
 * \param nargs Number of key-value pairs (must be even: key1, val1, key2, val2, ...)
 * \param ... Alternating const char* keys and values
 */
void
luaA_emit_signal_global_with_table(const char *name, int nargs, ...)
{
    va_list ap;
    int j;

    if (!globalconf_L)
        return;

    /* Build table */
    lua_createtable(globalconf_L, 0, nargs / 2);

    /* Add key-value pairs to table */
    va_start(ap, nargs);
    for (j = 0; j < nargs; j += 2) {
        const char *key = va_arg(ap, const char *);
        const char *value = va_arg(ap, const char *);
        if (value) {
            lua_pushstring(globalconf_L, value);
            lua_setfield(globalconf_L, -2, key);
        }
    }
    va_end(ap);

    /* Emit signal with table as argument (table is already on stack) */
    signal_object_emit(globalconf_L, &global_signals, name, 1);
}

/** Emit a global signal with an argument already on the Lua stack
 * This is used by luaA_dofunction_on_error to emit debug::error with
 * the error message that's already on the stack.
 * \param L Lua state (with argument on top of stack)
 * \param name Signal name to emit
 * \param nargs Number of arguments already on stack
 */
void
luaA_emit_signal_global_with_stack(lua_State *L, const char *name, int nargs)
{
    signal_object_emit(L, &global_signals, name, nargs);
}
