/* window.c - Window lifecycle, geometry, and scene graph management */

#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#ifdef XWAYLAND
#include <wlr/xwayland.h>
#include <xcb/xcb.h>
#include "xwayland.h"
#endif

#include "somewm.h"
#include "somewm_api.h"
#include "window.h"
#include "monitor.h"
#include "protocols.h"
#include "input.h"
#include "globalconf.h"
#include "client.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/screen.h"
#include "objects/output.h"
#include "objects/drawin.h"
#include "objects/drawable.h"
#include "objects/tag.h"
#include "objects/layer_surface.h"
#include "objects/signal.h"
#include "objects/button.h"
#include "stack.h"
#include "banning.h"
#include "ewmh.h"
#include "property.h"
#include "shadow.h"
#include "animation.h"
#include "event.h"
#include "systray.h"
#include "draw.h"
#include "objects/spawn.h"

/* macros */
#define LISTEN(E, L, H)         wl_signal_add((E), ((L)->notify = (H), (L)))

/* extern declarations for functions still in somewm.c */
#include "focus.h"
extern void cursor_to_client_coordinates(Client *client, double *sx, double *sy);
extern void some_recompute_idle_inhibit(struct wlr_surface *exclude);
extern void some_refresh(void);
extern void printstatus(void);
extern void spawn(const Arg *arg);

/* Popup tracking structure for proper constraint handling */
typedef struct {
	struct wlr_xdg_popup *popup;
	struct wlr_scene_tree *root;
	struct wl_listener commit;
	struct wl_listener reposition;
	struct wl_listener destroy;
} Popup;

/* forward declarations */
void applybounds(Client *c, struct wlr_box *bbox);
void arrange(Monitor *m);
unsigned int get_border_width(void);
const float *get_focuscolor(void);
const float *get_bordercolor(void);
const float *get_urgentcolor(void);
void initialcommitnotify(struct wl_listener *listener, void *data);
void commitnotify(struct wl_listener *listener, void *data);
void commitpopup(struct wl_listener *listener, void *data);
void createdecoration(struct wl_listener *listener, void *data);
void createnotify(struct wl_listener *listener, void *data);
void createpopup(struct wl_listener *listener, void *data);
void destroydecoration(struct wl_listener *listener, void *data);
void destroynotify(struct wl_listener *listener, void *data);
void destroypopup(struct wl_listener *listener, void *data);
void fullscreennotify(struct wl_listener *listener, void *data);
void killclient(const Arg *arg);
void mapnotify(struct wl_listener *listener, void *data);
void maximizenotify(struct wl_listener *listener, void *data);
void popup_unconstrain(Popup *p);
void repositionpopup(struct wl_listener *listener, void *data);
void requestdecorationmode(struct wl_listener *listener, void *data);
void resize(Client *c, struct wlr_box geo, int interact);
void apply_geometry_to_wlroots(Client *c);
void client_remove_all_listeners(client_t *c);
void client_reregister_listeners(client_t *c);
void setfullscreen(Client *c, int fullscreen);
void setmon(Client *c, Monitor *m, uint32_t newtags);
void swapstack(const Arg *arg);
void tagmon(const Arg *arg);
void togglefloating(const Arg *arg);
void unmapnotify(struct wl_listener *listener, void *data);
void updatetitle(struct wl_listener *listener, void *data);
void zoom(const Arg *arg);
void sync_tiling_reorder(Client *c);

/* listener structs */
struct wl_listener new_xdg_toplevel = {.notify = createnotify};
struct wl_listener new_xdg_popup = {.notify = createpopup};
struct wl_listener new_xdg_decoration = {.notify = createdecoration};

void
applybounds(Client *c, struct wlr_box *bbox)
{
	/* Minimum geometry must fit borders AND titlebars with at least 1px content */
	int min_w = 1 + 2 * (int)c->bw
		+ c->titlebar[CLIENT_TITLEBAR_LEFT].size
		+ c->titlebar[CLIENT_TITLEBAR_RIGHT].size;
	int min_h = 1 + 2 * (int)c->bw
		+ c->titlebar[CLIENT_TITLEBAR_TOP].size
		+ c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
	c->geometry.width = MAX(min_w, c->geometry.width);
	c->geometry.height = MAX(min_h, c->geometry.height);

	if (c->geometry.x >= bbox->x + bbox->width)
		c->geometry.x = bbox->x + bbox->width - c->geometry.width;
	if (c->geometry.y >= bbox->y + bbox->height)
		c->geometry.y = bbox->y + bbox->height - c->geometry.height;
	if (c->geometry.x + c->geometry.width <= bbox->x)
		c->geometry.x = bbox->x;
	if (c->geometry.y + c->geometry.height <= bbox->y)
		c->geometry.y = bbox->y;
}

/* Synchronize tiling order change (zoom operation) */
void
sync_tiling_reorder(Client *c)
{
	/* Safety check: if arrays not initialized yet, skip sync */
	if (!globalconf.clients.tab) {
		return;
	}

	/* Remove from current position in clients list */
	foreach(elem, globalconf.clients) {
		if (*elem == c) {
			client_array_remove(&globalconf.clients, elem);
			break;
		}
	}

	/* Add to front of clients list (push = insert at position 0) */
	client_array_push(&globalconf.clients, c);

}

void
arrange(Monitor *m)
{
	lua_State *L;
	screen_t *screen;
	Client *c;

	if (!m || !m->wlr_output->enabled)
		return;

	/* Get Lua state */
	L = globalconf_get_lua_State();
	if (!L)
		return;

	/* WAYLAND-SPECIFIC: Always update scene node visibility, even during initialization.
	 * Unlike X11 where windows are visible by default, Wayland scene nodes start disabled.
	 * This MUST run before any early returns to ensure clients become visible. */
	foreach(client, globalconf.clients) {
		bool visible;
		c = *client;
		if (!c->mon || c->mon != m || !c->scene)
			continue;

		visible = client_isvisible(c);
		wlr_scene_node_set_enabled(&c->scene->node, visible);
		client_set_suspended(c, !visible);
	}

	/* Safety check: if not initialized yet, skip Lua arrange but scene nodes are already updated */
	if (!globalconf.screens.tab) {
		return;
	}

	/* Find screen_t for this Monitor */
	screen = luaA_screen_get_by_monitor(L, m);
	if (!screen || !screen->valid) {
		return;
	}

	/* Call awful.layout.arrange(screen) in Lua */
	lua_getglobal(L, "awful");        /* Get awful module */
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		goto fallback;
	}

	lua_getfield(L, -1, "layout");    /* Get awful.layout */
	if (!lua_istable(L, -1)) {
		lua_pop(L, 2);
		goto fallback;
	}

	lua_getfield(L, -1, "arrange");   /* Get awful.layout.arrange */
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 3);
		goto fallback;
	}

	/* Push screen as argument */
	luaA_object_push(L, screen);

	/* Call awful.layout.arrange(screen) */
	if (lua_pcall(L, 1, 0, 0) != 0) {
		lua_pop(L, 1);
	}

	/* Clean up stack */
	lua_pop(L, 2);  /* Pop layout and awful */

fallback:
	/* Scene node visibility already updated at function start (Wayland-specific requirement) */

	/* Update fullscreen background */
	c = focustop(m);
	wlr_scene_node_set_enabled(&m->fullscreen_bg->node,
		c && c->fullscreen);

	motionnotify(0, NULL, 0, 0, 0, 0);
	some_recompute_idle_inhibit(NULL);
}

/* Handle initial XDG commit - sets scale, capabilities, size.
 * This listener is registered in createnotify before wlr_scene_xdg_surface_create. */
void
initialcommitnotify(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, initial_commit);
	Monitor *m;

	if (!c->surface.xdg || !c->surface.xdg->initial_commit)
		return;

	/* Get the monitor this client will be rendered on for initial scale setting.
	 * Final monitor/tags will be determined by Lua rules in mapnotify(). */
	m = c->mon ? c->mon : selmon;
	if (m) {
		client_set_scale(client_surface(c), m->wlr_output->scale);
	}

	wlr_xdg_toplevel_set_wm_capabilities(c->surface.xdg->toplevel,
			WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN);
	if (c->decoration)
		requestdecorationmode(&c->set_decoration_mode, c->decoration);
	if (m && !client_is_unmanaged(c) && !client_is_float_type(c)) {
		wlr_xdg_toplevel_set_size(c->surface.xdg->toplevel,
			m->w.width - 2 * c->bw, m->w.height - 2 * c->bw);
	} else {
		wlr_xdg_toplevel_set_size(c->surface.xdg->toplevel, 0, 0);
	}
}

