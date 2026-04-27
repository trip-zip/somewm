/*
 * xwayland.c - XWayland X11 compatibility layer
 *
 * Handles X11 client lifecycle, configuration, activation, and EWMH
 * initialization for XWayland surfaces.
 */
#ifdef XWAYLAND

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/xwayland.h>
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>

#include "somewm.h"
#include "somewm_api.h"
#include "event_queue.h"
#include "xwayland.h"
#include "globalconf.h"
#include "common/luaobject.h"
#include "objects/signal.h"
#include "client.h"
#include "stack.h"
#include "ewmh.h"
#include "common/util.h"

/* Listener helpers */

#include "window.h"
#include "somewm_internal.h"

/* Forward declarations */
void dissociatex11(struct wl_listener *listener, void *data);
void sethints(struct wl_listener *listener, void *data);

/* Local listeners */
static struct wl_listener new_xwayland_surface;
static struct wl_listener xwayland_ready_listener;

void
activatex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, activate);

	/* Only "managed" windows can be activated */
	if (client_is_unmanaged(c))
		return;

	/* Guard against stale client: after client_unmanage() invalidates the
	 * client (window = XCB_NONE), this listener may still fire if the
	 * XWayland surface hasn't been destroyed yet (e.g., Discord close-to-tray
	 * then re-launch). Skip to prevent use-after-free and Lua panics. */
	if (c->window == XCB_NONE)
		return;

	/* Tell XWayland the surface is activated at the X11 level */
	wlr_xwayland_surface_activate(c->surface.xwayland, 1);

	/* Emit request::activate signal to Lua so it can grant keyboard focus.
	 * This matches the pattern used by foreign_toplevel_request_activate()
	 * and ensures XWayland clients go through the same focus permission
	 * system as native Wayland clients. */
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	lua_pushstring(L, "xwayland");  /* context */
	lua_newtable(L);  /* hints table */
	lua_pushboolean(L, true);
	lua_setfield(L, -2, "raise");
	some_event_queue_signal(L, -3, SIG_REQUEST_ACTIVATE, 2);
	lua_pop(L, 1);
}

void
associatex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, associate);
	struct wlr_surface *surface = client_surface(c);

	if (!surface) {
		return;
	}

	LISTEN(&surface->events.map, &c->map, mapnotify);
	LISTEN(&surface->events.unmap, &c->unmap, unmapnotify);
}

void
configurex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, configure);
	struct wlr_xwayland_surface_configure_event *event = data;
	if (c->window == XCB_NONE)
		return;
	if (!client_surface(c) || !client_surface(c)->mapped) {
		wlr_xwayland_surface_configure(c->surface.xwayland,
				event->x, event->y, event->width, event->height);
		return;
	}
	if (client_is_unmanaged(c)) {
		wlr_scene_node_set_position(&c->scene->node, event->x, event->y);
		wlr_xwayland_surface_configure(c->surface.xwayland,
				event->x, event->y, event->width, event->height);
		return;
	}
	if (some_client_get_floating(c)) {
		resize(c, (struct wlr_box){.x = event->x - c->bw,
				.y = event->y - c->bw, .width = event->width + c->bw * 2,
				.height = event->height + c->bw * 2}, 0);
	} else {
		arrange(c->mon);
	}
}

void
createnotifyx11(struct wl_listener *listener, void *data)
{
	/* XWayland client creation - follows same pattern as createnotify()
	 * but adapts for XWayland-specific protocols */
	struct wlr_xwayland_surface *xsurface = data;
	Client *c;
	lua_State *L;

	L = globalconf_get_lua_State();

	/* Create Lua client object (matches AwesomeWM client_manage line 2138) */
	c = client_new(L);
	/* client_new() leaves the client on the Lua stack at index -1 */

	/* Assign unique client ID (Sway-style incrementing counter) */
	c->id = next_client_id++;

	/* Link to XWayland surface (adapts X11 window linkage to XWayland) */
	xsurface->data = c;
	c->surface.xwayland = xsurface;
	c->client_type = X11;
	/* Set the window ID for EWMH/X11 property lookups */
	c->window = xsurface->window_id;
	c->bw = client_is_unmanaged(c) ? 0 : get_border_width();

	/* NOTE: Do NOT call ewmh_client_check_hints() here!
	 * At this point the XWayland surface exists but may not be fully initialized.
	 * Making XCB property queries here can interfere with the XWayland protocol.
	 * EWMH hints will be read in mapnotify() when the surface is ready. */

	/* Register XWayland event listeners */
	LISTEN(&xsurface->events.associate, &c->associate, associatex11);
	LISTEN(&xsurface->events.destroy, &c->destroy, destroynotify);
	LISTEN(&xsurface->events.dissociate, &c->dissociate, dissociatex11);
	LISTEN(&xsurface->events.request_activate, &c->activate, activatex11);
	LISTEN(&xsurface->events.request_configure, &c->configure, configurex11);
	LISTEN(&xsurface->events.request_fullscreen, &c->request_fullscreen, fullscreennotify);
	LISTEN(&xsurface->events.set_hints, &c->set_hints, sethints);
	LISTEN(&xsurface->events.set_title, &c->set_title, updatetitle);

	/* Add to global clients array (matches AwesomeWM client_manage line 2202) */
	lua_pushvalue(L, -1);
	client_array_push(&globalconf.clients, luaA_object_ref(L, -1));

	/* Add to stack (matches AwesomeWM client_manage) */
	stack_client_push(c);

	/* Emit client::list signal (matches AwesomeWM line 2266) */
	some_event_queue_class(&client_class, SIG_LIST);

	/* Pop the client from the Lua stack */
	lua_pop(L, 1);
}

