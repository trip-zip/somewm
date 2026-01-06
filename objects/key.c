/*
 * key.c - Keybinding object
 *
 * Copyright © 2024 somewm contributors
 * Based on AwesomeWM's objects/key.c
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "key.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "screen.h"
#include "signal.h"
#include "luaa.h"
#include "common/util.h"
#include "../globalconf.h"
#include <xkbcommon/xkbcommon.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* Manual array implementations to avoid macro pointer type issues */
void key_array_init(key_array_t *arr) {
	arr->tab = NULL;
	arr->len = 0;
	arr->size = 0;
}

void key_array_wipe(key_array_t *arr) {
	free(arr->tab);
	arr->tab = NULL;
	arr->len = 0;
	arr->size = 0;
}

void key_array_append(key_array_t *arr, keyb_t *elem) {
	if (arr->len >= arr->size) {
		arr->size = arr->size ? arr->size * 2 : 4;
		arr->tab = realloc(arr->tab, arr->size * sizeof(keyb_t *));
	}
	arr->tab[arr->len++] = elem;
}

/** Set key array from Lua table (AwesomeWM pattern)
 * Ported from AwesomeWM objects/key.c:luaA_key_array_set
 * \param L Lua state
 * \param oidx Owner object index on stack
 * \param idx Key table index on stack
 * \param keys Array to fill
 */
void
luaA_key_array_set(lua_State *L, int oidx, int idx, key_array_t *keys)
{
	luaA_checktable(L, idx);

	/* Unref all existing key objects */
	for (int i = 0; i < keys->len; i++)
		luaA_object_unref_item(L, oidx, keys->tab[i]);

	/* Clear and reinitialize the array */
	key_array_wipe(keys);
	key_array_init(keys);

	/* Iterate through table and add key objects */
	lua_pushnil(L);
	while (lua_next(L, idx)) {
		if (luaA_toudata(L, -1, &key_class))
			key_array_append(keys, luaA_object_ref_item(L, oidx, -1));
		else
			lua_pop(L, 1);
	}
}

/** Push key array as Lua table (AwesomeWM pattern)
 * Ported from AwesomeWM objects/key.c:luaA_key_array_get
 * \param L Lua state
 * \param oidx Owner object index on stack
 * \param keys Array to push
 * \return Number of values pushed (1)
 */