/* Handle subsequent XDG commits - resizing and opacity.
 * This listener is registered in mapnotify AFTER wlr_scene_xdg_surface_create
 * so it fires AFTER wlroots' internal surface_reconfigure() which resets opacity. */
void
commitnotify(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, commit);

	/* Skip initial commit - handled by initialcommitnotify */
	if (c->surface.xdg->initial_commit)
		return;

	/* Only call resize() for floating or fullscreen clients.
	 * Tiled clients have their geometry managed by the Lua layout engine,
	 * which may intentionally position clients offscreen (e.g. carousel
	 * layout). resize() calls applybounds() which would clamp offscreen
	 * clients back to the monitor workarea. For tiled clients, call
	 * apply_geometry_to_wlroots() directly to update clip, borders, scene
	 * position, and re-send the configure event without clamping. */
	if (some_client_get_floating(c) || c->fullscreen) {
		resize(c, c->geometry, (some_client_get_floating(c) && !c->fullscreen));
	} else {
		/* Send toplevel bounds so wlroots schedules a configure that
		 * carries the pending size. Without this, slow-to-resize clients
		 * (e.g. Ghostty) may never get a re-configure after a screen
		 * change because client_set_size() is gated by !c->resize. */
		client_set_bounds(c, c->geometry.width, c->geometry.height);
		apply_geometry_to_wlroots(c);
	}

	/* mark a pending resize as completed */
	if (c->resize) {
		if (c->resize <= c->surface.xdg->current.configure_serial) {
			c->resize = 0;
		}
	}

	/* Re-apply opacity after wlroots' surface_reconfigure() resets it to 1.0.
	 * Our listener fires after wlroots' because we registered it after
	 * wlr_scene_xdg_surface_create() in mapnotify(). */
	if (c->opacity >= 0)
		client_apply_opacity_to_scene(c, (float)c->opacity);
}

/* Unconstrain popup using proper scene node coordinates (River pattern) */
void
popup_unconstrain(Popup *p)
{
	LayerSurface *l = NULL;
	Client *c = NULL;
	struct wlr_box box;
	int root_lx, root_ly;
	int type;

	if (!p->root)
		return;

	type = toplevel_from_wlr_surface(p->popup->base->surface, &c, &l);
	if (type < 0)
		return;

	/* Get the output box */
	if (type == LayerShell) {
		if (!l || !l->mon)
			return;
		box = l->mon->m;
	} else {
		if (!c || !c->mon)
			return;
		box = c->mon->w;
	}

	/* Get global coordinates of the popup root scene tree */
	if (!wlr_scene_node_coords(&p->root->node, &root_lx, &root_ly))
		return;

	/* Convert output box to popup-relative coordinates */
	box.x -= root_lx;
	box.y -= root_ly;

	wlr_xdg_popup_unconstrain_from_box(p->popup, &box);
}

void
repositionpopup(struct wl_listener *listener, void *data)
{
	Popup *p = wl_container_of(listener, p, reposition);
	popup_unconstrain(p);
}

void
destroypopup(struct wl_listener *listener, void *data)
{
	Popup *p = wl_container_of(listener, p, destroy);
	wl_list_remove(&p->commit.link);
	wl_list_remove(&p->reposition.link);
	wl_list_remove(&p->destroy.link);
	free(p);
}

void
commitpopup(struct wl_listener *listener, void *data)
{
	Popup *p = wl_container_of(listener, p, commit);
	LayerSurface *l = NULL;
	Client *c = NULL;
	int type;

	if (!p->popup->base->initial_commit)
		return;

	type = toplevel_from_wlr_surface(p->popup->base->surface, &c, &l);
	if (!p->popup->parent || type < 0)
		return;

	/* Create scene surface for popup */
	p->popup->base->surface->data = wlr_scene_xdg_surface_create(
			p->popup->parent->data, p->popup->base);

	if ((l && !l->mon) || (c && !c->mon)) {
		wlr_xdg_popup_destroy(p->popup);
		return;
	}

	/* Set root scene tree for coordinate calculation */
	p->root = (type == LayerShell) ? l->popups : c->scene_surface;

	/* Apply initial constraint */
	popup_unconstrain(p);
}

void
createdecoration(struct wl_listener *listener, void *data)
{
	struct wlr_xdg_toplevel_decoration_v1 *deco = data;
	Client *c = deco->toplevel->base->data;
	c->decoration = deco;

	LISTEN(&deco->events.request_mode, &c->set_decoration_mode, requestdecorationmode);
	LISTEN(&deco->events.destroy, &c->destroy_decoration, destroydecoration);

	requestdecorationmode(&c->set_decoration_mode, deco);
}

void
createnotify(struct wl_listener *listener, void *data)
{
	/* This event is raised when a client creates a new toplevel (application window).
	 *
	 * This function follows AwesomeWM's client_manage() pattern (first half):
	 * 1. Create Lua client object with client_new(L)
	 * 2. Link to protocol surface (Wayland XDG shell vs X11 window)
	 * 3. Register protocol event listeners
	 * 4. Add client to global clients array
	 * 5. Emit client::list signal
	 * 6. DO NOT emit manage signal yet - that happens in mapnotify()
	 */
	struct wlr_xdg_toplevel *toplevel = data;
	Client *c = NULL;
	lua_State *L;

	L = globalconf_get_lua_State();

	/* Create Lua client object (matches AwesomeWM client_manage line 2138) */
	c = client_new(L);
	/* client_new() leaves the client on the Lua stack at index -1 */

	/* Assign unique client ID (Sway-style incrementing counter) */
	c->id = next_client_id++;

	/* Initialize opacity to -1 (unset) so commitnotify doesn't apply 0% opacity.
	 * -1 means "use default" (fully opaque). 0 would mean fully transparent. */
	c->opacity = -1;

	/* Link to Wayland surface (adapts X11 window linkage to Wayland) */
	toplevel->base->data = c;
	c->surface.xdg = toplevel->base;
	c->client_type = XDGShell;
	c->bw = get_border_width();

	/* Register Wayland event listeners (adapts X11 event masks to Wayland signals)
	 * Note: The main commit listener is registered in mapnotify() AFTER wlr_scene_xdg_surface_create()
	 * so our listener fires AFTER wlroots' internal surface_reconfigure() which resets opacity.
	 * We use a separate listener for the initial commit to handle pre-map setup. */
	LISTEN(&toplevel->base->surface->events.commit, &c->initial_commit, initialcommitnotify);
	LISTEN(&toplevel->base->surface->events.map, &c->map, mapnotify);
	LISTEN(&toplevel->base->surface->events.unmap, &c->unmap, unmapnotify);
	LISTEN(&toplevel->events.destroy, &c->destroy, destroynotify);
	LISTEN(&toplevel->events.request_fullscreen, &c->request_fullscreen, fullscreennotify);
	LISTEN(&toplevel->events.request_maximize, &c->maximize, maximizenotify);
	LISTEN(&toplevel->events.set_title, &c->set_title, updatetitle);

	/* Note: property_register_wayland_listeners() is called in mapnotify() after
	 * the client is fully registered in Lua. Calling it here would fail because
	 * luaA_object_push() can't find the client reference yet. */

	/* Add to global clients array (matches AwesomeWM client_manage line 2202)
	 * Duplicate client on stack, then take a reference for the array */
	lua_pushvalue(L, -1);
	client_array_push(&globalconf.clients, luaA_object_ref(L, -1));

	/* Add to stack (matches AwesomeWM client_manage) */
	stack_client_push(c);

	/* Emit client::list signal (matches AwesomeWM line 2266) */
	luaA_class_emit_signal(L, &client_class, "list", 0);

	/* Keep client on Lua stack - it will be used by mapnotify() later
	 * DO NOT emit manage signal here - AwesomeWM emits it at end of client_manage,
	 * which corresponds to our mapnotify() event (when the window is actually mapped) */
	lua_pop(L, 1);
}

