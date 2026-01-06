/*
 * keygrabber.h - key grabbing header
 *
 * Copyright © 2008 Julien Danjou <julien@danjou.info>
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

#ifndef AWESOME_KEYGRABBER_H
#define AWESOME_KEYGRABBER_H

#include <lua.h>
#include <xkbcommon/xkbcommon.h>
#include <stdbool.h>
#include <stdint.h>

int luaA_keygrabber_stop(lua_State *);
bool keygrabber_handlekpress(lua_State *, xkb_keycode_t, struct xkb_state *, bool);

/* somewm-specific */
bool some_keygrabber_is_running(void);
bool some_keygrabber_handle_key(uint32_t modifiers, uint32_t keysym, const char *keyname);
void luaA_keygrabber_setup(lua_State *L);

#endif
// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
