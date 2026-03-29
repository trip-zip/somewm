/*
 * protocols.c - Protocol handlers for somewm compositor
 *
 * Layer shell, idle inhibit, session lock, foreign toplevel management,
 * and XDG activation token handling.
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <glib.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>

#include "somewm.h"
#include "somewm_api.h"
#include "globalconf.h"
#include "client.h"
#include "common/luaobject.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/screen.h"
#include "objects/drawin.h"
#include "objects/layer_surface.h"
#include "objects/signal.h"
#include "objects/mousegrabber.h"
#include "stack.h"
#include "banning.h"
#include "animation.h"
#include "protocols.h"

#define LENGTH(X)               (sizeof X / sizeof X[0])
#define LISTEN(E, L, H) wl_signal_add((E), ((L)->notify = (H), (L)))
#define LISTEN_STATIC(E, H) do { struct wl_listener *_l = ecalloc(1, sizeof(*_l)); _l->notify = (H); wl_signal_add((E), _l); } while (0)

/* Forward declaration for wlr_input_device (used by motionnotify extern) */
struct wlr_input_device;

/* Extern declarations for functions in somewm.c */
extern void arrange(Monitor *m);
#include "focus.h"
extern void pointerfocus(Client *c, struct wlr_surface *surface,
		double sx, double sy, uint32_t time);
extern void setfullscreen(Client *c, int fullscreen);
extern void motionnotify(uint32_t time, struct wlr_input_device *device,
		double sx, double sy, double sx_unaccel, double sy_unaccel);

/* Forward declarations */
void checkidleinhibitor(struct wlr_surface *exclude);
static void destroyidleinhibitor(struct wl_listener *listener, void *data);
void destroylayersurfacenotify(struct wl_listener *listener, void *data);
void unmaplayersurfacenotify(struct wl_listener *listener, void *data);
static void destroylock(SessionLock *lock, int unlock);
void destroylocksurface(struct wl_listener *listener, void *data);
static void destroysessionlock(struct wl_listener *listener, void *data);
void unlocksession(struct wl_listener *listener, void *data);
void foreign_toplevel_request_activate(struct wl_listener *listener, void *data);
void foreign_toplevel_request_close(struct wl_listener *listener, void *data);
void foreign_toplevel_request_fullscreen(struct wl_listener *listener, void *data);
void foreign_toplevel_request_maximize(struct wl_listener *listener, void *data);
void foreign_toplevel_request_minimize(struct wl_listener *listener, void *data);
static gboolean activation_token_timeout(gpointer user_data);

/* Stores the focused client before locking, for restoration on unlock */
static Client *pre_lock_focused_client = NULL;

/* XDG Activation token tracking (Wayland startup notification) */
typedef struct {
	char *token;              /* XDG activation token string */
	char *app_id;             /* Application ID from spawn */
	uint32_t timeout_id;      /* GLib timeout source ID for cleanup */
} activation_token_t;

/* Pending activation tokens (matches AwesomeWM's sn_waits pattern) */
static activation_token_t *pending_tokens = NULL;
static size_t pending_tokens_len = 0;
static size_t pending_tokens_cap = 0;

/* ==========================================================================
 * Layer Shell
 * ========================================================================== */

void
arrangelayer(Monitor *m, struct wl_list *list, struct wlr_box *usable_area, int exclusive)
{
	LayerSurface *l;
	struct wlr_box full_area = m->m;

	wl_list_for_each(l, list, link) {
		struct wlr_layer_surface_v1 *layer_surface = l->layer_surface;

		if (!layer_surface->initialized)
			continue;

		if (exclusive != (layer_surface->current.exclusive_zone > 0))
			continue;

		wlr_scene_layer_surface_v1_configure(l->scene_layer, &full_area, usable_area);
		wlr_scene_node_set_position(&l->popups->node, l->scene->node.x, l->scene->node.y);
	}
}