void
createpopup(struct wl_listener *listener, void *data)
{
	/* This event is raised when a client (either xdg-shell or layer-shell)
	 * creates a new popup. */
	struct wlr_xdg_popup *popup = data;
	Popup *p = ecalloc(1, sizeof(*p));

	p->popup = popup;
	p->root = NULL;  /* Set in commitpopup after finding toplevel */

	LISTEN(&popup->base->surface->events.commit, &p->commit, commitpopup);
	LISTEN(&popup->events.reposition, &p->reposition, repositionpopup);
	LISTEN(&popup->events.destroy, &p->destroy, destroypopup);
}

void
destroydecoration(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, destroy_decoration);

	wl_list_remove(&c->destroy_decoration.link);
	wl_list_remove(&c->set_decoration_mode.link);
	c->decoration = NULL;
}

/** Remove all wl_listeners from a client.
 * Extracted from destroynotify's cleanup path. Handles XDG vs XWayland,
 * mapped vs unmapped states, decoration, and foreign_toplevel listeners.
 * Used by hot-reload to detach clients from wlroots signals before Lua GC.
 */
void
client_remove_all_listeners(client_t *c)
{
	wl_list_remove(&c->destroy.link);
	wl_list_remove(&c->set_title.link);
	wl_list_remove(&c->request_fullscreen.link);
#ifdef XWAYLAND
	if (c->client_type != XDGShell) {
		wl_list_remove(&c->activate.link);
		wl_list_remove(&c->associate.link);
		wl_list_remove(&c->configure.link);
		wl_list_remove(&c->dissociate.link);
		wl_list_remove(&c->set_hints.link);
		/* If associate was called, map/unmap listeners need cleanup */
		if (c->map.link.prev && c->map.link.next) {
			wl_list_remove(&c->map.link);
			wl_list_remove(&c->unmap.link);
		}
	} else
#endif
	{
		wl_list_remove(&c->initial_commit.link);
		/* commit.link is removed in unmapnotify for XDG clients.
		 * Only remove here if unmapnotify didn't run (c->scene still set). */
		if (c->scene) {
			wl_list_remove(&c->commit.link);
		}
		wl_list_remove(&c->map.link);
		wl_list_remove(&c->unmap.link);
		wl_list_remove(&c->maximize.link);
	}
	/* Clean up foreign toplevel handle if not already done by unmapnotify */
	if (c->toplevel_handle) {
		wl_list_remove(&c->foreign_request_activate.link);
		wl_list_remove(&c->foreign_request_close.link);
		wl_list_remove(&c->foreign_request_fullscreen.link);
		wl_list_remove(&c->foreign_request_maximize.link);
		wl_list_remove(&c->foreign_request_minimize.link);
		wlr_foreign_toplevel_handle_v1_destroy(c->toplevel_handle);
		c->toplevel_handle = NULL;
	}
	/* Clean up decoration listeners if decoration exists */
	if (c->decoration) {
		wl_list_remove(&c->set_decoration_mode.link);
		wl_list_remove(&c->destroy_decoration.link);
		c->decoration = NULL;
	}
}

/** Re-register all wl_listeners for a client after hot-reload.
 * Called after Lua state is rebuilt. Registers the appropriate set of listeners
 * based on client type (XDG vs XWayland) and mapped state (scene != NULL).
 *
 * For mapped clients: registers the "already mapped" listener set (commit, not
 * initial_commit; plus foreign_toplevel and decoration listeners).
 * For unmapped clients: registers the "pre-map" listener set matching
 * createnotify/createnotifyx11.
 */
void
client_reregister_listeners(client_t *c)
{
#ifdef XWAYLAND
	if (c->client_type != XDGShell) {
		struct wlr_xwayland_surface *xsurface = c->surface.xwayland;

		/* Core X11 listeners (from createnotifyx11) */
		LISTEN(&xsurface->events.associate, &c->associate, associatex11);
		LISTEN(&xsurface->events.destroy, &c->destroy, destroynotify);
		LISTEN(&xsurface->events.dissociate, &c->dissociate, dissociatex11);
		LISTEN(&xsurface->events.request_activate, &c->activate, activatex11);
		LISTEN(&xsurface->events.request_configure, &c->configure, configurex11);
		LISTEN(&xsurface->events.request_fullscreen, &c->request_fullscreen, fullscreennotify);
		LISTEN(&xsurface->events.set_hints, &c->set_hints, sethints);
		LISTEN(&xsurface->events.set_title, &c->set_title, updatetitle);

		/* If mapped (has surface association), register map/unmap */
		if (c->scene && xsurface->surface) {
			LISTEN(&xsurface->surface->events.map, &c->map, mapnotify);
			LISTEN(&xsurface->surface->events.unmap, &c->unmap, unmapnotify);
		}
	} else
#endif
	{
		struct wlr_xdg_toplevel *toplevel = c->surface.xdg->toplevel;

		/* Core XDG listeners (from createnotify) */
		LISTEN(&toplevel->events.destroy, &c->destroy, destroynotify);
		LISTEN(&toplevel->events.request_fullscreen, &c->request_fullscreen, fullscreennotify);
		LISTEN(&toplevel->events.request_maximize, &c->maximize, maximizenotify);
		LISTEN(&toplevel->events.set_title, &c->set_title, updatetitle);

		if (c->scene) {
			/* Mapped: register commit (not initial_commit, since already mapped).
			 * Initialize initial_commit.link so client_remove_all_listeners
			 * can safely call wl_list_remove on it during consecutive reloads. */
			LISTEN(&c->surface.xdg->surface->events.commit, &c->commit, commitnotify);
			LISTEN(&c->surface.xdg->surface->events.map, &c->map, mapnotify);
			LISTEN(&c->surface.xdg->surface->events.unmap, &c->unmap, unmapnotify);
			wl_list_init(&c->initial_commit.link);
		} else {
			/* Unmapped: register initial_commit + map/unmap (from createnotify) */
			LISTEN(&c->surface.xdg->surface->events.commit, &c->initial_commit, initialcommitnotify);
			LISTEN(&c->surface.xdg->surface->events.map, &c->map, mapnotify);
			LISTEN(&c->surface.xdg->surface->events.unmap, &c->unmap, unmapnotify);
			wl_list_init(&c->commit.link);
		}
	}

	/* Note: foreign_toplevel_handle was destroyed by client_remove_all_listeners().
	 * A new handle is created during mapnotify's manage sequence in hot-reload
	 * phase F, so we do NOT recreate it here. c->toplevel_handle is NULL. */

	/* Re-register decoration listeners if decoration still exists */
	if (c->decoration) {
		LISTEN(&c->decoration->events.request_mode, &c->set_decoration_mode, requestdecorationmode);
		LISTEN(&c->decoration->events.destroy, &c->destroy_decoration, destroydecoration);
	}
}

void
destroynotify(struct wl_listener *listener, void *data)
{
	/* Called when the xdg_toplevel is destroyed. */
	Client *c = wl_container_of(listener, c, destroy);
	bool already_unmanaged;
	int i;


	/* Safety: If Lua state destroyed during cleanup, skip client_unmanage()
	 * which emits signals. This should never happen with correct cleanup
	 * order, but guards against race conditions. */
	if (!globalconf_L) {
		/* Minimal cleanup: remove listeners only */
		client_remove_all_listeners(c);
		return;  /* Skip client_unmanage() */
	}

	/* client_unmanage() will handle invalidation at the proper time (AFTER signals are emitted).
	 * This matches AwesomeWM's pattern where c->window = XCB_NONE happens at the END of client_unmanage(). */

	/* Check if client is still in the clients array.
	 * For normal lifecycle: unmap -> unmapnotify calls client_unmanage -> destroy -> destroynotify (skip unmanage).
	 * For edge case: destroy without unmap -> client still in array, destroynotify must call client_unmanage. */
	already_unmanaged = true;
	for (i = 0; i < globalconf.clients.len; i++) {
		if (globalconf.clients.tab[i] == c) {
			already_unmanaged = false;  /* Found in array = NOT yet unmanaged */
			break;
		}
	}

	if (already_unmanaged) {
		/* Client already removed from array by unmapnotify, skip client_unmanage.
		 * For XWayland clients, client_unmanage(UNMAP) kept the Lua reference
		 * alive to allow re-mapping.  Release it now. */
#ifdef XWAYLAND
		if (c->client_type == X11) {
			lua_State *L = globalconf_get_lua_State();
			luaA_object_unref(L, c);
		}
#endif
	} else {
		/* Edge case: client still in array (destroyed without unmap), need to unmanage */
		client_unmanage(c, CLIENT_UNMANAGE_DESTROYED);
	}

	/* Clean up Wayland-specific listeners (not handled by client_unmanage) */
	client_remove_all_listeners(c);

	/* Note: Do NOT free(c) or metadata here - client_unmanage() called luaA_object_unref(),
	 * Lua GC will call client_wipe() to free metadata and eventually free(c).
	 * Manual free() bypasses Lua ref counting and causes use-after-free bugs. */
}

