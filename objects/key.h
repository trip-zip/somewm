/*
 * key.h - Keybinding object
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

#ifndef AWESOME_OBJECTS_KEY_H
#define AWESOME_OBJECTS_KEY_H

#include <xkbcommon/xkbcommon.h>
#include <stdint.h>

/* Forward declare types we need */
typedef struct lua_State lua_State;

#include "common/luaclass.h"
#include "common/luaobject.h"

/** Key object structure */
typedef struct keyb_t
{
	LUA_OBJECT_HEADER
	/** Modifier mask */
	uint16_t modifiers;
	/** Keysym */
	xkb_keysym_t keysym;
	/** Keycode (optional, for direct keycode bindings like #10) */
	xkb_keycode_t keycode;
} keyb_t;

/** Key class */
extern lua_class_t key_class;

/** Initialize key class
 * \param L Lua state
 */
void key_class_setup(lua_State *L);

/** Convert Lua table of modifier strings to bitmask
 * \param L Lua state
 * \param ud Stack index of modifier table
 * \return Modifier bitmask
 */
uint16_t luaA_tomodifiers(lua_State *L, int ud);

/** Push modifier bitmask as Lua table of strings
 * \param L Lua state
 * \param modifiers Modifier bitmask
 * \return Number of values pushed
 */
int luaA_pushmodifiers(lua_State *L, uint16_t modifiers);

/* Object functions */
LUA_OBJECT_FUNCS(key_class, keyb_t, key)

/* key_array_t type - matches globalconf.h definition */
#ifndef KEY_ARRAY_T_DEFINED
#define KEY_ARRAY_T_DEFINED
typedef struct {
	keyb_t **tab;
	int len, size;
} key_array_t;
#endif

/* Array function declarations - manually defined to avoid macro issues */
void key_array_init(key_array_t *arr);
void key_array_wipe(key_array_t *arr);
void key_array_append(key_array_t *arr, keyb_t *elem);

/** Set key array from Lua table (AwesomeWM pattern)
 * \param L Lua state
 * \param oidx Owner object index on stack
 * \param idx Key table index on stack
 * \param keys Array to fill
 */
void luaA_key_array_set(lua_State *L, int oidx, int idx, key_array_t *keys);

/** Push key array as Lua table (AwesomeWM pattern)
 * \param L Lua state
 * \param oidx Owner object index on stack
 * \param keys Array to push
 * \return Number of values pushed (1)
 */
int luaA_key_array_get(lua_State *L, int oidx, key_array_t *keys);

#endif
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
 */
