/*
 * xkb.c - keyboard layout control functions
 *
 * Copyright © 2015 Aleksey Fedotov <lexa@cfotr.com>
 * Copyright © 2024 somewm contributors
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

/**
 * @module awesome
 */

#include "xkb.h"
#include "globalconf.h"
#include "luaa.h"

#include <glib.h>
#include <stdbool.h>
#include <xkbcommon/xkbcommon.h>

/* Forward declaration for signal emission */
void luaA_emit_signal_global(const char *name);

/**
 * Switch keyboard layout.
 *
 * @staticfct xkb_set_layout_group
 * @tparam integer num Keyboard layout number, integer from 0 to 3
 * @noreturn
 */
int
luaA_xkb_set_layout_group(lua_State *L)
{
    /* X11-only: Wayland keyboard layout is per-seat, not global.
     * In Wayland, layout switching is handled by the compositor or
     * by each application's input method. */
    (void)L;
    return 0;
}

/**
 * Get current layout number.
 *
 * @staticfct xkb_get_layout_group
 * @treturn integer num Current layout number, integer from 0 to 3.
 */
int
luaA_xkb_get_layout_group(lua_State *L)
{
    /* X11-only: Return 0 as default group.
     * In Wayland, the layout group is per-seat. */
    lua_pushinteger(L, 0);
    return 1;
}

/**
 * Get layout short names.
 *
 * @staticfct xkb_get_group_names
 * @treturn string A string describing the current layout settings,
 *   e.g.: 'pc+us+de:2+inet(evdev)+group(alt_shift_toggle)+ctrl(nocaps)'
 */
int
luaA_xkb_get_group_names(lua_State *L)
{
    /* X11-only: Return empty string.
     * In Wayland, layout names come from the seat's keyboard. */
    lua_pushstring(L, "");
    return 1;
}

static bool __attribute__((unused))
fill_rmlvo_from_root(struct xkb_rule_names *xkb_names)
{
    /* X11-only: Reads _XKB_RULES_NAMES from root window.
     * Wayland gets RMLVO from wlr_keyboard. */
    (void)xkb_names;
    return false;
}

static void __attribute__((unused))
xkb_fill_state(void)
{
    /* X11-only: Fills xkb_state from X11 connection.
     * Wayland uses wlr_keyboard state. */
}

static void __attribute__((unused))
xkb_init_keymap(void)
{
    /* X11-only: Initializes keymap from X11.
     * Wayland keymap comes from wlr_keyboard. */
}

static void __attribute__((unused))
xkb_free_keymap(void)
{
    /* X11-only: Frees X11 keymap resources. */
}

static void __attribute__((unused))
xkb_reload_keymap(void)
{
    /* X11-only: Reloads keymap after XKB events.
     * Wayland handles keymap changes via wlr_keyboard events. */
}

/* Deferred XKB signal emission (matches AwesomeWM's xkb_refresh pattern) */
static gboolean
xkb_refresh(gpointer unused)
{
    (void)unused;
    globalconf.xkb.update_pending = false;

    if (globalconf.xkb.map_changed)
        luaA_emit_signal_global("xkb::map_changed");

    if (globalconf.xkb.group_changed)
        luaA_emit_signal_global("xkb::group_changed");

    globalconf.xkb.map_changed = false;
    globalconf.xkb.group_changed = false;

    return G_SOURCE_REMOVE;
}

static void
xkb_schedule_refresh(void)
{
    if (globalconf.xkb.update_pending)
        return;
    globalconf.xkb.update_pending = true;
    g_idle_add_full(G_PRIORITY_LOW, xkb_refresh, NULL, NULL);
}

/** The xkb notify event handler.
 * \param event The event.
 */
void
event_handle_xkb_notify(xcb_generic_event_t* event)
{
    /* X11-only: Handles XCB_XKB_* events.
     * Wayland uses wlr_keyboard events instead. */
    (void)event;
}

/** Initialize XKB support
 * This call allocates resources, that should be freed by calling xkb_free()
 */
void
xkb_init(void)
{
    /* X11-only: Sets up XKB extension.
     * Wayland keyboard init is in compositor setup. */
    globalconf.xkb.update_pending = false;
    globalconf.xkb.map_changed = false;
    globalconf.xkb.group_changed = false;
}

/** Frees resources allocated by xkb_init()
 */
void
xkb_free(void)
{
    /* X11-only: Unsubscribes from XKB events and frees keymap. */
}

/*
 * somewm Wayland-specific functions
 */

void
xkb_schedule_group_changed(void)
{
    globalconf.xkb.group_changed = true;
    xkb_schedule_refresh();
}

void
xkb_schedule_map_changed(void)
{
    globalconf.xkb.map_changed = true;
    xkb_schedule_refresh();
}
