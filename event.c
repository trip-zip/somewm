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
#include "objects/mousegrabber.h"
#include "somewm_api.h"
#include "luaa.h"
#include "common/luaobject.h"
#include <stdio.h>

/** Handle event with mousegrabber if active
 * Ported from AwesomeWM's event_handle_mousegrabber()
 *
 * The mask passed to the grabber is built from the tracked button state;
 * extra_mask bits are ORed in. Scroll buttons (4-7) are synthesized from
 * axis events and never held, so they only ever arrive via extra_mask.
 *
 * \param x Mouse X coordinate
 * \param y Mouse Y coordinate
 * \param extra_mask X11-style button mask bits to add to the tracked state
 * \return true if event consumed by mousegrabber
 */
bool
event_handle_mousegrabber(double x, double y, uint16_t extra_mask)
{
    lua_State *L;
    uint16_t mask;

    if (!mousegrabber_isrunning())
        return false;

    L = globalconf_get_lua_State();
    mask = extra_mask | some_button_state_mask();

    /* Push coords table to stack */
    mousegrabber_handleevent(L, (int)x, (int)y, mask);

    /* Get mousegrabber callback */
    lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

    /* Push coords as argument */
    lua_pushvalue(L, -2);

    /* Call callback(coords) */
    if (lua_pcall(L, 1, 1, 0) == 0) {
        /* Check return value */
        if (!lua_isboolean(L, -1) || !lua_toboolean(L, -1)) {
            /* Callback returned false - stop grabbing */
            luaA_mousegrabber_stop(L);
        }
        lua_pop(L, 1);  /* Pop return value */
    } else {
        /* Error in callback - stop grabbing */
        fprintf(stderr, "somewm: mousegrabber error: %s\n",
                lua_tostring(L, -1));
        lua_pop(L, 1);  /* Pop error message */
        luaA_mousegrabber_stop(L);
    }

    lua_pop(L, 1);  /* Pop coords table */
    return true;
}

/** Deliver scroll ticks to the mousegrabber as X11-style button events.
 *
 * X11 delivers each tick as a press+release pair: the button's state mask
 * bit set, then cleared. Only buttons 1-5 have a state mask bit, so
 * horizontal ticks (buttons 6/7) set no flag, matching upstream.
 *
 * \param x Mouse X coordinate
 * \param y Mouse Y coordinate
 * \param button X11 button number (4-7)
 * \param ticks Number of full scroll ticks to deliver
 */
void
event_handle_mousegrabber_scroll(double x, double y, uint32_t button, int ticks)
{
    uint16_t press_mask = button <= 5 ? 1 << (7 + button) : 0;

    for (int tick = 0; tick < ticks; tick++) {
        if (!event_handle_mousegrabber(x, y, press_mask))
            break;
        if (!event_handle_mousegrabber(x, y, 0))
            break;
    }
}

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