void
arrangelayers(Monitor *m)
{
	int i;
	struct wlr_box usable_area = m->m;
	LayerSurface *l;
	uint32_t layers_above_shell[] = {
		ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
		ZWLR_LAYER_SHELL_V1_LAYER_TOP,
	};
	if (!m->wlr_output->enabled)
		return;

	/* Arrange exclusive surfaces from top->bottom */
	for (i = 3; i >= 0; i--)
		arrangelayer(m, &m->layers[i], &usable_area, 1);

	/* Apply drawin struts (from Lua wibars) to the usable area
	 * This must happen AFTER layer shell exclusive zones but BEFORE setting m->w */
	some_monitor_apply_drawin_struts(m, &usable_area);

	if (!wlr_box_equal(&usable_area, &m->w)) {
		lua_State *L;
		screen_t *screen;

		m->w = usable_area;

		/* Update Lua screen.workarea property to match the new usable area
		 * This emits property::workarea signal so layouts get the correct workarea */
		L = globalconf_get_lua_State();
		if (L && globalconf.screens.tab) {
			screen = luaA_screen_get_by_monitor(L, m);
			if (screen) {
				screen_set_workarea(L, screen, &usable_area);
			}
		}

		arrange(m);
	}

	/* Arrange non-exlusive surfaces from top->bottom */
	for (i = 3; i >= 0; i--)
		arrangelayer(m, &m->layers[i], &usable_area, 0);

	/* Find topmost keyboard interactive layer and emit request::keyboard signal
	 * If the layer surface has a Lua object, let Lua decide whether to grant focus.
	 * Otherwise, use legacy auto-grant behavior. */
	for (i = 0; i < (int)LENGTH(layers_above_shell); i++) {
		wl_list_for_each_reverse(l, &m->layers[layers_above_shell[i]], link) {
			if (locked || !l->layer_surface->current.keyboard_interactive || !l->mapped)
				continue;

			if (l->lua_object && globalconf_L) {
				/* Emit request::keyboard signal - Lua decides whether to grant focus */
				const char *context = (l->layer_surface->current.keyboard_interactive ==
					ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE)
					? "exclusive" : "on_demand";
				layer_surface_emit_request_keyboard(l->lua_object, context);
				/* If Lua granted focus, we're done. Otherwise, continue searching. */
				if (l->lua_object->has_keyboard_focus)
					return;
			} else {
				/* Legacy behavior for surfaces without Lua objects */
				focusclient(NULL, 0);
				exclusive_focus = l;
				client_notify_enter(l->layer_surface->surface, wlr_seat_get_keyboard(seat));
				return;
			}
		}
	}
}

void
commitlayersurfacenotify(struct wl_listener *listener, void *data)
{
	LayerSurface *l = wl_container_of(listener, l, surface_commit);
	struct wlr_layer_surface_v1 *layer_surface = l->layer_surface;
	struct wlr_scene_tree *scene_layer = layers[layermap[layer_surface->current.layer]];
	struct wlr_layer_surface_v1_state old_state;
	int was_mapped;

	if (l->layer_surface->initial_commit) {
		client_set_scale(layer_surface->surface, l->mon->wlr_output->scale);

		/* Temporarily set the layer's current state to pending
		 * so that we can easily arrange it */
		old_state = l->layer_surface->current;
		l->layer_surface->current = l->layer_surface->pending;
		arrangelayers(l->mon);
		l->layer_surface->current = old_state;
		return;
	}

	if (layer_surface->current.committed == 0 && l->mapped == layer_surface->surface->mapped)
		return;

	was_mapped = l->mapped;
	l->mapped = layer_surface->surface->mapped;

	/* If surface just mapped, create Lua object and emit request::manage */
	if (!was_mapped && l->mapped && !l->lua_object && globalconf_L) {
		lua_State *L = globalconf_get_lua_State();
		layer_surface_t *ls = layer_surface_manage(L, l);
		/* Note: luaA_object_ref inside layer_surface_manage already pops the object */
		layer_surface_emit_manage(ls);
	}

	if (scene_layer != l->scene->node.parent) {
		wlr_scene_node_reparent(&l->scene->node, scene_layer);
		wl_list_remove(&l->link);
		wl_list_insert(&l->mon->layers[layer_surface->current.layer], &l->link);
		wlr_scene_node_reparent(&l->popups->node, (layer_surface->current.layer
				< ZWLR_LAYER_SHELL_V1_LAYER_TOP ? layers[LyrTop] : scene_layer));
	}

	arrangelayers(l->mon);

	/* Emit property change signals for Lua (matches AwesomeWM pattern) */
	if (l->lua_object && globalconf_L && layer_surface->current.committed) {
		lua_State *L = globalconf_get_lua_State();
		uint32_t committed = layer_surface->current.committed;

		luaA_object_push(L, l->lua_object);

		if (committed & (1 << 5))  /* WLR_LAYER_SURFACE_V1_STATE_LAYER */
			luaA_object_emit_signal(L, -1, "property::layer", 0);
		if (committed & (1 << 1))  /* WLR_LAYER_SURFACE_V1_STATE_ANCHOR */
			luaA_object_emit_signal(L, -1, "property::anchor", 0);
		if (committed & (1 << 2))  /* WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_ZONE */
			luaA_object_emit_signal(L, -1, "property::exclusive_zone", 0);
		if (committed & (1 << 4))  /* WLR_LAYER_SURFACE_V1_STATE_KEYBOARD_INTERACTIVITY */
			luaA_object_emit_signal(L, -1, "property::keyboard_interactive", 0);
		if (committed & (1 << 3))  /* WLR_LAYER_SURFACE_V1_STATE_MARGIN */
			luaA_object_emit_signal(L, -1, "property::margin", 0);

		lua_pop(L, 1);
	}
}

