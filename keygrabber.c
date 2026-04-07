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
#include "somewm_api.h"

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

/* Convert a key event to a human-readable string, preferring UTF-8 text when
 * available and falling back to keysym names for control/non-printable keys.
 */
static void
key_to_text(struct xkb_state* state, xkb_keycode_t keycode, char *buf,
            size_t buflen)
{
    xkb_keysym_t keysym;
    /* Get the keysym */
    keysym = xkb_state_key_get_one_sym(state, keycode);

    /* Prefer translated UTF-8 text and fall back to keysym names for
     * control/non-printable keys. */
    if (xkb_state_key_get_utf8(state, keycode, buf, buflen) <= 0 ||
        is_control(buf)) {
        /* Use text names for control characters */
        xkb_keysym_get_name(keysym, buf, buflen);
    }
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
    char buf[64] = {0};

    /* Convert key event to human-readable string. */
    key_to_text(state, keycode, buf, sizeof(buf));

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

/* somewm-specific: Handle a key event when keygrabber is running.
 * Delegates to keygrabber_handlekpress() for argument pushing, then
 * invokes the Lua callback via pcall.
 */
bool
some_keygrabber_handle_key(xkb_keycode_t keycode, struct xkb_state *state, bool is_press)
{
    if (!state || globalconf.keygrabber == LUA_REFNIL)
        return false;

    lua_State *L = globalconf_get_lua_State();

    /* Get the callback function from registry */
    lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.keygrabber);

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    /* Push modifiers, key name, event type */
    keygrabber_handlekpress(L, keycode, state, is_press);

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

/* ---- _keygrabber test helper module (somewm-specific) ---- */

/** Inject a key event into the keygrabber for testing.
 * Called from Lua: _keygrabber.inject(keyname, is_press)
 * Returns: boolean (consumed by keygrabber)
 *
 * Unlike root.fake_input(), this routes through the keygrabber callback,
 * following the same pattern as _gesture.inject().
 */
static int
luaA_keygrabber_inject(lua_State *L)
{
    const char *key_str = luaL_checkstring(L, 1);
    if (lua_gettop(L) < 2)
        return luaL_error(L, "_keygrabber.inject requires 2 arguments: keyname, is_press");
    bool is_press = lua_toboolean(L, 2);

    struct xkb_keymap *keymap = some_xkb_get_keymap();
    struct xkb_state *state = some_xkb_get_state();
    if (!keymap || !state) {
        lua_pushboolean(L, 0);
        return 1;
    }

    /* Resolve keysym name to keycode */
    xkb_keysym_t keysym = xkb_keysym_from_name(key_str, XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == XKB_KEY_NoSymbol)
        return luaL_error(L, "Unknown keysym: %s", key_str);

    xkb_keycode_t keycode = 0;
    xkb_keycode_t min_kc = xkb_keymap_min_keycode(keymap);
    xkb_keycode_t max_kc = xkb_keymap_max_keycode(keymap);
    for (xkb_keycode_t kc = min_kc; kc <= max_kc; kc++) {
        const xkb_keysym_t *syms;
        int nsyms = xkb_keymap_key_get_syms_by_level(keymap, kc, 0, 0, &syms);
        for (int i = 0; i < nsyms; i++) {
            if (syms[i] == keysym) {
                keycode = kc;
                break;
            }
        }
        if (keycode != 0)
            break;
    }
    if (keycode == 0)
        return luaL_error(L, "Keysym '%s' not in current keymap", key_str);

    bool consumed = some_keygrabber_handle_key(keycode, state, is_press);
    lua_pushboolean(L, consumed);
    return 1;
}

static const struct luaL_Reg awesome_keygrabber_test_lib[] =
{
    { "inject", luaA_keygrabber_inject },
    { NULL, NULL }
};

void
luaA_keygrabber_test_setup(lua_State *L)
{
    luaA_setfuncs(L, awesome_keygrabber_test_lib);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