void
fullscreennotify(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, request_fullscreen);
	/* Guard against stale XWayland client after client_unmanage() */
	if (c->client_type == X11 && c->window == XCB_NONE)
		return;
	setfullscreen(c, client_wants_fullscreen(c));
}

/* ========== APPEARANCE HELPER FUNCTIONS ========== */
/* These functions read appearance settings from beautiful.* (Lua theme system)
 * with fallbacks to globalconf defaults. This achieves AwesomeWM compatibility:
 * themes can customize appearance without recompiling C code. */

/** Get border width from beautiful.border_width or globalconf default */
unsigned int
get_border_width(void)
{
	lua_State *L = globalconf_get_lua_State();
	if (!L) return globalconf.appearance.border_width;

	/* Use require() to get beautiful module (it's typically local, not global) */
	lua_getglobal(L, "require");
	lua_pushstring(L, "beautiful");
	if (lua_pcall(L, 1, 1, 0) != 0) {
		lua_pop(L, 1);
		return globalconf.appearance.border_width;
	}
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "border_width");
		if (lua_isnumber(L, -1)) {
			unsigned int val = lua_tointeger(L, -1);
			lua_pop(L, 2);
			return val;
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	return globalconf.appearance.border_width;
}

/** Get focus color from beautiful.border_focus or globalconf default */
const float *
get_focuscolor(void)
{
	/* TODO: Add beautiful.border_focus parsing (hex string to RGBA)
	 * For now, just return globalconf default */
	return globalconf.appearance.focuscolor;
}

/** Get border color from beautiful.border_normal or globalconf default */
const float *
get_bordercolor(void)
{
	/* TODO: Add beautiful.border_normal parsing (hex string to RGBA)
	 * For now, just return globalconf default */
	return globalconf.appearance.bordercolor;
}

/** Get urgent color from beautiful.border_urgent or globalconf default */
const float *
get_urgentcolor(void)
{
	/* TODO: Add beautiful.border_urgent parsing (hex string to RGBA)
	 * For now, just return globalconf default */
	return globalconf.appearance.urgentcolor;
}

void
killclient(const Arg *arg)
{
	Client *sel = focustop(selmon);
	if (sel)
		client_send_close(sel);
}