void
createlayersurface(struct wl_listener *listener, void *data)
{
	struct wlr_layer_surface_v1 *layer_surface = data;
	LayerSurface *l;
	struct wlr_surface *surface = layer_surface->surface;
	struct wlr_scene_tree *scene_layer = layers[layermap[layer_surface->pending.layer]];

	if (!layer_surface->output
			&& !(layer_surface->output = selmon ? selmon->wlr_output : NULL)) {
		wlr_layer_surface_v1_destroy(layer_surface);
		return;
	}

	l = layer_surface->data = ecalloc(1, sizeof(*l));
	l->type = LayerShell;
	LISTEN(&surface->events.commit, &l->surface_commit, commitlayersurfacenotify);
	LISTEN(&surface->events.unmap, &l->unmap, unmaplayersurfacenotify);
	LISTEN(&layer_surface->events.destroy, &l->destroy, destroylayersurfacenotify);

	l->layer_surface = layer_surface;
	l->mon = layer_surface->output->data;
	l->scene_layer = wlr_scene_layer_surface_v1_create(scene_layer, layer_surface);
	l->scene = l->scene_layer->tree;
	l->popups = surface->data = wlr_scene_tree_create(layer_surface->current.layer
			< ZWLR_LAYER_SHELL_V1_LAYER_TOP ? layers[LyrTop] : scene_layer);
	l->scene->node.data = l->popups->node.data = l;

	wl_list_insert(&l->mon->layers[layer_surface->pending.layer],&l->link);
	wlr_surface_send_enter(surface, layer_surface->output);
}

void
destroylayersurfacenotify(struct wl_listener *listener, void *data)
{
	LayerSurface *l = wl_container_of(listener, l, destroy);

	wl_list_remove(&l->link);
	wl_list_remove(&l->destroy.link);
	wl_list_remove(&l->unmap.link);
	wl_list_remove(&l->surface_commit.link);
	wlr_scene_node_destroy(&l->scene->node);
	wlr_scene_node_destroy(&l->popups->node);
	free(l);
}

void
unmaplayersurfacenotify(struct wl_listener *listener, void *data)
{
	LayerSurface *l = wl_container_of(listener, l, unmap);

	l->mapped = 0;
	wlr_scene_node_set_enabled(&l->scene->node, 0);
	if (l == exclusive_focus) {
		exclusive_focus = NULL;
		focusclient(focustop(selmon), 1);
	}
	if (l->layer_surface->output && (l->mon = l->layer_surface->output->data))
		arrangelayers(l->mon);

	/* Emit request::unmanage signal if we have a Lua object */
	if (l->lua_object && globalconf_L) {
		layer_surface_emit_unmanage(l->lua_object);
	}

	motionnotify(0, NULL, 0, 0, 0, 0);
}

