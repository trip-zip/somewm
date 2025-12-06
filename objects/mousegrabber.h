/*
 * mousegrabber.h - mouse pointer grabbing header
 *
 * Adapted from AwesomeWM's mousegrabber.h for somewm (Wayland compositor)
 * Copyright © 2008 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed it and/or modify
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

#ifndef SOMEWM_MOUSEGRABBER_H
#define SOMEWM_MOUSEGRABBER_H

#include <lua.h>
#include <stdint.h>
#include <stdbool.h>

/** Stop mousegrabber.
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int luaA_mousegrabber_stop(lua_State *L);

/** Handle pointer motion events during grab.
 * Routes motion events to Lua callback when mousegrabber is active.
 * \param L The Lua VM state
 * \param x The mouse X coordinate
 * \param y The mouse Y coordinate
 * \param button_states Array of 5 button states (pressed/not pressed)
 */
void mousegrabber_handleevent(lua_State *L, double x, double y, int *button_states);

/** Check if mousegrabber is currently active.
 * \return true if mousegrabber is running, false otherwise
 */
bool mousegrabber_isrunning(void);

/** Initialize the mousegrabber Lua module
 * \param L The Lua VM state
 */
void luaA_mousegrabber_setup(lua_State *L);

#endif /* SOMEWM_MOUSEGRABBER_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
