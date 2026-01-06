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
#include "globalconf.h"
#include "objects/button.h"
#include "objects/mousegrabber.h"
#include "luaa.h"
#include "common/luaobject.h"
#include "common/util.h"
#include <stdio.h>

/* AwesomeWM compatibility: ANY modifier mask */
#define BUTTON_MODIFIER_ANY 0xFFFF

/** Check if button event matches button binding
 * Ported from AwesomeWM's event_button_match()
 * \param ev Button event
 * \param b Button binding
 * \param data User data (unused)
 * \return true if match
 */
bool
event_button_match(button_event_t *ev, button_t *b, void *data)
{
    bool button_matches;
    bool mods_match;

    (void)data;  /* Unused */

    /* Match button: 0 = any button, else exact match */
    button_matches = (!b->button || ev->button == b->button);

    /* Match modifiers: BUTTON_MODIFIER_ANY = any, else exact match */
    mods_match = (b->modifiers == BUTTON_MODIFIER_ANY ||
                  b->modifiers == (ev->state & 0xFF));

    return button_matches && mods_match;
}

/** Generic button array callback - iterate and emit signals
 * Ported from AwesomeWM's DO_EVENT_HOOK_CALLBACK macro
 * This implements the two-stage pattern:
 * - Stage 1: Generic button::press/release on object (done by caller)
 * - Stage 2: Specific press/release on matching button objects (done here)
 *
 * \param ev Button event
 * \param arr Button array to check
 * \param L Lua state
 * \param oud Object-under index on stack (0 for global, <0 for relative)
 * \param nargs Number of arguments to pass to button signals (usually 0)
 * \param data User data passed to match function
 */
void
event_button_callback(button_event_t *ev, button_array_t *arr,
                      lua_State *L, int oud, int nargs, void *data)
{
    int abs_oud;
    int item_matching;
    const char *signal_name;
    int i;

    if (!arr || !arr->tab || arr->len == 0)
        return;

    /* Convert relative stack index to absolute */
    abs_oud = oud < 0 ? ((lua_gettop(L) + 1) + oud) : oud;
    item_matching = 0;

    /* First pass: push all matching button objects to stack */
    for (i = 0; i < arr->len; i++) {
        button_t *btn = arr->tab[i];

        if (event_button_match(ev, btn, data)) {
            /* Push button object - either from object or directly */
            if (oud)
                luaA_object_push_item(L, abs_oud, btn);
            else
                luaA_object_push(L, btn);
            item_matching++;
        }
    }

    /* Second pass: emit signals on each matching button */
    signal_name = ev->is_press ? "press" : "release";

    for (; item_matching > 0; item_matching--) {
        /* Duplicate arguments for this button (if any) */
        for (i = 0; i < nargs; i++)
            lua_pushvalue(L, -nargs - item_matching);

        /* Emit signal on button object */
        luaA_object_emit_signal(L, -nargs - 1, signal_name, nargs);

        /* Pop button object */
        lua_pop(L, 1);
    }

    /* Pop arguments */
    lua_pop(L, nargs);
}

/** Emit button::press or button::release signal on object
 * Ported from AwesomeWM's event_emit_button()
 * Object must be at top of stack!
 *
 * \param L Lua state
 * \param ev Button event
 */
void
event_emit_button(lua_State *L, button_event_t *ev)
{
    const char *name = ev->is_press ? "button::press" : "button::release";

    /* Push event arguments: x, y, button, modifiers */
    lua_pushinteger(L, ev->x);
    lua_pushinteger(L, ev->y);
    lua_pushinteger(L, ev->button);

    /* Push modifiers table (AwesomeWM compatibility) */
    lua_newtable(L);
    /* For now, simple modifier mask - can enhance later */
    lua_pushinteger(L, ev->state);
    lua_setfield(L, -2, "_mask");

    /* Emit signal with 4 arguments */
    luaA_object_emit_signal(L, -5, name, 4);
}

/** Handle event with mousegrabber if active
 * Ported from AwesomeWM's event_handle_mousegrabber()
 *
 * \param x Mouse X coordinate
 * \param y Mouse Y coordinate
 * \param button_states Array of 5 button states
 * \return true if event consumed by mousegrabber
 */
bool
event_handle_mousegrabber(double x, double y, int button_states[5])
{
    lua_State *L;

    if (!mousegrabber_isrunning())
        return false;

    L = globalconf_get_lua_State();

    /* Push coords table to stack */
    mousegrabber_handleevent(L, x, y, button_states);

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
		luaA_object_emit_signal(L, -1, "mouse::leave", 0);
		lua_pop(L, 1);
		luaA_object_unref(L, globalconf.drawable_under_mouse);
		globalconf.drawable_under_mouse = NULL;
	}

	if (d != NULL) {
		globalconf.drawable_under_mouse = d;
		luaA_object_emit_signal(L, ud, "mouse::enter", 0);
	}
}