/* ==========================================================================
 * Idle Inhibit
 * ========================================================================== */

void
checkidleinhibitor(struct wlr_surface *exclude)
{
	int inhibited = 0, unused_lx, unused_ly;
	struct wlr_idle_inhibitor_v1 *inhibitor;
	wl_list_for_each(inhibitor, &idle_inhibit_mgr->inhibitors, link) {
		struct wlr_surface *surface = wlr_surface_get_root_surface(inhibitor->surface);
		struct wlr_scene_tree *tree = surface->data;
		if (exclude != surface && (globalconf.appearance.bypass_surface_visibility || (!tree
				|| wlr_scene_node_coords(&tree->node, &unused_lx, &unused_ly)))) {
			inhibited = 1;
			break;
		}
	}

	wlr_idle_notifier_v1_set_inhibited(idle_notifier, inhibited);
}

void
createidleinhibitor(struct wl_listener *listener, void *data)
{
	struct wlr_idle_inhibitor_v1 *idle_inhibitor = data;
	LISTEN_STATIC(&idle_inhibitor->events.destroy, destroyidleinhibitor);

	checkidleinhibitor(NULL);
}

static void
destroyidleinhibitor(struct wl_listener *listener, void *data)
{
	/* `data` is the wlr_surface of the idle inhibitor being destroyed,
	 * at this point the idle inhibitor is still in the list of the manager */
	checkidleinhibitor(wlr_surface_get_root_surface(data));
	wl_list_remove(&listener->link);
	free(listener);
}

bool
some_is_idle_inhibited(void)
{
	return !wl_list_empty(&idle_inhibit_mgr->inhibitors);
}

/* ==========================================================================
 * Session Lock
 * ========================================================================== */

static void
destroylock(SessionLock *lock, int unlock)
{
	wlr_seat_keyboard_notify_clear_focus(seat);
	if ((locked = !unlock))
		goto destroy;

	wlr_scene_node_set_enabled(&locked_bg->node, 0);

	focusclient(focustop(selmon), 0);
	motionnotify(0, NULL, 0, 0, 0, 0);

destroy:
	wl_list_remove(&lock->new_surface.link);
	wl_list_remove(&lock->unlock.link);
	wl_list_remove(&lock->destroy.link);

	wlr_scene_node_destroy(&lock->scene->node);
	cur_lock = NULL;
	free(lock);
}

void
destroylocksurface(struct wl_listener *listener, void *data)
{
	Monitor *m = wl_container_of(listener, m, destroy_lock_surface);
	struct wlr_session_lock_surface_v1 *surface, *lock_surface = m->lock_surface;

	m->lock_surface = NULL;
	wl_list_remove(&m->destroy_lock_surface.link);

	if (lock_surface->surface != seat->keyboard_state.focused_surface)
		return;

	if (locked && cur_lock && !wl_list_empty(&cur_lock->surfaces)) {
		surface = wl_container_of(cur_lock->surfaces.next, surface, link);
		client_notify_enter(surface->surface, wlr_seat_get_keyboard(seat));
	} else if (!locked) {
		focusclient(focustop(selmon), 1);
	} else {
		wlr_seat_keyboard_clear_focus(seat);
	}
}

static void
destroysessionlock(struct wl_listener *listener, void *data)
{
	SessionLock *lock = wl_container_of(listener, lock, destroy);
	destroylock(lock, 0);
}

/* ==========================================================================
 * Lua Lock API Implementation
 * ========================================================================== */

/** Activate Lua-controlled lock mode
 * - Promotes lock surface and cover surfaces to LyrBlock
 * - Gives keyboard focus to lock surface
 */
