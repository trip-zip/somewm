/*
 * focus.c - Focus policy for somewm compositor
 *
 * Client focus, activation, pointer constraint updates.
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/xwayland.h>

#include "somewm.h"
#include "somewm_api.h"
#include "focus.h"
#include "event_queue.h"
#include "window.h"
#include "input.h"
#include "globalconf.h"
#include "client.h"
#include "common/luaobject.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/layer_surface.h"
#include "objects/screen.h"
#include "objects/signal.h"

#include "somewm_internal.h"

void
focusclient(Client *c, int lift)
{
	struct wlr_surface *old = seat->keyboard_state.focused_surface;
	int old_client_type;
	Client *old_c = NULL;
	LayerSurface *old_l = NULL;
	struct wlr_surface *surface;
	struct wlr_keyboard *kb;

	if (session_is_locked())
		return;

	if (c && lift)
		client_restack(c);

	if (c && client_surface(c) == old)
		return;

	if ((old_client_type = toplevel_from_wlr_surface(old, &old_c, &old_l)) == XDGShell) {
		struct wlr_xdg_popup *popup, *tmp;
		wl_list_for_each_safe(popup, tmp, &old_c->surface.xdg->popups, link)
			wlr_xdg_popup_destroy(popup);
	}

	if (c && !client_is_unmanaged(c)) {
		selmon = c->mon;
		/* Clear urgent flag via proper API to emit property::urgent signal */
		luaA_object_push(globalconf_L, c);
		client_set_urgent(globalconf_L, -1, false);
		lua_pop(globalconf_L, 1);

		/* Don't change border color if there is an exclusive focus or we are
		 * handling a drag operation */
		if (!exclusive_focus && !seat->drag)
			client_set_border_color(c, get_focuscolor());
	}

	/* Deactivate old client if focus is changing */
	if (old && (!c || client_surface(c) != old)) {
		/* A mapped top or overlay surface retains keyboard focus.
		 * Its scene node remains until the next frame parks it. */
		if (old_client_type == LayerShell && old_l->mapped
				&& old_l->layer_surface->current.layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP) {
			return;
		} else if (old_c && old_c == exclusive_focus && client_wants_focus(old_c)) {
			return;
		} else if (old_c && !client_is_unmanaged(old_c)) {
			/* Only do protocol-level deactivation if new client doesn't want focus.
			 * Skipping this avoids issues with winecfg and similar clients. */
			if (!c || !client_wants_focus(c)) {
				client_activate_surface(old, 0);
				if (old_c->toplevel_handle)
					wlr_foreign_toplevel_handle_v1_set_activated(old_c->toplevel_handle, false);
			}
		}
	}

	/* Unfocus old client from globalconf (AwesomeWM pattern) - this emits proper signals */
	if (c && globalconf.focus.client && globalconf.focus.client != c &&
	    !client_is_unmanaged(globalconf.focus.client)) {
		client_set_border_color(globalconf.focus.client, get_bordercolor());
		luaA_object_push(globalconf_L, globalconf.focus.client);
		lua_pushboolean(globalconf_L, false);
		some_event_queue_signal(globalconf_L, -2, SIG_PROPERTY_ACTIVE, 1);
		some_event_queue_signal0(globalconf_L, -1, SIG_UNFOCUS);
		lua_pop(globalconf_L, 1);
		some_event_queue_global(SIG_CLIENT_UNFOCUS);
	}
	printstatus();

	if (!c) {
		/* With no client, all we have left is to clear focus (deferred pattern) */
		globalconf.focus.client = NULL;
		globalconf.focus.need_update = true;
		return;
	}

	/* Change cursor surface */
	motionnotify(0, NULL, 0, 0, 0, 0);

	/* Set pending focus change for AwesomeWM compatibility (Lua code may check this) */
	globalconf.focus.client = c;
	globalconf.focus.need_update = true;

	/* Activate the new client */
	client_activate_surface(client_surface(c), 1);

	if (c->toplevel_handle)
		wlr_foreign_toplevel_handle_v1_set_activated(c->toplevel_handle, true);

	/* CRITICAL: Apply keyboard focus IMMEDIATELY while surface is valid (not deferred)
	 * AwesomeWM defers this, but Wayland surface pointers can become invalid by the time
	 * client_focus_refresh() runs. We must apply focus now. */
	surface = client_surface(c);

	/* Check if surface is ready for keyboard input.
	 * For XWayland clients, wlr_surface->mapped may be false even when the XWayland
	 * map event has fired. We use c->scene as the indicator that mapnotify() has
	 * processed this client and it's ready for input. */
	int surface_ready;
	if (c->client_type == X11) {
		surface_ready = (surface && c->scene != NULL);
	} else
	{
		surface_ready = (surface && surface->mapped);
	}

	if (surface_ready) {
		/* Sway pattern: inform XWayland of the active seat on every focus
		 * change to an X11 client. Required for proper keyboard delivery. */
		if (c->client_type == X11)
			wlr_xwayland_set_seat(xwayland, seat);
		kb = wlr_seat_get_keyboard(seat);
		if (kb) {
			wlr_seat_keyboard_notify_enter(seat, surface,
			                                kb->keycodes,
			                                kb->num_keycodes,
			                                &kb->modifiers);
		} else {
			/* Send keyboard enter even without a keyboard device (Sway pattern).
			 * This ensures the surface knows it has keyboard focus. */
			wlr_seat_keyboard_notify_enter(seat, surface, NULL, 0, NULL);
		}
		/* Update pointer constraint for newly focused surface.
		 * Games like Minecraft need the constraint to follow keyboard focus. */
		cursorconstrain(wlr_pointer_constraints_v1_constraint_for_surface(
			pointer_constraints, surface, seat));
	}

	/* Emit focus signals (AwesomeWM pattern)
	 * CRITICAL: Must emit both property::active AND object-level "focus" signal.
	 * The awful.client.focus.history module connects to "focus" signal to track
	 * focus history. Without this, focus.history.list remains empty. */
	if (!client_is_unmanaged(c)) {
		luaA_object_push(globalconf_L, c);
		lua_pushboolean(globalconf_L, true);
		some_event_queue_signal(globalconf_L, -2, SIG_PROPERTY_ACTIVE, 1);
		some_event_queue_signal0(globalconf_L, -1, SIG_FOCUS);
		lua_pop(globalconf_L, 1);
	}

	some_event_queue_global(SIG_CLIENT_FOCUS);
}