int
luaA_key_array_get(lua_State *L, int oidx, key_array_t *keys)
{
	lua_createtable(L, keys->len, 0);
	for (int i = 0; i < keys->len; i++) {
		luaA_object_push_item(L, oidx, keys->tab[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/* Setup key object class */
lua_class_t key_class;

/** Get the name of a keysym.
 * It's caller's responsibility to release the returned string.
 * \param keysym The keysym to get the name of.
 * \return A newly allocated string with the keysym name, or NULL on error.
 */
char *
key_get_keysym_name(xkb_keysym_t keysym)
{
	const ssize_t bufsize = 64;
	char *buf = p_new(char, bufsize);
	ssize_t len;

	if ((len = xkb_keysym_get_name(keysym, buf, bufsize)) == -1) {
		p_delete(&buf);
		return NULL;
	}
	if (len + 1 > bufsize) {
		p_realloc(&buf, len + 1);
		if (xkb_keysym_get_name(keysym, buf, len + 1) != len) {
			p_delete(&buf);
			return NULL;
		}
	}
	return buf;
}

/** Modifier name to wlroots modifier mapping */
static const struct {
	const char *name;
	uint16_t mod;
} mod_names[] = {
	{ "Shift",   (1 << 0) },  /* WLR_MODIFIER_SHIFT */
	{ "Lock",    (1 << 1) },  /* WLR_MODIFIER_CAPS */
	{ "Control", (1 << 2) },  /* WLR_MODIFIER_CTRL */
	{ "Ctrl",    (1 << 2) },  /* Alias */
	{ "Mod1",    (1 << 3) },  /* WLR_MODIFIER_ALT */
	{ "Mod2",    (1 << 4) },  /* WLR_MODIFIER_MOD2 */
	{ "Mod3",    (1 << 5) },  /* WLR_MODIFIER_MOD3 */
	{ "Mod4",    (1 << 6) },  /* WLR_MODIFIER_LOGO */
	{ "Mod5",    (1 << 7) },  /* WLR_MODIFIER_MOD5 */
	{ "Any",     0xFFFF },    /* Match any modifiers */
};

/** Parse modifier string to bitmask value
 * \param mod Modifier name
 * \return Modifier bit, or 0 if not found
 */
static uint16_t
parse_modifier(const char *mod)
{
	for (size_t i = 0; i < sizeof(mod_names) / sizeof(mod_names[0]); i++) {
		if (strcmp(mod, mod_names[i].name) == 0) {
			return mod_names[i].mod;
		}
	}

	return 0;
}

/** Convert Lua table of modifier strings to bitmask
 * Stack: [..., modifiers_table]
 */
uint16_t
luaA_tomodifiers(lua_State *L, int ud)
{
	uint16_t modifiers = 0;


	luaL_checktype(L, ud, LUA_TTABLE);

	lua_pushnil(L);
	while (lua_next(L, ud < 0 ? ud - 1 : ud)) {
		if (lua_isstring(L, -1)) {
			const char *mod = lua_tostring(L, -1);
			modifiers |= parse_modifier(mod);
		}
		lua_pop(L, 1);
	}

	return modifiers;
}

/** Push modifier bitmask as Lua table of strings
 * \param L Lua state
 * \param modifiers Modifier bitmask
 * \return Number of values pushed (always 1)
 */
int
luaA_pushmodifiers(lua_State *L, uint16_t modifiers)
{
	int i, n = 0;

	lua_newtable(L);

	for (i = 0; i < (int)(sizeof(mod_names) / sizeof(mod_names[0])); i++) {
		if (mod_names[i].mod != 0xFFFF && (modifiers & mod_names[i].mod)) {
			lua_pushstring(L, mod_names[i].name);
			lua_rawseti(L, -2, ++n);
		}
	}

	return 1;
}

/** Store a key string into a key object.
 * Parses the key string and stores the keysym/keycode.
 * \param L The Lua VM state.
 * \param ud The index of the key object on the stack.
 * \param str The key string.
 * \param len The length of the key string.
 */
static void
luaA_keystore(lua_State *L, int ud, const char *str, ssize_t len)
{
	if (len <= 0 || !str)
		return;

	keyb_t *key = luaA_checkudata(L, ud, &key_class);

	if (len == 1) {
		/* Single character - use as keysym directly */
		key->keycode = 0;
		key->keysym = str[0];
	} else if (str[0] == '#') {
		/* Keycode syntax: #num */
		key->keycode = atoi(str + 1);
		key->keysym = 0;
	} else {
		/* Named keysym - use xkb_keysym_from_name */
		key->keycode = 0;
		key->keysym = xkb_keysym_from_name(str, XKB_KEYSYM_CASE_INSENSITIVE);

		if (key->keysym == XKB_KEY_NoSymbol) {
			luaA_warn(L, "failed to convert \"%s\" into keysym", str);
			return;
		}
	}

	luaA_object_emit_signal(L, ud, "property::key", 0);
}

/** key.modifiers property getter
 * \param L Lua state
 * \param key Key object
 * \return Number of values pushed
 */
static int
luaA_key_get_modifiers(lua_State *L, keyb_t *key)
{
	luaA_pushmodifiers(L, key->modifiers);
	return 1;
}

/** key.modifiers property setter
 * \param L Lua state
 * \param key Key object
 * \return 0
 */
static int
luaA_key_set_modifiers(lua_State *L, keyb_t *key)
{
	key->modifiers = luaA_tomodifiers(L, -1);
	luaA_object_emit_signal(L, -3, "property::modifiers", 0);
	return 0;
}

/** key.key property getter (returns keysym as string)
 * \param L Lua state
 * \param k Key object
 * \return Number of values pushed
 */
static int
luaA_key_get_key(lua_State *L, keyb_t *k)
{
	if (k->keycode) {
		char buf[12];
		int slen = snprintf(buf, sizeof(buf), "#%u", k->keycode);
		lua_pushlstring(L, buf, slen);
	} else {
		char *name = key_get_keysym_name(k->keysym);
		if (!name)
			return 0;
		lua_pushstring(L, name);
		p_delete(&name);
	}
	return 1;
}

/** key.key property setter
 * \param L Lua state
 * \param k Key object
 * \return 0
 */
static int
luaA_key_set_key(lua_State *L, keyb_t *k)
{
	size_t klen;
	const char *key = luaL_checklstring(L, -1, &klen);
	luaA_keystore(L, -3, key, klen);
	return 0;
}

/** key.keysym property getter (returns keysym as number)
 * \param L Lua state
 * \param key Key object
 * \return Number of values pushed
 */
static int
luaA_key_get_keysym(lua_State *L, keyb_t *key)
{
	lua_pushinteger(L, key->keysym);
	return 1;
}

/** Create a new key object.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_key_new(lua_State *L)
{
	return luaA_class_new(L, &key_class);
}

/** Initialize key class
 * \param L Lua state
 */
void
key_class_setup(lua_State *L)
{
	static const struct luaL_Reg key_methods[] = {
		LUA_CLASS_METHODS(key)
		{ "__call", luaA_key_new },
		{ NULL, NULL }
	};

	static const struct luaL_Reg key_meta[] = {
		LUA_OBJECT_META(key)
		LUA_CLASS_META
		{ NULL, NULL }
	};


	luaA_class_setup(L, &key_class, "key", NULL,
	                 (lua_class_allocator_t) key_new, NULL, NULL,
	                 luaA_class_index_miss_property, luaA_class_newindex_miss_property,
	                 key_methods, key_meta);

	luaA_class_add_property(&key_class, "key",
	                        (lua_class_propfunc_t) luaA_key_set_key,
	                        (lua_class_propfunc_t) luaA_key_get_key,
	                        (lua_class_propfunc_t) luaA_key_set_key);
	luaA_class_add_property(&key_class, "keysym",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_key_get_keysym,
	                        NULL);
	luaA_class_add_property(&key_class, "modifiers",
	                        (lua_class_propfunc_t) luaA_key_set_modifiers,
	                        (lua_class_propfunc_t) luaA_key_get_modifiers,
	                        (lua_class_propfunc_t) luaA_key_set_modifiers);

}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
 */