void
some_activate_lua_lock(void)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);

	/* Save currently focused client for restoration on unlock. */
	pre_lock_focused_client = globalconf.focus.client;

	/* Clear current keyboard focus */
	wlr_seat_keyboard_notify_clear_focus(seat);

	/* Stop any active mousegrabber to prevent Lua callbacks executing
	 * during lock (e.g., client resize/move operations) */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		luaA_mousegrabber_stop(L);
	}

	/* Enable the compositor-level background rect in LyrBlock.
	 * This provides an opaque safety net behind all lock surfaces so that
	 * desktop content is never visible, even on screens that have no
	 * Lua-created cover wibox (e.g. hotplugged monitors). */
	wlr_scene_node_set_enabled(&locked_bg->node, 1);

	/* Promote all cover surfaces to LyrBlock so they hide desktop content
	 * on secondary monitors */
	for (int i = 0; i < cover_count; i++)
		some_promote_lock_cover(covers[i]);

	/* Promote lock surface to LyrBlock and raise above covers */
	if (lock_surface && lock_surface->scene_tree) {
		wlr_scene_node_reparent(&lock_surface->scene_tree->node, layers[LyrBlock]);
		wlr_scene_node_raise_to_top(&lock_surface->scene_tree->node);
	}
}

/** Deactivate Lua-controlled lock mode
 * - Restores lock surface and covers to normal layers
 * - Restores normal focus
 */
void
some_deactivate_lua_lock(void)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);

	/* Disable compositor-level lock background */
	wlr_scene_node_set_enabled(&locked_bg->node, 0);

	/* Move lock surface back to normal layer (LyrWibox) */
	if (lock_surface && lock_surface->scene_tree) {
		wlr_scene_node_reparent(&lock_surface->scene_tree->node, layers[LyrWibox]);
	}

	/* Move cover surfaces back to normal layers via stack_refresh() */
	for (int i = 0; i < cover_count; i++) {
		if (covers[i] && covers[i]->scene_tree) {
			wlr_scene_node_reparent(&covers[i]->scene_tree->node, layers[LyrWibox]);
		}
	}

	/* Let stack_refresh() sort everything back to proper layers */
	stack_refresh();

	/* Restore focus to pre-lock client if still valid, otherwise top client */
	if (pre_lock_focused_client && pre_lock_focused_client->scene) {
		focusclient(pre_lock_focused_client, 1);
	} else {
		focusclient(focustop(selmon), 1);
	}
	pre_lock_focused_client = NULL;
	motionnotify(0, NULL, 0, 0, 0, 0);
}

/** Promote a single cover to LyrBlock during an active lock.
 * Re-raises the interactive lock surface above the new cover so it
 * stays on top of all covers. */
void
some_promote_lock_cover(drawin_t *d)
{
	if (d && d->scene_tree) {
		wlr_scene_node_reparent(&d->scene_tree->node, layers[LyrBlock]);
		wlr_scene_node_raise_to_top(&d->scene_tree->node);
		drawin_t *lock_surface = some_get_lua_lock_surface();
		if (lock_surface && lock_surface->scene_tree)
			wlr_scene_node_raise_to_top(&lock_surface->scene_tree->node);
	}
}

/** Clear pre_lock_focused_client if it matches the given client.
 * Called from client_unmanage() to prevent use-after-free on unlock. */
void
some_clear_pre_lock_client(Client *c)
{
	if (c == pre_lock_focused_client)
		pre_lock_focused_client = NULL;
}

/** Check if ext-session-lock-v1 is currently active */
int
some_is_ext_session_locked(void)
{
	return locked;
}

void
createlocksurface(struct wl_listener *listener, void *data)
{
	SessionLock *lock = wl_container_of(listener, lock, new_surface);
	struct wlr_session_lock_surface_v1 *lock_surface = data;
	Monitor *m = lock_surface->output->data;
	struct wlr_scene_tree *scene_tree = lock_surface->surface->data
			= wlr_scene_subsurface_tree_create(lock->scene, lock_surface->surface);
	m->lock_surface = lock_surface;

	wlr_scene_node_set_position(&scene_tree->node, m->m.x, m->m.y);
	wlr_session_lock_surface_v1_configure(lock_surface, m->m.width, m->m.height);

	LISTEN(&lock_surface->events.destroy, &m->destroy_lock_surface, destroylocksurface);

	if (m == selmon)
		client_notify_enter(lock_surface->surface, wlr_seat_get_keyboard(seat));
}

