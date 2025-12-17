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

/** Connect a callback to a global signal (used by awesome.connect_signal)
 * \param name Signal name
 * \param ref Lua reference to callback function
 */
void
luaA_signal_connect(const char *name, const void *ref)
{
    signal_connect(&global_signals, name, ref);
}

/** Disconnect a callback from a global signal (used by awesome.disconnect_signal)
 * \param name Signal name
 * \param ref Pointer to callback function
 * \return true if the signal was disconnected
 */
bool
luaA_signal_disconnect(const char *name, const void *ref)
{
    return signal_disconnect(&global_signals, name, ref);
}

/** Emit a global signal (used by awesome.emit_signal)
 * \param L Lua state
 * \param name Signal name
 * \param nargs Number of arguments on stack
 */
void
luaA_signal_emit(lua_State *L, const char *name, int nargs)
{
    signal_object_emit(L, &global_signals, name, nargs);
}

/** Setup the signal system
 * Initializes the global signal array for C code.
 * NOTE: We do NOT register a global 'signal' table in Lua because:
 * 1. AwesomeWM doesn't have this - it uses awesome.connect_signal() instead
 * 2. A global 'signal' table conflicts with user configs that have a signal/ directory
 *    (e.g., require('signal') would return the global instead of loading the module)
 */
void
luaA_signal_setup(lua_State *L)
{
    (void)L;  /* Unused - we no longer register a Lua module */

    /* Initialize global signal array */
    signal_array_init(&global_signals);

    /* NOTE: Removed luaA_openlib(L, "signal", ...) to avoid conflicts with
     * user configs. Global signals should be accessed via awesome.connect_signal(). */
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
