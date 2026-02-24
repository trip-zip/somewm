/*
 * keygrabber.c - key grabbing
 *
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
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

/*
 * @author Julien Danjou &lt;julien@danjou.info&gt;
 * @copyright 2008-2009 Julien Danjou
 * @module keygrabber
 */

#include <unistd.h>
#include <xkbcommon/xkbcommon.h>

#include "objects/keygrabber.h"
#include "objects/key.h"
#include "globalconf.h"
#include "luaa.h"
#include "common/lualib.h"
#include "somewm_types.h"

/** Grab the keyboard.
 * \return True if keyboard was grabbed.
 *
 * Note: In Wayland, compositors inherently have keyboard access, so this
 * is a no-op that always succeeds. The X11 version uses xcb_grab_keyboard.
 */
static bool
keygrabber_grab(void)
{
    /* Wayland compositors don't need explicit keyboard grabbing like X11.
     * We just track state internally. Always return success. */
    return true;
}

/** Returns, whether the \0-terminated char in UTF8 is control char.
 * Control characters are either characters without UTF8 representation like XF86MonBrightnessUp
 * or backspace and the other characters in ASCII table before space
 *
 * \param buf input buffer
 * \return True if the input buffer is control character.
 */
static bool
is_control(const char *buf)
{
    unsigned char c = (unsigned char)buf[0];
    return c < 0x20 || c == 0x7f;
}

/** Handle keypress event.
 * \param L Lua stack to push the key pressed.
 * \param keycode The keycode of the pressed key.
 * \param state The xkb_state for key conversion.
 * \param is_press True for key press, false for key release.
 * \return True if a key was successfully retrieved, false otherwise.
 */
bool
keygrabber_handlekpress(lua_State *L, xkb_keycode_t keycode,
                        struct xkb_state *state, bool is_press)
{
    char buf[64];
    xkb_keysym_t keysym;

    /* Get the keysym */
    keysym = xkb_state_key_get_one_sym(state, keycode);

    /* Get UTF-8 representation */
    xkb_state_key_get_utf8(state, keycode, buf, sizeof(buf));

    if (is_control(buf)) {
        /* Use text names for control characters */
        xkb_keysym_get_name(keysym, buf, sizeof(buf));
    }

    /* Push modifiers table */
    luaA_pushmodifiers(L, xkb_state_serialize_mods(state, XKB_STATE_MODS_EFFECTIVE));

    /* Push key name */
    lua_pushstring(L, buf);

    /* Push event type */
    if (is_press)
        lua_pushliteral(L, "press");
    else
        lua_pushliteral(L, "release");

    return true;
}

/* Grab keyboard input and read pressed keys, calling a callback function at
 * each keypress, until `keygrabber.stop` is called.
 * The callback function receives three arguments:
 *
 * @param callback A callback function as described above.
 * @deprecated keygrabber.run
 */
static int
luaA_keygrabber_run(lua_State *L)
{
    if (globalconf.keygrabber != LUA_REFNIL)
        luaL_error(L, "keygrabber already running");

    luaA_registerfct(L, 1, &globalconf.keygrabber);

    if (!keygrabber_grab()) {
        luaA_unregister(L, &globalconf.keygrabber);
        luaL_error(L, "unable to grab keyboard");
    }

    return 0;
}

/** Stop grabbing the keyboard.
 * @deprecated keygrabber.stop
 */
int
luaA_keygrabber_stop(lua_State *L)
{
    /* Wayland: no xcb_ungrab_keyboard needed */
    luaA_unregister(L, &globalconf.keygrabber);
    return 0;
}

/** Check if keygrabber is running.
 * @deprecated keygrabber.isrunning
 * @treturn bool A boolean value, true if keygrabber is running, false otherwise.
 * @see keygrabber.is_running
 */
static int
luaA_keygrabber_isrunning(lua_State *L)
{
    lua_pushboolean(L, globalconf.keygrabber != LUA_REFNIL);
    return 1;
}

const struct luaL_Reg awesome_keygrabber_lib[] =
{
    { "run", luaA_keygrabber_run },
    { "stop", luaA_keygrabber_stop },
    { "isrunning", luaA_keygrabber_isrunning },
    { "__index", luaA_default_index },
    { "__newindex", luaA_default_newindex },
    { NULL, NULL }
};

/* somewm-specific: Check if keygrabber is currently running
 * Used by somewm.c event handling
 */
bool
some_keygrabber_is_running(void)
{
    return globalconf.keygrabber != LUA_REFNIL;
}

/* somewm-specific: Handle a key event when keygrabber is running
 * Used by somewm.c keyboard event handling
 */
bool
some_keygrabber_handle_key(uint32_t modifiers, uint32_t keysym, const char *keyname)
{
    lua_State *L;

    (void)keysym;  /* Unused */

    if (globalconf.keygrabber == LUA_REFNIL)
        return false;

    L = globalconf_get_lua_State();

    /* Get the callback function from registry */
    lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.keygrabber);

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    /* Push modifiers table using AwesomeWM helper */
    luaA_pushmodifiers(L, modifiers);

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

/** Initialize the keygrabber Lua module
 * \param L The Lua VM state
 */
void
luaA_keygrabber_setup(lua_State *L)
{
    /* Register the methods on the table at the top of the stack */
    luaA_setfuncs(L, awesome_keygrabber_lib);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