void
locksession(struct wl_listener *listener, void *data)
{
	struct wlr_session_lock_v1 *session_lock = data;
	SessionLock *lock;
	if (cur_lock) {
		wlr_session_lock_v1_destroy(session_lock);
		return;
	}
	/* EDGE-3: Reject ext-session-lock when Lua lock is active */
	if (some_is_lua_locked()) {
		fprintf(stderr, "somewm: ext-session-lock rejected while Lua lock is active\n");
		wlr_session_lock_v1_destroy(session_lock);
		return;
	}
	wlr_scene_node_set_enabled(&locked_bg->node, 1);
	lock = session_lock->data = ecalloc(1, sizeof(*lock));
	focusclient(NULL, 0);

	lock->scene = wlr_scene_tree_create(layers[LyrBlock]);
	cur_lock = lock->lock = session_lock;
	locked = 1;

	LISTEN(&session_lock->events.new_surface, &lock->new_surface, createlocksurface);
	LISTEN(&session_lock->events.destroy, &lock->destroy, destroysessionlock);
	LISTEN(&session_lock->events.unlock, &lock->unlock, unlocksession);

	wlr_session_lock_v1_send_locked(session_lock);
}

void
unlocksession(struct wl_listener *listener, void *data)
{
	SessionLock *lock = wl_container_of(listener, lock, unlock);
	destroylock(lock, 1);
}

/* ==========================================================================
 * Foreign Toplevel Management
 * ========================================================================== */

void
foreign_toplevel_request_activate(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, foreign_request_activate);

	/* Emit request::activate signal to Lua with switch_to_tag hint.
	 * This lets awful.permissions.activate handle tag switching when
	 * activating a window on a different tag (e.g., via rofi -show window). */
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	lua_pushstring(L, "foreign_toplevel");  /* context */
	lua_newtable(L);  /* hints table */
	lua_pushboolean(L, true);
	lua_setfield(L, -2, "switch_to_tag");
	lua_pushboolean(L, true);
	lua_setfield(L, -2, "raise");
	luaA_object_emit_signal(L, -3, "request::activate", 2);
	lua_pop(L, 1);
}

void
foreign_toplevel_request_close(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, foreign_request_close);
	client_send_close(c);
}

void
foreign_toplevel_request_fullscreen(struct wl_listener *listener, void *data)
{
	struct wlr_foreign_toplevel_handle_v1_fullscreen_event *event = data;
	Client *c = wl_container_of(listener, c, foreign_request_fullscreen);
	setfullscreen(c, event->fullscreen);
}

void
foreign_toplevel_request_maximize(struct wl_listener *listener, void *data)
{
	struct wlr_foreign_toplevel_handle_v1_maximized_event *event = data;
	Client *c = wl_container_of(listener, c, foreign_request_maximize);
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	client_set_maximized(L, -1, event->maximized);
	lua_pop(L, 1);
}

void
foreign_toplevel_request_minimize(struct wl_listener *listener, void *data)
{
	struct wlr_foreign_toplevel_handle_v1_minimized_event *event = data;
	Client *c = wl_container_of(listener, c, foreign_request_minimize);
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	client_set_minimized(L, -1, event->minimized);
	lua_pop(L, 1);
}

/* ==========================================================================
 * XDG Activation Tokens
 * ========================================================================== */

/* Cancel all pending activation token timeouts.
 * Called before hot-reload GLib source sweep to prevent compositor-owned
 * timeout sources from being destroyed by the ID-based scan. */
void
activation_tokens_cancel_all(void)
{
	for (size_t i = 0; i < pending_tokens_len; i++) {
		g_source_remove(pending_tokens[i].timeout_id);
		free(pending_tokens[i].token);
		free(pending_tokens[i].app_id);
	}
	pending_tokens_len = 0;
}

static gboolean
activation_token_timeout(gpointer user_data)
{
	char *token;
	size_t i;

	token = (char *)user_data;

	/* Find and remove the token */
	for (i = 0; i < pending_tokens_len; i++) {
		if (strcmp(pending_tokens[i].token, token) == 0) {
			/* Emit spawn::timeout signal (matches AwesomeWM spawn.c:115) */
			luaA_emit_signal_global_with_table("spawn::timeout", 2,
				"id", token);
			free(pending_tokens[i].token);
			free(pending_tokens[i].app_id);

			/* Shift remaining tokens */
			memmove(&pending_tokens[i], &pending_tokens[i + 1],
				(pending_tokens_len - i - 1) * sizeof(activation_token_t));
			pending_tokens_len--;
			break;
		}
	}

	free(token);
	return G_SOURCE_REMOVE;  /* One-shot timer */
}