void
dissociatex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, dissociate);
	wl_list_remove(&c->map.link);
	wl_list_remove(&c->unmap.link);
}

void
sethints(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, set_hints);
	xcb_icccm_wm_hints_t *hints = c->surface.xwayland->hints;
	lua_State *L;

	if (!hints)
		return;

	if (c->window == XCB_NONE)
		return;

	/* Get Lua state for signal emission */
	L = globalconf_get_lua_State();
	luaA_object_push(L, c);

	/* Emit request::urgent and let Lua decide (matches AwesomeWM property.c:203-204) */
	lua_pushboolean(L, xcb_icccm_wm_hints_get_urgency(hints));
	some_event_queue_signal(L, -2, SIG_REQUEST_URGENT, 1);

	/* Handle input focus hint (XCB_ICCCM_WM_HINT_INPUT)
	 * If input hint is set and false, client should not receive focus */
	if (hints->flags & XCB_ICCCM_WM_HINT_INPUT)
		c->nofocus = !hints->input;

	/* Handle window group (XCB_ICCCM_WM_HINT_WINDOW_GROUP) */
	if (hints->flags & XCB_ICCCM_WM_HINT_WINDOW_GROUP)
		client_set_group_window(L, -1, hints->window_group);

	lua_pop(L, 1);
	printstatus();
}

void
xwaylandready(struct wl_listener *listener, void *data)
{
	struct wlr_xcursor *xcursor;
	xcb_connection_t *conn;
	const xcb_setup_t *setup;
	xcb_screen_iterator_t iter;

	/* assign the one and only seat */
	wlr_xwayland_set_seat(xwayland, seat);

	/* Set the default XWayland cursor to match the rest of somewm. */
	if ((xcursor = wlr_xcursor_manager_get_xcursor(cursor_mgr, "default", 1)))
		wlr_xwayland_set_cursor(xwayland,
				xcursor->images[0]->buffer, xcursor->images[0]->width * 4,
				xcursor->images[0]->width, xcursor->images[0]->height,
				xcursor->images[0]->hotspot_x, xcursor->images[0]->hotspot_y);

	/* Initialize XCB connection for EWMH support (AwesomeWM pattern) */
	conn = xcb_connect(xwayland->display_name, NULL);
	if (xcb_connection_has_error(conn)) {
		fprintf(stderr, "somewm: Failed to connect to XWayland display %s\n",
		        xwayland->display_name);
		return;
	}
	globalconf.connection = conn;

	/* Set up X11 screen structure for EWMH (AwesomeWM pattern) */
	setup = xcb_get_setup(conn);
	iter = xcb_setup_roots_iterator(setup);
	if (!iter.rem) {
		fprintf(stderr, "somewm: XWayland setup has no screens\n");
		return;
	}

	/* Allocate and populate screen structure */
	globalconf.screen = calloc(1, sizeof(*globalconf.screen));
	if (!globalconf.screen) {
		fprintf(stderr, "somewm: Failed to allocate screen structure\n");
		return;
	}
	globalconf.screen->root = iter.data->root;
	globalconf.screen->black_pixel = iter.data->black_pixel;
	globalconf.screen->root_depth = iter.data->root_depth;
	globalconf.screen->root_visual = iter.data->root_visual;

	/* Initialize EWMH atoms (must be done before ewmh_init) */
	init_ewmh_atoms(conn);

	/* Initialize EWMH support on root window */
	ewmh_init(conn, 0);

	/* Connect Lua signals for automatic EWMH property updates */
	ewmh_init_lua();

	log_info("EWMH support initialized for XWayland");

	/* Notify Lua that XWayland is fully usable: DISPLAY socket bound,
	 * EWMH atoms initialized, Lua property handlers connected. Subscribers
	 * (e.g. autostart of Qt5/GTK X11 apps that race the DISPLAY socket)
	 * can act now. The flag lets luaA_hot_reload() re-emit for late
	 * subscribers after rc.lua reload. */
	globalconf.xwayland_ready_seen = true;
	luaA_emit_signal_global("xwayland::ready");
}

void
xwayland_setup(void)
{
	if ((xwayland = wlr_xwayland_create(dpy, compositor, 1))) {
		wl_signal_add(&xwayland->events.ready,
			(xwayland_ready_listener.notify = xwaylandready,
			 &xwayland_ready_listener));
		wl_signal_add(&xwayland->events.new_surface,
			(new_xwayland_surface.notify = createnotifyx11,
			 &new_xwayland_surface));

		setenv("DISPLAY", xwayland->display_name, 1);
	} else {
		fprintf(stderr, "failed to setup XWayland X server, continuing without it\n");
	}
}

void
xwayland_cleanup(void)
{
	wl_list_remove(&new_xwayland_surface.link);
	wl_list_remove(&xwayland_ready_listener.link);
	if (xwayland) {
		wlr_xwayland_destroy(xwayland);
		xwayland = NULL;
	}
}

#endif /* XWAYLAND */