void
mapnotify(struct wl_listener *listener, void *data)
{
	/* Called when the surface is mapped, or ready to display on-screen. */
	Client *p = NULL;
	Client *w, *c = wl_container_of(listener, c, map);
	Monitor *m;
	int i;
	lua_State *L;
	tag_t *tag;

	/* Create scene tree for this client and its border */
	c->scene = client_surface(c)->data = wlr_scene_tree_create(layers[LyrTile]);
	/* Enabled later by a call to arrange() */
	wlr_scene_node_set_enabled(&c->scene->node, client_is_unmanaged(c));
	c->scene_surface = c->client_type == XDGShell
			? wlr_scene_xdg_surface_create(c->scene, c->surface.xdg)
			: wlr_scene_subsurface_tree_create(c->scene, client_surface(c));

	/* Handle scene surface creation failure (can happen with XWayland/Electron apps) */
	if (!c->scene_surface) {
		warn("Failed to create scene surface for client (type=%d)", c->client_type);
		wlr_scene_node_destroy(&c->scene->node);
		c->scene = NULL;
		client_surface(c)->data = NULL;
		return;
	}

	c->scene->node.data = c->scene_surface->node.data = c;

	/* Register commit listener AFTER wlr_scene_xdg_surface_create() so our listener
	 * fires AFTER wlroots' internal surface_reconfigure() which resets opacity to 1.0.
	 * This allows our compositor-controlled opacity to take effect.
	 * Only for XDG clients - commitnotify references XDG-specific fields.
	 * XWayland uses configurex11 for resize, not commits. */
	if (c->client_type == XDGShell) {
		LISTEN(&client_surface(c)->events.commit, &c->commit, commitnotify);
	}

	client_get_geometry(c, &c->geometry);

#ifdef XWAYLAND
	/* Re-manage XWayland clients that were previously unmapped (e.g., Discord
	 * close-to-tray then re-open).  client_unmanage(UNMAP) removed the client
	 * from arrays and invalidated window, but kept the Lua reference alive.
	 * Restore the client to a manageable state before proceeding. */
	if (c->client_type == X11 && c->window == XCB_NONE) {
		c->window = c->surface.xwayland->window_id;
		c->bw = client_is_unmanaged(c) ? 0 : get_border_width();
		client_array_push(&globalconf.clients, c);
		stack_client_push(c);
		luaA_class_emit_signal(globalconf_get_lua_State(),
			&client_class, "list", 0);
	}
#endif

	/* Handle unmanaged clients first so we can return prior create borders */
	if (client_is_unmanaged(c)) {
		/* Unmanaged clients always are floating */
		wlr_scene_node_reparent(&c->scene->node, layers[LyrFloat]);
		wlr_scene_node_set_position(&c->scene->node, c->geometry.x, c->geometry.y);
		client_set_size(c, c->geometry.width, c->geometry.height);
		if (client_wants_focus(c)) {
			focusclient(c, 1);
			exclusive_focus = c;
		}
		goto unset_fullscreen;
	}

	for (i = 0; i < 4; i++) {
		c->border[i] = wlr_scene_rect_create(c->scene, 0, 0,
				c->urgent ? get_urgentcolor() : get_bordercolor());
		c->border[i]->node.data = c;
	}

	/* Create shadow (compositor-level, replaces picom shadows) */
	{
		const shadow_config_t *shadow_config = shadow_get_effective_config(
			c->shadow_config, false);
		if (shadow_config && shadow_config->enabled) {
			shadow_create(c->scene, &c->shadow, shadow_config,
				c->geometry.width, c->geometry.height);
		}
	}

	/* Create foreign toplevel handle for external tools (rofi, taskbars, etc.) */
	if (foreign_toplevel_mgr) {
		c->toplevel_handle = wlr_foreign_toplevel_handle_v1_create(foreign_toplevel_mgr);
		if (c->toplevel_handle) {
			const char *title = client_get_title(c);
			const char *app_id = client_get_appid(c);
			if (title)
				wlr_foreign_toplevel_handle_v1_set_title(c->toplevel_handle, title);
			if (app_id)
				wlr_foreign_toplevel_handle_v1_set_app_id(c->toplevel_handle, app_id);
			wlr_foreign_toplevel_handle_v1_set_maximized(c->toplevel_handle, c->maximized);
			wlr_foreign_toplevel_handle_v1_set_minimized(c->toplevel_handle, c->minimized);
			wlr_foreign_toplevel_handle_v1_set_fullscreen(c->toplevel_handle, c->fullscreen);
			if (c->mon && c->mon->wlr_output)
				wlr_foreign_toplevel_handle_v1_output_enter(c->toplevel_handle, c->mon->wlr_output);
			LISTEN(&c->toplevel_handle->events.request_activate, &c->foreign_request_activate, foreign_toplevel_request_activate);
			LISTEN(&c->toplevel_handle->events.request_close, &c->foreign_request_close, foreign_toplevel_request_close);
			LISTEN(&c->toplevel_handle->events.request_fullscreen, &c->foreign_request_fullscreen, foreign_toplevel_request_fullscreen);
			LISTEN(&c->toplevel_handle->events.request_maximize, &c->foreign_request_maximize, foreign_toplevel_request_maximize);
			LISTEN(&c->toplevel_handle->events.request_minimize, &c->foreign_request_minimize, foreign_toplevel_request_minimize);
		}
	}

	/* Initialize client geometry with room for border */
	c->geometry.width += 2 * c->bw;
	c->geometry.height += 2 * c->bw;

	/* Client was already added to arrays in createnotify() (matches AwesomeWM pattern)
	 * No need to add again here - doing so would create duplicates */

	/* Set initial monitor, tags, floating status, and focus:
	 * we always consider floating, clients that have parent and thus
	 * we set the same tags and monitor as its parent.
	 * If there is no parent, apply rules */
	if ((p = client_get_parent(c))) {

		/* Fetch initial properties using new property system.
		 * This calls client_set_*() which emits property::* signals on the client object.
		 * Both Wayland and XWayland use proper signal emission now. */
		if (c->client_type == XDGShell) {
			property_register_wayland_listeners(c);
		}
#ifdef XWAYLAND
		else {
			property_update_xwayland_properties(c);
		}
#endif

		/* Wayland transient windows should be treated as dialogs.
		 * XDG shell doesn't have explicit window type hints like X11's _NET_WM_WINDOW_TYPE,
		 * so we infer dialog type from the transient_for relationship.
		 * This makes Lua's update_implicitly_floating() detect them as floating,
		 * allowing user placement code in request::manage to work correctly. */
		c->type = WINDOW_TYPE_DIALOG;

		/* Set transient_for so Lua code can access c.transient_for property.
		 * This is needed for placement rules like awful.placement.centered(c, {parent = c.transient_for}) */
		L = globalconf_get_lua_State();
		luaA_object_push(L, c);
		client_set_transient_for(L, -1, p);
		lua_pop(L, 1);

		/* Copy tags from parent client (array-based)
		 * Note: Floating is managed by Lua property system now.
		 * Transient/dialog windows are detected via update_implicitly_floating() */

		/* Tag child with all tags that parent is tagged with */
		for (i = 0; i < globalconf.tags.len; i++) {
			tag = globalconf.tags.tab[i];
			if (is_client_tagged(p, tag)) {
				luaA_object_push(L, tag);
				tag_client(L, c);
			}
		}

		/* c->tags removed - tags managed by arrays */

		/* Set monitor (setmon will handle resize, arrange, etc.) */
		setmon(c, p->mon, 0);

		/* Emit property and manage signals for transient clients too.
		 * This is needed for Lua rules and placement code to work. */
		luaA_object_push(L, c);
		luaA_object_emit_signal(L, -1, "property::x", 0);
		luaA_object_emit_signal(L, -1, "property::y", 0);
		luaA_object_emit_signal(L, -1, "property::width", 0);
		luaA_object_emit_signal(L, -1, "property::height", 0);
		luaA_object_emit_signal(L, -1, "property::geometry", 0);
		luaA_object_emit_signal(L, -1, "property::type", 0);

		lua_pushstring(L, "new");
		lua_newtable(L);
		luaA_object_emit_signal(L, -3, "request::manage", 2);
		luaA_object_emit_signal(L, -1, "manage", 0);
		lua_pop(L, 1);

		/* Apply geometry BEFORE enabling scene node to send configure event.
		 * Fixes Firefox tiling issue (#10).
		 * Reset c->resize to force re-send configure even if setmon()->resize()
		 * already sent one (unflushed). This ensures the configure is flushed
		 * before we enable the scene node. */
		c->resize = 0;
		apply_geometry_to_wlroots(c);
		wl_display_flush_clients(dpy);

		/* Enable scene node for transient client */
		if (client_on_selected_tags(c)) {
			wlr_scene_node_set_enabled(&c->scene->node, true);
		}
	} else {
		Monitor *target_mon;
		screen_t *target_screen;

		/* Apply rules via Lua awful.rules system (AwesomeWM pattern) */
		L = globalconf_get_lua_State();

		/* Fetch initial properties using new property system.
		 * This calls client_set_*() which emits property::* signals on the client object.
		 * Both Wayland and XWayland use proper signal emission now. */
		if (c->client_type == XDGShell) {
			property_register_wayland_listeners(c);
		}
#ifdef XWAYLAND
		else {
			property_update_xwayland_properties(c);
		}
#endif

		/* Initialize the window type after property fetch.
		 * For native Wayland clients, infer dialog-like float types from the XDG
		 * parent/size constraints so Lua can treat them as implicitly floating.
		 * For XWayland clients, keep the type established by X11 properties. */
		if (c->client_type == XDGShell)
			c->type = client_is_float_type(c) ? WINDOW_TYPE_DIALOG : WINDOW_TYPE_NORMAL;

		/* Determine target monitor (but don't set c->mon yet - setmon() needs to do that) */
		target_mon = xytomon(c->geometry.x, c->geometry.y);
		if (!target_mon)
			target_mon = selmon;
		target_screen = luaA_screen_get_by_monitor(L, target_mon);

		/* Set default tags BEFORE emitting manage signal (AwesomeWM pattern)
		 * Tag client with all currently selected tags on the target monitor.
		 * Lua rules can then modify this via tag_client()/untag_client() calls. */
		for (i = 0; i < globalconf.tags.len; i++) {
			tag = globalconf.tags.tab[i];
			/* Check if tag is selected using array system */
			if (tag->selected && tag->screen == target_screen) {
				/* Push tag to Lua stack */
				luaA_object_push(L, tag);
				/* Tag the client (pops tag from stack, takes reference) */
				tag_client(L, c);
			}
		}

		/* c->tags removed - tags managed by arrays */

		/* Set the client's monitor BEFORE emitting signals (matches AwesomeWM line 2206).
		 * This ensures the client has a screen when signal handlers run. */
		target_mon = c->mon ? c->mon : xytomon(c->geometry.x, c->geometry.y);
		if (!target_mon)
			target_mon = selmon;
		setmon(c, target_mon, 0);

		/* Push client to Lua stack for signal emission */
		luaA_object_push(L, c);

		/* Emit property signals (matches AwesomeWM client_manage lines 2215-2228)
		 * These notify Lua code that initial client properties are set */
		luaA_object_emit_signal(L, -1, "property::x", 0);
		luaA_object_emit_signal(L, -1, "property::y", 0);
		luaA_object_emit_signal(L, -1, "property::width", 0);
		luaA_object_emit_signal(L, -1, "property::height", 0);
		luaA_object_emit_signal(L, -1, "property::window", 0);
		luaA_object_emit_signal(L, -1, "property::geometry", 0);
		luaA_object_emit_signal(L, -1, "property::size_hints_honor", 0);
		luaA_object_emit_signal(L, -1, "property::type", 0);

		/* Emit request::manage with context and hints (matches AwesomeWM line 2278)
		 * This is the modern AwesomeWM signal for client management */
		lua_pushstring(L, "new");  /* context */
		lua_newtable(L);            /* hints table (empty for now) */
		luaA_object_emit_signal(L, -3, "request::manage", 2);

		/* Emit legacy "manage" signal for backwards compatibility (matches AwesomeWM line 2281)
		 * Note: AwesomeWM comment says "TODO v6: remove this" */
		luaA_object_emit_signal(L, -1, "manage", 0);

#ifdef XWAYLAND
		/* For XWayland clients, emit request::activate to grant focus.
		 * Native Wayland clients use XDG activation protocol which triggers
		 * the urgent() handler. X11 clients don't have this mechanism, so
		 * we emit the signal here when they first map.
		 * This matches AwesomeWM behavior where new windows get focus. */
		if (c->client_type == X11) {
			/* Activate the XWayland surface BEFORE emitting request::activate.
			 * This initializes the XWayland machinery so keyboard focus can be set.
			 * Without this, the first XWayland client in a session won't get focus
			 * because the XWayland subsystem isn't "primed" yet. */
			wlr_xwayland_surface_activate(c->surface.xwayland, 1);

			lua_pushstring(L, "xwayland_map");  /* context */
			lua_newtable(L);  /* hints table */
			lua_pushboolean(L, true);
			lua_setfield(L, -2, "raise");
			luaA_object_emit_signal(L, -3, "request::activate", 2);
		}
#endif

		/* Pop client from Lua stack */
		lua_pop(L, 1);

		/* Force-run deferred layout arrange before applying geometry.
		 * awful.layout.arrange() (triggered by manage signals above) queues
		 * itself via timer.delayed_call(). Without running it now, c->geometry
		 * still holds the client's requested size (e.g. Firefox's saved 800x600)
		 * instead of the tiled geometry. The "refresh" signal triggers
		 * timer.run_delayed_calls_now() which executes the deferred arrange,
		 * updating c->geometry to the correct tiled dimensions.
		 * In X11/AwesomeWM this isn't needed because the WM sends ConfigureNotify
		 * before mapping. In Wayland, the client commits first, so we must
		 * ensure the tiled geometry is computed before we flush the configure. */
		luaA_emit_refresh();

		/* Apply geometry BEFORE enabling scene node to send configure event.
		 * Without this, client may render a frame at wrong size before receiving
		 * the tiled geometry configure event. Fixes Firefox tiling issue (#10).
		 * Reset c->resize to force re-send configure even if setmon()->resize()
		 * already sent one (unflushed). This ensures the configure is flushed
		 * before we enable the scene node. */
		c->resize = 0;
		apply_geometry_to_wlroots(c);

		/* Flush configure event to client immediately so it receives the tiled
		 * geometry before we make it visible. Without this, the configure is
		 * queued but not sent until the next poll cycle. */
		wl_display_flush_clients(dpy);

		/* Enable scene node for new client if on selected tags (Wayland-specific).
		 * Unlike AwesomeWM, we don't call arrange() here - that's triggered by Lua signals.
		 * We only need to make the client visible in the scene graph.
		 * AwesomeWM's client_manage() (objects/client.c:2278-2294) does NOT call arrange()
		 * after request::manage - layout is handled by the Lua signal system.
		 * Calling arrange() here would overwrite geometry set by Lua placement code. */
		if (client_on_selected_tags(c)) {
			wlr_scene_node_set_enabled(&c->scene->node, true);
		}
	}
	printstatus();

	/* Ensure keyboard focus is delivered now that the surface is mapped.
	 * focusclient() may have been called earlier (from Lua rules) when the
	 * surface wasn't ready yet, so keyboard enter was skipped. Re-send it
	 * now. This fixes games and clients that appear focused but don't
	 * receive keyboard input. */
	if (globalconf.focus.client == c && client_surface(c)) {
		/* Use same surface_ready logic as focusclient(): for XWayland
		 * clients, surface->mapped may be false even after map event,
		 * so check c->scene instead. */
		int ready;
#ifdef XWAYLAND
		if (c->client_type == X11)
			ready = (c->scene != NULL);
		else
#endif
			ready = client_surface(c)->mapped;
		if (ready && seat->keyboard_state.focused_surface != client_surface(c)) {
#ifdef XWAYLAND
			if (c->client_type == X11)
				wlr_xwayland_set_seat(xwayland, seat);
#endif
			struct wlr_keyboard *kb = wlr_seat_get_keyboard(seat);
			if (kb) {
				wlr_seat_keyboard_notify_enter(seat, client_surface(c),
					kb->keycodes, kb->num_keycodes, &kb->modifiers);
			} else {
				wlr_seat_keyboard_notify_enter(seat, client_surface(c),
					NULL, 0, NULL);
			}
		}
	}

unset_fullscreen:
	m = c->mon ? c->mon : xytomon(c->geometry.x, c->geometry.y);
	foreach(client, globalconf.clients) {
		w = *client;
		/* Use array-based tag overlap check */
		if (w != c && w != p && w->fullscreen && m == w->mon && clients_share_tags(w, c))
			setfullscreen(w, 0);
	}

	luaA_emit_signal_global("client::map");

	/* If cursor is within this new client's geometry, set pointer focus directly.
	 * Don't use motionnotify(0,...) because xytonode may not find the surface yet
	 * (buffer not committed) and would CLEAR pointer focus instead. */
	if (client_surface(c) && client_surface(c)->mapped
			&& cursor->x >= c->geometry.x && cursor->x < c->geometry.x + c->geometry.width
			&& cursor->y >= c->geometry.y && cursor->y < c->geometry.y + c->geometry.height) {
		double sx, sy;
		cursor_to_client_coordinates(c, &sx, &sy);
		wlr_log(WLR_DEBUG, "[POINTER-REEVAL] mapnotify: setting pointer focus on %s (cursor in geometry)",
			client_get_appid(c));
		pointerfocus(c, client_surface(c), sx, sy, 0);
	}
}

