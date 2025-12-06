/*
 * keygrabber.c - Keygrabber object implementation
 *
 * Copyright © 2024 somewm contributors
 * Based on AwesomeWM keygrabber patterns
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stddef.h>
#include <stdbool.h>
#include "somewm_types.h"
#include "objects/keygrabber.h"

/* Global keygrabber state */
static int keygrabber_callback = LUA_NOREF;  /* Reference to Lua callback function */
static bool keygrabber_running = false;      /* Is keygrabber currently active? */
static lua_State *globalL = NULL;            /* Global Lua state for callback execution */

/** Check if keygrabber is currently running
 * \return true if keygrabber is active, false otherwise
 */
bool
some_keygrabber_is_running(void)
{
    return keygrabber_running;
}

/** Handle a key event when keygrabber is running
 * \param modifiers The modifier mask (Shift, Control, Alt, etc.)
 * \param keysym The keysym value
 * \param keyname The string name of the key (e.g., "Escape", "a")
 * \return true if the event was handled, false otherwise
 */
bool
some_keygrabber_handle_key(uint32_t modifiers, uint32_t keysym, const char *keyname)
{
    lua_State *L;

    if (!keygrabber_running || keygrabber_callback == LUA_NOREF || !globalL)
        return false;

    L = globalL;

    /* Get the callback function from registry */
    lua_rawgeti(L, LUA_REGISTRYINDEX, keygrabber_callback);

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    /* Create modifiers table */
    lua_newtable(L);

    /* AwesomeWM modifier names */
    if (modifiers & WLR_MODIFIER_SHIFT) {
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "Shift");
    }
    if (modifiers & WLR_MODIFIER_CTRL) {
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "Control");
    }
    if (modifiers & WLR_MODIFIER_ALT) {
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "Mod1");
    }
    if (modifiers & WLR_MODIFIER_LOGO) {
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "Mod4");
    }

    /* Push key name */
    lua_pushstring(L, keyname);

    /* Push event type (always "press" for now) */
    lua_pushstring(L, "press");

    /* Call the callback: callback(modifiers, key, event) */
    if (lua_pcall(L, 3, 0, 0) != 0) {
        const char *error = lua_tostring(L, -1);
        fprintf(stderr, "Error in keygrabber callback: %s\n", error);
        lua_pop(L, 1);
        return false;
    }

    return true;
}

/** Start the keygrabber with a callback function
 * Lua API: keygrabber.run(callback)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack (0)
 */
static int
luaA_keygrabber_run(lua_State *L)
{
    /* Check that first argument is a function */
    luaL_checktype(L, 1, LUA_TFUNCTION);

    /* If we already have a callback, unreference it */
    if (keygrabber_callback != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, keygrabber_callback);
    }

    /* Store the callback function in the registry */
    lua_pushvalue(L, 1);  /* Push the function */
    keygrabber_callback = luaL_ref(L, LUA_REGISTRYINDEX);

    /* Mark keygrabber as running */
    keygrabber_running = true;

    return 0;
}

/** Stop the keygrabber
 * Lua API: keygrabber.stop()
 * \param L The Lua VM state
 * \return Number of elements pushed on stack (0)
 */
static int
luaA_keygrabber_stop(lua_State *L)
{
    (void)L;  /* Unused parameter */

    /* Unreference the callback if we have one */
    if (keygrabber_callback != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, keygrabber_callback);
        keygrabber_callback = LUA_NOREF;
    }

    /* Mark keygrabber as stopped */
    keygrabber_running = false;

    return 0;
}

/** Check if keygrabber is currently running
 * Lua API: keygrabber.isrunning()
 * \param L The Lua VM state
 * \return Number of elements pushed on stack (1 - boolean)
 */
static int
luaA_keygrabber_isrunning(lua_State *L)
{
    lua_pushboolean(L, keygrabber_running);
    return 1;
}

/** Initialize the keygrabber Lua module
 * \param L The Lua VM state
 */
void
luaA_keygrabber_setup(lua_State *L)
{
    static const struct luaL_Reg keygrabber_methods[] = {
        { "run", luaA_keygrabber_run },
        { "stop", luaA_keygrabber_stop },
        { "isrunning", luaA_keygrabber_isrunning },
        { NULL, NULL }
    };

    /* Store global Lua state for callback execution */
    globalL = L;

    /* Create the keygrabber module table */
    luaL_register(L, NULL, keygrabber_methods);
}
