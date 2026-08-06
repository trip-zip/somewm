/*
 * event.c - event handling helpers
 *
 * Adapted from AwesomeWM's event.c for somewm (Wayland compositor)
 * Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "event.h"
#include "event_queue.h"
#include "globalconf.h"
#include "common/luaobject.h"

/** Record that the given drawable contains the pointer.
 * Emits mouse::enter/leave signals on drawables for widget hover events.
 */
void
event_drawable_under_mouse(lua_State *L, int ud)
{
	void *d;

	/* luaA_object_ref pops, so push a copy first */
	lua_pushvalue(L, ud);
	d = luaA_object_ref(L, -1);

	if (d == globalconf.drawable_under_mouse) {
		luaA_object_unref(L, d);
		return;
	}

	if (globalconf.drawable_under_mouse != NULL) {
		luaA_object_push(L, globalconf.drawable_under_mouse);
		some_event_queue_signal0(L, -1, SIG_MOUSE_LEAVE);
		lua_pop(L, 1);
		luaA_object_unref(L, globalconf.drawable_under_mouse);
		globalconf.drawable_under_mouse = NULL;
	}

	if (d != NULL) {
		globalconf.drawable_under_mouse = d;
		some_event_queue_signal0(L, ud, SIG_MOUSE_ENTER);
	}
}