void
maximizenotify(struct wl_listener *listener, void *data)
{
	/* This event is raised when a client would like to maximize itself,
	 * typically because the user clicked on the maximize button on
	 * client-side decorations. somewm doesn't support maximization, but
	 * to conform to xdg-shell protocol we still must send a configure.
	 * Since xdg-shell protocol v5 we should ignore request of unsupported
	 * capabilities, just schedule a empty configure when the client uses <5
	 * protocol version
	 * wlr_xdg_surface_schedule_configure() is used to send an empty reply. */
	Client *c = wl_container_of(listener, c, maximize);
	if (c->surface.xdg->initialized
			&& wl_resource_get_version(c->surface.xdg->toplevel->resource)
					< XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION)
		wlr_xdg_surface_schedule_configure(c->surface.xdg);
}

void
requestdecorationmode(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, set_decoration_mode);
	if (c->surface.xdg->initialized)
		wlr_xdg_toplevel_decoration_v1_set_mode(c->decoration,
				WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

/* Apply geometry to wlroots scene graph - Wayland-specific rendering layer.
 * This function ONLY updates wlroots; it does NOT modify c->geometry or emit signals.
 * Called by resize() for interactive resize and client_resize_do() for Lua-initiated resize.
 */
void
apply_geometry_to_wlroots(Client *c)
{
	struct wlr_box clip;
	int titlebar_left, titlebar_top;

	if (!c->scene || !client_surface(c) || !client_surface(c)->mapped)
		return;

	/* Get titlebar sizes - they occupy space inside geometry.
	 * When fullscreen, ignore titlebar sizes - surface should cover entire geometry. */
	titlebar_left = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_LEFT].size;
	titlebar_top = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_TOP].size;

	/* Update scene-graph position and borders */
	wlr_scene_node_set_position(&c->scene->node, c->geometry.x, c->geometry.y);
	/* Offset scene_surface by titlebar sizes (titlebars occupy space in geometry) */
	wlr_scene_node_set_position(&c->scene_surface->node, c->bw + titlebar_left, c->bw + titlebar_top);
	wlr_scene_rect_set_size(c->border[0], c->geometry.width, c->bw);
	wlr_scene_rect_set_size(c->border[1], c->geometry.width, c->bw);
	wlr_scene_rect_set_size(c->border[2], c->bw, c->geometry.height - 2 * c->bw);
	wlr_scene_rect_set_size(c->border[3], c->bw, c->geometry.height - 2 * c->bw);
	wlr_scene_node_set_position(&c->border[1]->node, 0, c->geometry.height - c->bw);
	wlr_scene_node_set_position(&c->border[2]->node, 0, c->bw);
	wlr_scene_node_set_position(&c->border[3]->node, c->geometry.width - c->bw, c->bw);

	/* Update shadow geometry (lazy creation if needed) */
	{
		const shadow_config_t *shadow_config = shadow_get_effective_config(
			c->shadow_config, false);
		if (shadow_config && shadow_config->enabled) {
			if (c->shadow.tree) {
				shadow_update_geometry(&c->shadow, shadow_config,
					c->geometry.width, c->geometry.height);
			} else {
				shadow_create(c->scene, &c->shadow, shadow_config,
					c->geometry.width, c->geometry.height);
			}
		}
	}

	/* Update titlebar positions - they depend on current geometry */
	client_update_titlebar_positions(c);

	/* Request size change from client (subtract borders AND titlebars from geometry)
	 * CRITICAL: Only send configure if there's no pending resize waiting for client commit.
	 * Without this check, we flood the client with configure events on every refresh cycle,
	 * which crashes Firefox and other clients that can't handle rapid configure floods. */
	if (!c->resize) {
		/* Sync xdg-shell fullscreen state with c->fullscreen so the client
		 * knows it is fullscreen. Done here (not in client_set_fullscreen)
		 * so it batches into the same configure as the size change. */
		if (c->client_type == XDGShell && c->surface.xdg && c->surface.xdg->toplevel
				&& c->surface.xdg->toplevel->scheduled.fullscreen != c->fullscreen)
			client_set_fullscreen_internal(c, c->fullscreen);
#ifdef XWAYLAND
		else if (c->client_type == X11 && c->surface.xwayland
				&& c->surface.xwayland->fullscreen != c->fullscreen)
			client_set_fullscreen_internal(c, c->fullscreen);
#endif
		if (c->fullscreen) {
			/* Fullscreen: client gets full geometry minus borders only */
			c->resize = client_set_size(c,
					c->geometry.width - 2 * c->bw,
					c->geometry.height - 2 * c->bw);
		} else {
			int sw = c->geometry.width - 2 * c->bw
				- titlebar_left - c->titlebar[CLIENT_TITLEBAR_RIGHT].size;
			int sh = c->geometry.height - 2 * c->bw
				- titlebar_top - c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
			if (sw < 1) sw = 1;
			if (sh < 1) sh = 1;
			c->resize = client_set_size(c, sw, sh);
		}
	}
	client_get_clip(c, &clip);

	/* Clip client content to its assigned monitor bounds so offscreen
	 * clients (e.g. carousel scrolling layout) don't render on adjacent
	 * monitors. For fully-inside clients this is just a bounds check.
	 *
	 * We toggle individual child scene nodes (surface, borders, shadow,
	 * titlebars) rather than c->scene->node which the banning system
	 * controls. */
	if (c->mon) {
		struct wlr_box mon = c->mon->m;
		bool fully_inside =
			c->geometry.x >= mon.x &&
			c->geometry.y >= mon.y &&
			c->geometry.x + c->geometry.width <= mon.x + mon.width &&
			c->geometry.y + c->geometry.height <= mon.y + mon.height;

		if (fully_inside) {
			/* Common case: everything visible, no clipping needed.
			 * Re-enable surface/borders/shadow that may have been hidden.
			 * Titlebars are managed by client_update_titlebar_positions(). */
			wlr_scene_node_set_enabled(&c->scene_surface->node, true);
			for (int i = 0; i < 4; i++)
				wlr_scene_node_set_enabled(&c->border[i]->node, true);
			if (c->shadow.tree)
				wlr_scene_node_set_enabled(&c->shadow.tree->node, true);
		} else {
			/* Client extends past monitor: clip surface, hide everything
			 * else (wlr_scene_rect/buffer have no clip API). */
			int cx = c->geometry.x + c->bw + titlebar_left;
			int cy = c->geometry.y + c->bw + titlebar_top;
			int vl = cx > mon.x ? cx : mon.x;
			int vt = cy > mon.y ? cy : mon.y;
			int vr = (cx + clip.width) < (mon.x + mon.width)
				? (cx + clip.width) : (mon.x + mon.width);
			int vb = (cy + clip.height) < (mon.y + mon.height)
				? (cy + clip.height) : (mon.y + mon.height);

			if (vr > vl && vb > vt) {
				/* Partially visible: narrow the clip */
				clip.x += vl - cx;
				clip.y += vt - cy;
				clip.width = vr - vl;
				clip.height = vb - vt;
				wlr_scene_node_set_enabled(&c->scene_surface->node, true);
			} else {
				/* Fully offscreen */
				wlr_scene_node_set_enabled(&c->scene_surface->node, false);
			}

			/* Hide borders, shadow, and titlebars */
			for (int i = 0; i < 4; i++)
				wlr_scene_node_set_enabled(&c->border[i]->node, false);
			if (c->shadow.tree)
				wlr_scene_node_set_enabled(&c->shadow.tree->node, false);
			for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP;
					bar < CLIENT_TITLEBAR_COUNT; bar++) {
				if (c->titlebar[bar].scene_buffer)
					wlr_scene_node_set_enabled(
						&c->titlebar[bar].scene_buffer->node, false);
			}
		}
	}

	wlr_scene_subsurface_tree_set_clip(&c->scene_surface->node, &clip);
}

