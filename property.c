/*
 * property.c - property handlers
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

#include "property.h"
#include "objects/client.h"
#include "luaa.h"
#include "globalconf.h"

#include <wayland-server-core.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <string.h>

/* ========================================================================
 * Wayland Property Handlers (Native Wayland clients)
 * ======================================================================== */

/** Handle xdg_toplevel.set_title event
 * Called when a native Wayland client changes its window title
 * \param listener The wl_listener
 * \param data User data (not used, title comes from toplevel)
 */
void
property_handle_toplevel_title(struct wl_listener *listener, void *data)
{
	client_t *c;
	struct wlr_xdg_toplevel *toplevel;
	lua_State *L;
	const char *title;

	(void)data; /* Unused */

	/* Get client from listener */
	c = wl_container_of(listener, c, set_title);
	if (!c || c->client_type != XDGShell)
		return;

	/* Get title from xdg_toplevel */
	toplevel = c->surface.xdg->toplevel;
	if (!toplevel)
		return;

	title = toplevel->title;

	/* Update client name using proper AwesomeWM setter
	 * This will emit property::name signal on the client object */
	L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	client_set_name(L, -1, title ? strdup(title) : NULL);
	lua_pop(L, 1);
}

/** Handle xdg_toplevel.set_app_id event
 * Called when a native Wayland client changes its app_id (equivalent to WM_CLASS)
 * \param listener The wl_listener
 * \param data User data (not used, app_id comes from toplevel)
 */
void
property_handle_toplevel_app_id(struct wl_listener *listener, void *data)
{
	client_t *c;
	struct wlr_xdg_toplevel *toplevel;
	lua_State *L;
	const char *app_id;

	(void)data; /* Unused */

	/* Get client from listener - note: we reuse set_title listener for app_id
	 * In practice, app_id changes are rare after initial mapping */
	c = wl_container_of(listener, c, set_title);
	if (!c || c->client_type != XDGShell)
		return;

	/* Get app_id from xdg_toplevel */
	toplevel = c->surface.xdg->toplevel;
	if (!toplevel)
		return;

	app_id = toplevel->app_id;

	/* Update client class using proper AwesomeWM setter
	 * This will emit property::class signal on the client object
	 * Note: Wayland doesn't have "instance" like X11, so we set class only */
	L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	client_set_class_instance(L, -1,
		app_id ? app_id : "",
		""); /* Empty instance for Wayland clients */
	lua_pop(L, 1);
}

/** Update all Wayland properties for a client
 * Called during initial client setup to fetch all properties at once
 * \param c The client
 */
void
property_update_wayland_properties(client_t *c)
{
	struct wlr_xdg_toplevel *toplevel;
	struct wlr_surface *surface;
	struct wl_client *wl_client;
	lua_State *L;
	pid_t pid;

	if (!c || c->client_type != XDGShell)
		return;

	toplevel = c->surface.xdg->toplevel;
	if (!toplevel)
		return;

	L = globalconf_get_lua_State();
	luaA_object_push(L, c);

	/* Update title */
	if (toplevel->title)
		client_set_name(L, -1, strdup(toplevel->title));

	/* Update app_id (class) */
	if (toplevel->app_id) {
		client_set_class_instance(L, -1, toplevel->app_id, "");
	}

	/* Get PID from wl_client */
	surface = c->surface.xdg->surface;
	if (surface && surface->resource) {
		wl_client = wl_resource_get_client(surface->resource);
		wl_client_get_credentials(wl_client, &pid, NULL, NULL);
		client_set_pid(L, -1, (uint32_t)pid);
	}

	/* Note: Wayland doesn't have equivalents for:
	 * - icon_name (no protocol support)
	 * - role (X11-specific, use window type instead)
	 * - machine (get via PID if needed)
	 * - instance (X11-specific WM_CLASS component)
	 */

	lua_pop(L, 1);
}

/** Register Wayland property listeners for a client
 * Attaches listeners to xdg_toplevel events for native Wayland clients
 * \param c The client
 */
void
property_register_wayland_listeners(client_t *c)
{
	struct wlr_xdg_toplevel *toplevel;

	if (!c || c->client_type != XDGShell)
		return;

	toplevel = c->surface.xdg->toplevel;
	if (!toplevel)
		return;

	/* Note: The set_title listener is already registered in somewm.c
	 * via LISTEN(&toplevel->events.set_title, &c->set_title, updatetitle)
	 * We don't need to register it again here.
	 *
	 * XDG shell doesn't have separate events for app_id changes,
	 * so we handle app_id during initial property fetch.
	 */

	/* Fetch initial properties */
	property_update_wayland_properties(c);
}

