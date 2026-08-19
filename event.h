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

/** Route an input event to the mousegrabber if one is active.
 * \return true if the event was consumed by the mousegrabber.
 */
bool event_handle_mousegrabber(double x, double y, uint16_t extra_mask);

/** Deliver scroll ticks to an active mousegrabber as press+release pairs. */
void event_handle_mousegrabber_scroll(double x, double y, uint32_t button,
                                      int ticks);

#endif /* SOMEWM_EVENT_H */
