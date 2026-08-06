/*
 * event.h - event handling helpers
 *
 * Adapted from AwesomeWM's event.c for somewm (Wayland compositor)
 * Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef SOMEWM_EVENT_H
#define SOMEWM_EVENT_H

#include <lua.h>
#include "globalconf.h"

/** Record that the given drawable contains the pointer.
 * Emits mouse::enter/leave signals on drawables for widget hover events.
 */
void event_drawable_under_mouse(lua_State *L, int ud);

#endif /* SOMEWM_EVENT_H */
