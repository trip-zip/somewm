/*
 * property.h - property handlers header
 *
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
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

#ifndef SOMEWM_PROPERTY_H
#define SOMEWM_PROPERTY_H

#include "objects/client.h"
#include <wayland-server-core.h>

/* ========================================================================
 * Wayland Property Listeners (Native Wayland clients)
 * ======================================================================== */

/** Register Wayland property listeners for a client
 * Attaches listeners to xdg_toplevel events for native Wayland clients
 * \param c The client
 */
void property_register_wayland_listeners(client_t *c);

/** Handle xdg_toplevel.set_title event
 * \param listener The wl_listener
 * \param data User data (client_t *)
 */
void property_handle_toplevel_title(struct wl_listener *listener, void *data);

/** Handle xdg_toplevel.set_app_id event
 * \param listener The wl_listener
 * \param data User data (client_t *)
 */
void property_handle_toplevel_app_id(struct wl_listener *listener, void *data);

/* ========================================================================
 * XWayland Property Handling (X11 clients)
 * ======================================================================== */

#ifdef XWAYLAND

/** Update all XWayland properties for a client
 * Called during initial client setup to fetch all X11 properties at once.
 * Uses wlroots' cached XWayland surface properties (title, class, pid, etc.)
 * \param c The client
 */
void property_update_xwayland_properties(client_t *c);

#endif /* XWAYLAND */

/* ========================================================================
 * Lua API for Custom Properties
 * ======================================================================== */

/** Register a custom X property to watch (Lua API: awesome.register_xproperty)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int luaA_register_xproperty(lua_State *L);

/** Set an X property value (Lua API: awesome.set_xproperty)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int luaA_set_xproperty(lua_State *L);

/** Get an X property value (Lua API: awesome.get_xproperty)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int luaA_get_xproperty(lua_State *L);

/* ========================================================================
 * Custom Property Types (for Lua API)
 * ======================================================================== */

/** Custom X property structure (for awesome.register_xproperty) */
typedef struct xproperty {
    uint32_t atom;      /* xcb_atom_t on X11, placeholder on pure Wayland */
    const char *name;
    enum {
        /* UTF8_STRING */
        PROP_STRING,
        /* CARDINAL */
        PROP_NUMBER,
        /* CARDINAL with values 0 and 1 */
        PROP_BOOLEAN
    } type;
} xproperty_t;

/* Note: Array functions for xproperty_t (BARRAY_FUNCS) will be added
 * when implementing full custom property support. For now, the Lua API
 * functions return errors indicating they're not yet implemented. */

#endif /* SOMEWM_PROPERTY_H */
// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