Client *
focustop(Monitor *m)
{
	Client *top = NULL;
	enum node_layer layer = LAYER_INHERIT;
	foreach(item, globalconf.screens) {
		screen_t *s = *item;
		if (luaA_monitor_get_by_screen(globalconf_L, s) != m || !s->node)
			continue;
		struct node *n;
		wl_list_for_each(n, &s->node->children, link) {
			if (n->kind != NODE_CLIENT)
				continue;
			Client *c = n->owner;
			enum node_layer candidate = client_effective_layer(c);
			if (client_on_selected_tags(c) && candidate >= layer) {
				top = c;
				layer = candidate;
			}
		}
	}
	return top;
}

/* Single entry point for restoring focus after something closed, unlocked,
 * or disconnected. Emits request::focus_restore on the screen so Lua can
 * pick the right client from focus history. Falls back to focustop() when
 * Lua is unavailable or doesn't handle it. */
void
focus_restore(Monitor *m)
{
	if (session_is_locked())
		return;

	if (!m)
		m = selmon;

	if (globalconf_L) {
		lua_State *L = globalconf_get_lua_State();
		screen_t *screen = luaA_screen_get_by_monitor(L, m);
		if (screen) {
			luaA_object_push(L, screen);
			luaA_object_emit_signal(L, -1, "request::focus_restore", 0);
			lua_pop(L, 1);
			/* If Lua set a focused client, we're done */
			if (globalconf.focus.client)
				return;
		}
	}

	/* Fallback: focus topmost client on the monitor */
	focusclient(focustop(m), 1);
}