/* Create activation token and store it */
char *activation_token_create(const char *app_id)
{
	struct wlr_xdg_activation_token_v1 *token;
	const char *token_name;
	size_t new_cap;
	activation_token_t *new_tokens;
	activation_token_t *slot;

	if (!activation)
		return NULL;

	token = wlr_xdg_activation_token_v1_create(activation);
	if (!token)
		return NULL;

	/* Commit the token to get the token string */
	token_name = wlr_xdg_activation_token_v1_get_name(token);
	if (!token_name)
		return NULL;

	/* Grow array if needed */
	if (pending_tokens_len >= pending_tokens_cap) {
		new_cap = pending_tokens_cap == 0 ? 8 : pending_tokens_cap * 2;
		new_tokens = realloc(pending_tokens, new_cap * sizeof(activation_token_t));
		if (!new_tokens)
			return NULL;
		pending_tokens = new_tokens;
		pending_tokens_cap = new_cap;
	}

	/* Store token with metadata */
	slot = &pending_tokens[pending_tokens_len++];
	slot->token = strdup(token_name);
	slot->app_id = app_id ? strdup(app_id) : NULL;

	/* Setup 20-second timeout (matches AwesomeWM) */
	slot->timeout_id = g_timeout_add_seconds(20, activation_token_timeout,
		strdup(token_name));


	return slot->token;
}

/* Cleanup token (called from urgent handler on match) */
void activation_token_cleanup(const char *token)
{
	size_t i;

	if (!token)
		return;

	for (i = 0; i < pending_tokens_len; i++) {
		if (strcmp(pending_tokens[i].token, token) == 0) {
			/* Cancel timeout */
			g_source_remove(pending_tokens[i].timeout_id);


			free(pending_tokens[i].token);
			free(pending_tokens[i].app_id);

			/* Shift remaining tokens */
			memmove(&pending_tokens[i], &pending_tokens[i + 1],
				(pending_tokens_len - i - 1) * sizeof(activation_token_t));
			pending_tokens_len--;
			return;
		}
	}
}
void urgent(struct wl_listener *listener, void *data)
{
	struct wlr_xdg_activation_v1_request_activate_event *event;
	Client *c;
	const char *token_name;
	bool token_matched;
	lua_State *L;

	event = data;
	c = NULL;
	token_matched = false;

	toplevel_from_wlr_surface(event->surface, &c, NULL);
	if (!c)
		return;

	/* Extract token from activation event */
	token_name = event->token ? wlr_xdg_activation_token_v1_get_name(event->token) : NULL;

	/* Validate token against pending tokens */
	if (token_name) {
		size_t i;
		for (i = 0; i < pending_tokens_len; i++) {
			if (strcmp(pending_tokens[i].token, token_name) == 0) {
				token_matched = true;

				/* Set startup_id on client (matches AwesomeWM pattern) */
				if (c->startup_id)
					free(c->startup_id);
				c->startup_id = strdup(token_name);

				/* Clean up matched token */
				activation_token_cleanup(token_name);

				/* Emit spawn::completed signal (matches AwesomeWM spawn.c:167) */
				luaA_emit_signal_global_with_table("spawn::completed", 2,
					"id", token_name);
				break;
			}
		}
	}

	/* Emit request::activate signal to Lua (matches AwesomeWM) */
	L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	lua_pushstring(L, token_matched ? "startup" : "client");  /* context */
	luaA_object_emit_signal(L, -2, "request::activate", 1);
	lua_pop(L, 1);

	/* Emit request::urgent and let Lua decide (matches AwesomeWM) */
	luaA_object_push(L, c);
	lua_pushboolean(L, true);
	luaA_object_emit_signal(L, -2, "request::urgent", 1);
	lua_pop(L, 1);
}