void
resize(Client *c, struct wlr_box geo, int interact)
{
	struct wlr_box *bbox;

	if (!c->mon || !client_surface(c)->mapped)
		return;

	bbox = interact ? &sgeom : &c->mon->w;

	client_set_bounds(c, geo.width, geo.height);
	c->geometry = geo;
	applybounds(c, bbox);

	/* Apply aspect ratio constraint (Wayland equivalent of ICCCM aspect hints).
	 * Works on full geometry (including borders/titlebars) to match
	 * the ratio captured from Lua (geo.width / geo.height). */
	if (c->aspect_ratio > 0 && !c->fullscreen && !c->maximized) {
		int w = c->geometry.width;
		int h = c->geometry.height;
		if (w > 0 && h > 0) {
			double current = (double)w / h;
			/* Tolerance: ~1 pixel to prevent rounding oscillation */
			double epsilon = 1.5 / (double)h;
			if (current - c->aspect_ratio > epsilon) {
				c->geometry.width = (int)(h * c->aspect_ratio + 0.5);
			} else if (c->aspect_ratio - current > epsilon) {
				c->geometry.height = (int)(w / c->aspect_ratio + 0.5);
			}
		}
	}

	/* Apply to wlroots rendering */
	apply_geometry_to_wlroots(c);

	/* Emit signal for geometry change listeners */
	luaA_emit_signal_global("client::property::geometry");
}

void
setfullscreen(Client *c, int fullscreen)
{
	c->fullscreen = fullscreen;
	if (!c->mon || !client_surface(c)->mapped)
		return;

	/* Fullscreen is mutually exclusive with maximized states */
	if (fullscreen && (c->maximized || c->maximized_horizontal || c->maximized_vertical)) {
		c->maximized = 0;
		c->maximized_horizontal = 0;
		c->maximized_vertical = 0;
		/* Clear XDG toplevel maximize state if applicable */
		if (c->client_type == XDGShell && c->surface.xdg->toplevel)
			wlr_xdg_toplevel_set_maximized(c->surface.xdg->toplevel, 0);
	}

	c->bw = fullscreen ? 0 : get_border_width();
	client_set_fullscreen_internal(c, fullscreen);
	wlr_scene_node_reparent(&c->scene->node, layers[c->fullscreen ? LyrFS : LyrTile]);

	if (fullscreen) {
		c->prev = c->geometry;
		resize(c, c->mon->m, 0);
	} else {
		/* restore previous size instead of arrange for floating windows since
		 * client positions are set by the user and cannot be recalculated */
		resize(c, c->prev, 0);
	}
	/* Emit per-client property::fullscreen so Lua handlers run
	 * (update_implicitly_floating, arrange_prop_nf) before arrange */
	lua_State *L = globalconf_get_lua_State();
	if (L) {
		luaA_object_push(L, c);
		luaA_object_emit_signal(L, -1, "property::fullscreen", 0);
		lua_pop(L, 1);
	}

	arrange(c->mon);
	printstatus();

	/* Refresh stacking order (fullscreen layer changes) */
	stack_refresh();
}

void
setmon(Client *c, Monitor *m, uint32_t newtags)
{
	Monitor *oldmon = c->mon;
	screen_t *old_screen;
	lua_State *L;

	if (oldmon == m)
		return;

	wlr_log(WLR_ERROR, "[HOTPLUG] setmon: client=%s old=%s new=%s",
		client_get_title(c) ? client_get_title(c) : "?",
		oldmon ? oldmon->wlr_output->name : "NULL",
		m ? m->wlr_output->name : "NULL");

	L = globalconf_get_lua_State();
	old_screen = c->screen;  /* Capture before update */

	c->mon = m;
	c->prev = c->geometry;

	/* Update c->screen to match c->mon for Lua property access */
	c->screen = luaA_screen_get_by_monitor(L, m);

	/* Emit property::screen signal if screen changed (AwesomeWM pattern).
	 * This triggers Lua tag management (awful/tag.lua) to assign client
	 * to tags on the new screen via request::tag signal. */
	if (c->screen != old_screen) {
		luaA_object_push(L, c);
		if (old_screen != NULL)
			luaA_object_push(L, old_screen);
		else
			lua_pushnil(L);
		luaA_object_emit_signal(L, -2, "property::screen", 1);
		lua_pop(L, 1);
	}

	if (c->toplevel_handle) {
		if (oldmon && oldmon->wlr_output)
			wlr_foreign_toplevel_handle_v1_output_leave(c->toplevel_handle, oldmon->wlr_output);
		if (m && m->wlr_output)
			wlr_foreign_toplevel_handle_v1_output_enter(c->toplevel_handle, m->wlr_output);
	}

	/* Scene graph sends surface leave/enter events on move and resize */
	if (oldmon)
		arrange(oldmon);
	if (m) {
		/* Make sure window actually overlaps with the monitor */
		resize(c, c->geometry, 0);
		/* Tags managed by Lua/arrays, no c->tags assignment needed */
		/* Mark that client visibility needs refresh when moving monitors */
		banning_need_update();
		setfullscreen(c, c->fullscreen); /* This will call arrange(c->mon) */
		/* Note: setfloating() removed - Lua manages floating state via property system */
	}
	/* Note: focusclient() removed - Lua handles focus via request::activate signals */
}