/* ========================================================================
 * XWayland Property Handling (X11 clients)
 * ======================================================================== */

#ifdef XWAYLAND

#include <wlr/xwayland.h>
#include <xcb/xcb_icccm.h>

/** Update all XWayland properties for a client
 * Called during initial client setup to fetch all X11 properties at once.
 * Uses wlroots' cached XWayland surface properties.
 * \param c The client
 */
void
property_update_xwayland_properties(client_t *c)
{
	struct wlr_xwayland_surface *xsurface;
	lua_State *L;

	if (!c || c->client_type != X11)
		return;

	xsurface = c->surface.xwayland;
	if (!xsurface)
		return;

	L = globalconf_get_lua_State();
	luaA_object_push(L, c);

	/* Title (WM_NAME or _NET_WM_NAME - wlroots provides best available) */
	if (xsurface->title)
		client_set_name(L, -1, strdup(xsurface->title));

	/* Class and instance (WM_CLASS) */
	client_set_class_instance(L, -1,
		xsurface->class ? xsurface->class : "",
		xsurface->instance ? xsurface->instance : "");

	/* PID (_NET_WM_PID) */
	if (xsurface->pid > 0)
		client_set_pid(L, -1, (uint32_t)xsurface->pid);

	/* Role (WM_WINDOW_ROLE) - wlroots exposes this */
	if (xsurface->role)
		client_set_role(L, -1, strdup(xsurface->role));

	/* Size hints (WM_NORMAL_HINTS) */
	if (xsurface->size_hints) {
		xcb_size_hints_t *hints = xsurface->size_hints;

		/* Copy size hints to client structure */
		c->size_hints.flags = hints->flags;
		c->size_hints.x = hints->x;
		c->size_hints.y = hints->y;
		c->size_hints.width = hints->width;
		c->size_hints.height = hints->height;
		c->size_hints.min_width = hints->min_width;
		c->size_hints.min_height = hints->min_height;
		c->size_hints.max_width = hints->max_width;
		c->size_hints.max_height = hints->max_height;
		c->size_hints.base_width = hints->base_width;
		c->size_hints.base_height = hints->base_height;
		c->size_hints.width_inc = hints->width_inc;
		c->size_hints.height_inc = hints->height_inc;
		c->size_hints.min_aspect_num = hints->min_aspect_num;
		c->size_hints.min_aspect_den = hints->min_aspect_den;
		c->size_hints.max_aspect_num = hints->max_aspect_num;
		c->size_hints.max_aspect_den = hints->max_aspect_den;
		c->size_hints.win_gravity = hints->win_gravity;

		/* Emit size_hints signal */
		luaA_object_emit_signal(L, -1, "property::size_hints", 0);
	}

	/* WM_HINTS (urgency, input focus, window group, icons)
	 * These are handled by sethints() listener, but we can set initial values */
	if (xsurface->hints) {
		xcb_icccm_wm_hints_t *hints = xsurface->hints;

		/* Input focus */
		if (hints->flags & XCB_ICCCM_WM_HINT_INPUT)
			c->nofocus = !hints->input;

		/* Window group */
		if (hints->flags & XCB_ICCCM_WM_HINT_WINDOW_GROUP)
			client_set_group_window(L, -1, hints->window_group);

		/* Urgency (use proper API for signal emission) */
		client_set_urgent(L, -1, xcb_icccm_wm_hints_get_urgency(hints));
	}

	/* Transient-for relationship */
	if (xsurface->parent) {
		c->transient_for_window = xsurface->parent->window_id;
		/* client_find_transient_for() will resolve this to client_t* */
		client_find_transient_for(c);
	}

	lua_pop(L, 1);
}

#endif /* XWAYLAND */

/* ========================================================================
 * Lua API for Custom Properties
 * ======================================================================== */

/** Register a custom X property to watch (Lua API: awesome.register_xproperty)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int
luaA_register_xproperty(lua_State *L)
{
	/* TODO: Implement custom property registration
	 * This is used by Lua configs to watch arbitrary X properties
	 * Low priority for initial implementation */
	return luaL_error(L, "awesome.register_xproperty not yet implemented");
}

/** Set an X property value (Lua API: awesome.set_xproperty)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int
luaA_set_xproperty(lua_State *L)
{
	/* TODO: Implement X property setter
	 * Low priority for initial implementation */
	return luaL_error(L, "awesome.set_xproperty not yet implemented");
}

/** Get an X property value (Lua API: awesome.get_xproperty)
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 */
int
luaA_get_xproperty(lua_State *L)
{
	/* TODO: Implement X property getter
	 * Low priority for initial implementation */
	return luaL_error(L, "awesome.get_xproperty not yet implemented");
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