void
swapstack(const Arg *arg)
{
	Client *sel = focustop(selmon);
	int sel_idx = -1;
	int target_idx = -1;
	int i;
	Client *tmp;
	lua_State *L;

	if (!sel)
		return;

	if (globalconf.clients.len < 2)
		return;

	/* Find sel's position in clients array */
	for (i = 0; i < globalconf.clients.len; i++) {
		if (globalconf.clients.tab[i] == sel) {
			sel_idx = i;
			break;
		}
	}

	if (sel_idx == -1)
		return; /* Should never happen */

	/* Find next/prev client on selected tags */
	if (arg->i > 0) {
		/* Search forward */
		for (i = sel_idx + 1; i < globalconf.clients.len; i++) {
			if (client_on_selected_tags(globalconf.clients.tab[i])) {
				target_idx = i;
				break;
			}
		}
	} else {
		/* Search backward */
		for (i = sel_idx - 1; i >= 0; i--) {
			if (client_on_selected_tags(globalconf.clients.tab[i])) {
				target_idx = i;
				break;
			}
		}
	}

	if (target_idx == -1)
		return; /* No client found to swap with */

	/* Swap the two clients in the array */
	tmp = globalconf.clients.tab[sel_idx];
	globalconf.clients.tab[sel_idx] = globalconf.clients.tab[target_idx];
	globalconf.clients.tab[target_idx] = tmp;

	/* Emit signals (matches AwesomeWM swap()) */
	L = globalconf_get_lua_State();
	if (L) {
		Client *c = globalconf.clients.tab[target_idx]; /* original sel */
		Client *swap = globalconf.clients.tab[sel_idx]; /* original target */

		luaA_class_emit_signal(L, &client_class, "list", 0);

		/* First swapped signal on c (is_source=true) */
		luaA_object_push(L, c);
		luaA_object_push(L, swap);
		lua_pushboolean(L, true);
		luaA_object_emit_signal(L, -4, "swapped", 2);

		/* Second swapped signal on swap (is_source=false) */
		luaA_object_push(L, swap);
		luaA_object_push(L, c);
		lua_pushboolean(L, false);
		luaA_object_emit_signal(L, -3, "swapped", 2);
	}

	arrange(selmon);
}

void
tagmon(const Arg *arg)
{
	Client *sel = focustop(selmon);
	if (sel) {
		setmon(sel, dirtomon(arg->i), 0);
		focus_restore(selmon);
	}
}

void
togglefloating(const Arg *arg)
{
	Client *sel = focustop(selmon);
	lua_State *L;
	int is_floating;

	/* return if fullscreen */
	if (!sel || sel->fullscreen)
		return;

	/* Call Lua to toggle floating: awful.client.floating.toggle(c)
	 * This matches AwesomeWM's approach where C doesn't manage floating state */
	L = globalconf_get_lua_State();
	if (!L)
		return;

	/* Push client */
	luaA_object_push(L, sel);

	/* Get current floating state */
	lua_getfield(L, -1, "floating");
	is_floating = lua_toboolean(L, -1);
	lua_pop(L, 1);

	/* Set new floating state */
	lua_pushboolean(L, !is_floating);
	lua_setfield(L, -2, "floating");

	lua_pop(L, 1); /* pop client */
}

void
unmapnotify(struct wl_listener *listener, void *data)
{
	/* Called when the surface is unmapped, and should no longer be shown. */
	Client *c = wl_container_of(listener, c, unmap);

	/* Safety: If scene was never created (mapnotify failed), nothing to clean up */
	if (!c->scene) {
		return;
	}

	/* Safety: If Lua destroyed during cleanup, skip Lua-dependent operations */
	if (!globalconf_L) {
		wlr_scene_node_destroy(&c->scene->node);
		return;
	}

	luaA_emit_signal_global("client::unmap");

	if (c->toplevel_handle) {
		wl_list_remove(&c->foreign_request_activate.link);
		wl_list_remove(&c->foreign_request_close.link);
		wl_list_remove(&c->foreign_request_fullscreen.link);
		wl_list_remove(&c->foreign_request_maximize.link);
		wl_list_remove(&c->foreign_request_minimize.link);
		wlr_foreign_toplevel_handle_v1_destroy(c->toplevel_handle);
		c->toplevel_handle = NULL;
	}

	/* CRITICAL: If this is the focused client, clear focus immediately
	 * to prevent client_focus_refresh() from accessing dangling surface pointers */
	if (globalconf.focus.client == c) {
		globalconf.focus.client = NULL;
		globalconf.focus.need_update = true;
		/* Clear seat keyboard focus to prevent focusclient() from trying to
		 * deactivate this surface during focus restoration. The XDG surface
		 * is already uninitialized by the time unmapnotify fires, so any
		 * wlr_xdg_toplevel_set_activated() call would assert. */
		if (seat->keyboard_state.focused_surface == client_surface(c))
			wlr_seat_keyboard_clear_focus(seat);
	}

	if (client_is_unmanaged(c)) {
		if (c == exclusive_focus) {
			exclusive_focus = NULL;
			focus_restore(c->mon ? c->mon : selmon);
		}
	} else {
		/* AwesomeWM pattern: call client_unmanage() from unmapnotify.
		 * This emits request::unmanage while c->screen is still valid,
		 * allowing Lua's check_focus_delayed to restore focus properly.
		 * destroynotify() will see client already removed from array and skip. */
		client_unmanage(c, CLIENT_UNMANAGE_UNMAP);
	}

	/* Remove commit listener before destroying scene - only registered for XDG clients.
	 * Must be done before surface destruction as wlroots asserts listener lists are empty. */
	if (c->client_type == XDGShell) {
		wl_list_remove(&c->commit.link);
	}

	wlr_scene_node_destroy(&c->scene->node);
	c->scene = NULL;  /* Mark as cleaned up so destroynotify won't double-remove */

	/* Clear titlebar scene buffer pointers - they were children of c->scene
	 * and are now freed. Prevents use-after-free in refresh callbacks. */
	for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP; bar < CLIENT_TITLEBAR_COUNT; bar++) {
		c->titlebar[bar].scene_buffer = NULL;
	}

	printstatus();
	motionnotify(0, NULL, 0, 0, 0, 0);
}

void
updatetitle(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, set_title);
	lua_State *L;

	/* Guard against stale XWayland client after client_unmanage() */
	if (c->client_type == X11 && c->window == XCB_NONE)
		return;

	/* Use new property system for both Wayland and XWayland clients
	 * Both call client_set_name() which emits property::name signal */
	if (c->client_type == XDGShell) {
		property_handle_toplevel_title(listener, data);
	} else {
		/* XWayland: extract title from xwayland surface */
		L = globalconf_get_lua_State();
		luaA_object_push(L, c);
		client_set_name(L, -1, c->surface.xwayland->title
			? strdup(c->surface.xwayland->title) : NULL);
		lua_pop(L, 1);
	}

	if (c == focustop(c->mon))
		printstatus();

	if (c->toplevel_handle) {
		const char *title = client_get_title(c);
		if (title)
			wlr_foreign_toplevel_handle_v1_set_title(c->toplevel_handle, title);
	}
}


void
zoom(const Arg *arg)
{
	Client *c, *sel = focustop(selmon);
	int found_idx = -1;
	int i;

	if (!sel || !selmon || some_client_get_floating(sel))
		return;

	/* Search for the first tiled window that is not sel, marking sel as
	 * NULL if we pass it along the way */
	for (i = 0; i < globalconf.clients.len; i++) {
		c = globalconf.clients.tab[i];
		if (client_on_selected_tags(c) && !some_client_get_floating(c)) {
			if (c != sel) {
				found_idx = i;
				break;
			}
			sel = NULL;
		}
	}

	/* Return if no other tiled window was found */
	if (found_idx == -1)
		return;

	/* If we passed sel, move c to the front; otherwise, move sel to the
	 * front */
	if (!sel)
		sel = c;

	/* Remove sel from array and push to front */
	sync_tiling_reorder(sel);

	focusclient(sel, 1);
	arrange(selmon);
}
