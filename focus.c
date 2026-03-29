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
#ifdef XWAYLAND
#include <wlr/xwayland.h>
#endif

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
#include "objects/signal.h"
#include "stack.h"

extern void printstatus(void);

/** Update pointer constraint for a surface.
 * Called from somewm_api.c when Lua changes focus - games need pointer
 * constraints to follow keyboard focus for mouse lock to work. */
void
some_update_pointer_constraint(struct wlr_surface *surface)
{
	if (!surface)
		return;
	cursorconstrain(wlr_pointer_constraints_v1_constraint_for_surface(
		pointer_constraints, surface, seat));
}

void
focusclient(Client *c, int lift)
{
	struct wlr_surface *old = seat->keyboard_state.focused_surface;
	int unused_lx, unused_ly, old_client_type;
	Client *old_c = NULL;
	LayerSurface *old_l = NULL;
	struct wlr_surface *surface;
	struct wlr_keyboard *kb;

	if (session_is_locked())
		return;

	/* Raise client in stacking order if requested */
	if (c && lift) {
		if (!client_is_unmanaged(c))
			stack_client_append(c);
		else
			wlr_scene_node_raise_to_top(&c->scene->node);
	}

	if (c && client_surface(c) == old)
		return;

	if ((old_client_type = toplevel_from_wlr_surface(old, &old_c, &old_l)) == XDGShell) {
		struct wlr_xdg_popup *popup, *tmp;
		wl_list_for_each_safe(popup, tmp, &old_c->surface.xdg->popups, link)
			wlr_xdg_popup_destroy(popup);
	}

	/* Put the new client atop the focus stack and select its monitor */
	if (c && !client_is_unmanaged(c)) {
		/* Remove from current position in focus stack */
		foreach(elem, globalconf.stack) {
			if (*elem == c) {
				client_array_remove(&globalconf.stack, elem);
				break;
			}
		}
		/* Add to front of stack (most recent = index 0) */
		client_array_push(&globalconf.stack, c);

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
		/* If an overlay is focused, don't focus or activate the client,
		 * but only update its position in the focus stack to render its border with focuscolor
		 * and focus it after the overlay is closed. */
		if (old_client_type == LayerShell && wlr_scene_node_coords(
					&old_l->scene->node, &unused_lx, &unused_ly)
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
		some_event_queue_property(globalconf_L, -1, SIG_UNFOCUS);
		lua_pop(globalconf_L, 1);
		some_event_queue_global(SIG_CLIENT_UNFOCUS);
	}
	printstatus();

	if (!c) {
		/* With no client, all we have left is to clear focus (deferred pattern) */
		globalconf.focus.client = NULL;
		globalconf.focus.need_update = true;
		stack_windows();
		return;
	}

	/* Change cursor surface */
	motionnotify(0, NULL, 0, 0, 0, 0);

	/* Set pending focus change for AwesomeWM compatibility (Lua code may check this) */
	globalconf.focus.client = c;
	globalconf.focus.need_update = true;

	/* Trigger stack refresh: client_layer_translator() depends on which
	 * client has focus (e.g., fullscreen clients only get LyrFS when
	 * focused or when the focused client is on a different screen). */
	stack_windows();

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
#ifdef XWAYLAND
	if (c->client_type == X11) {
		surface_ready = (surface && c->scene != NULL);
	} else
#endif
	{
		surface_ready = (surface && surface->mapped);
	}

	if (surface_ready) {
#ifdef XWAYLAND
		/* Sway pattern: inform XWayland of the active seat on every focus
		 * change to an X11 client. Required for proper keyboard delivery. */
		if (c->client_type == X11)
			wlr_xwayland_set_seat(xwayland, seat);
#endif
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
		some_event_queue_property(globalconf_L, -1, SIG_FOCUS);
		lua_pop(globalconf_L, 1);
	}

	some_event_queue_global(SIG_CLIENT_FOCUS);

	/* Refresh stacking order (affects fullscreen layer) */
	stack_refresh();
}

/* We probably should change the name of this: it sounds like it
 * will focus the topmost client of this mon, when actually will
 * only return that client */
Client *
focustop(Monitor *m)
{
	foreach(c, globalconf.stack) {
		if (client_on_selected_tags(*c) && (*c)->mon == m)
			return *c;
	}
	return NULL;
}

/* Client focus functions (moved from objects/client.c) */

/** Unfocus a client (internal).
 * \param c The client.
 */
void
client_unfocus_internal(client_t *c)
{
    lua_State *L = globalconf_get_lua_State();
    globalconf.focus.client = NULL;

    luaA_object_push(L, c);

    lua_pushboolean(L, false);
    some_event_queue_signal(L, -2, SIG_PROPERTY_ACTIVE, 1);
    some_event_queue_property(L, -1, SIG_UNFOCUS);
    lua_pop(L, 1);
}

/** Unfocus a client.
 * \param c The client.
 */
void
client_unfocus(client_t *c)
{
    client_unfocus_internal(c);
    globalconf.focus.need_update = true;
}

/** Prepare banning a client by running all needed lua events.
 * \param c The client.
 */
void client_ban_unfocus(client_t *c)
{
    /* Wait until the last moment to take away the focus from the window. */
    if(globalconf.focus.client == c) {
        client_unfocus(c);
    }
}

/** Ban client and move it out of the viewport.
 * \param c The client.
 */
void
client_ban(client_t *c)
{
    if(!c->isbanned)
    {
        /* Wayland deviation: scene is created at map time, but clients are added
         * to globalconf.clients at create time (to match AwesomeWM signal timing).
         * X11's frame_window exists immediately, but our scene may not yet. */
        if(!c->scene)
            return;

        /* Wayland: hide in scene graph (equivalent to xcb_unmap_window) */
        wlr_scene_node_set_enabled(&c->scene->node, false);

        c->isbanned = true;

        client_ban_unfocus(c);
    }
}

/** This is part of The Bob Marley Algorithm: we ignore enter and leave window
 * in certain cases, like map/unmap or move, so we don't get spurious events.
 * The implementation works by noting the range of sequence numbers for which we
 * should ignore events. We grab the server to make sure that only we could
 * generate events in this range.
 */
void
client_ignore_enterleave_events(void)
{
    check(globalconf.pending_enter_leave_begin.sequence == 0);
    globalconf.pending_enter_leave_begin = xcb_grab_server(globalconf.connection);
    /* If the connection is broken, we get a request with sequence number 0
     * which would then trigger an assertion in
     * client_restore_enterleave_events(). Handle this nicely.
     */
    if(xcb_connection_has_error(globalconf.connection))
        fatal("X server connection broke (error %d)",
                xcb_connection_has_error(globalconf.connection));
    check(globalconf.pending_enter_leave_begin.sequence != 0);
}

void
client_restore_enterleave_events(void)
{
    sequence_pair_t pair;

    check(globalconf.pending_enter_leave_begin.sequence != 0);
    pair.begin = globalconf.pending_enter_leave_begin.sequence;
    pair.end = xcb_no_operation(globalconf.connection).sequence;
    xutil_ungrab_server(globalconf.connection);
    globalconf.pending_enter_leave_begin.sequence = 0;
    sequence_pair_array_append(&globalconf.ignore_enter_leave_events, pair);
}

/** Record that a client got focus.
 * \param c The client.
 * \return true if the client focus changed, false otherwise.
 */
bool
client_focus_update(client_t *c)
{
    lua_State *L = globalconf_get_lua_State();
    bool focused_new;

    if(globalconf.focus.client && globalconf.focus.client != c)
    {
        /* When we are called due to a FocusIn event (=old focused client
         * already unfocused), we don't want to cause a SetInputFocus,
         * because the client which has focus now could be using globally
         * active input model (or 'no input').
         */
        client_unfocus_internal(globalconf.focus.client);
    }

    focused_new = globalconf.focus.client != c;
    globalconf.focus.client = c;

    /* According to EWMH, we have to remove the urgent state from a client.
     * This should be done also for the current/focused client (FS#1310). */
    luaA_object_push(L, c);
    client_set_urgent(L, -1, false);

    if(focused_new) {
        lua_pushboolean(L, true);
        some_event_queue_signal(L, -2, SIG_PROPERTY_ACTIVE, 1);
        some_event_queue_property(L, -1, SIG_FOCUS);
    }

    lua_pop(L, 1);

    return focused_new;
}

/** Give focus to client, or to first client if client is NULL.
 * \param c The client.
 */
void
client_focus(client_t *c)
{
    extern void some_set_seat_keyboard_focus(client_t *c);

    /* We have to set focus on first client */
    if(!c && globalconf.clients.len && !(c = globalconf.clients.tab[0]))
        return;

    /* Update Awesome's internal focus state (borders, signals, etc.) */
    if(client_focus_update(c)) {
        globalconf.focus.need_update = true;
    }

    /* Always sync Wayland seat keyboard focus — it can desync independently
     * from Lua bookkeeping (e.g. layer surface steals keyboard, popup receives
     * keyboard enter, XWayland surface recreation). some_set_seat_keyboard_focus()
     * has its own early return when seat focus already matches (somewm_api.c). */
    some_set_seat_keyboard_focus(c);
}

/** Apply pending keyboard focus changes (AwesomeWM deferred focus pattern).
 * NOTE: Keyboard focus is now applied IMMEDIATELY in focusclient() for Wayland.
 * This function only handles clearing focus when no client is focused.
 * AwesomeWM defers focus, but Wayland surface pointers can become invalid,
 * so we apply focus immediately while the surface is guaranteed valid.
 */
void
client_focus_refresh(void)
{
    /* Early return if no focus change pending */
    if(!globalconf.focus.need_update)
        return;

    /* Only action needed: clear keyboard focus if no client is focused
     * BUT don't clear if a layer surface has exclusive focus (e.g., rofi) */
    if(!globalconf.focus.client && !some_has_exclusive_focus())
    {
        wlr_seat_keyboard_notify_clear_focus(some_get_seat());
    }

    globalconf.focus.need_update = false;
}

/** Apply pending border updates (AwesomeWM deferred border pattern for Wayland).
 * This function iterates through all clients and applies any pending border changes
 * to the wlr_scene_rect nodes if border_need_update is true.
 */
void
client_border_refresh(void)
{
    foreach(_c, globalconf.clients)
    {
        client_t *c = *_c;

        /* Check if border needs update */
        if(!c->border_need_update)
            continue;

        c->border_need_update = false;

        /* Skip if client has no scene (not yet mapped) */
        if(!c->scene || !c->border[0])
            continue;

        /* Sync wlroots border width (bw) with Lua-facing border_width */
        c->bw = c->border_width;

        /* Update border rectangle sizes based on new border width
         * Border layout: [0]=top, [1]=bottom, [2]=left, [3]=right
         * This matches the code in somewm.c:applybounds() */
        wlr_scene_rect_set_size(c->border[0], c->geometry.width, c->border_width);
        wlr_scene_rect_set_size(c->border[1], c->geometry.width, c->border_width);
        wlr_scene_rect_set_size(c->border[2], c->border_width, c->geometry.height - 2 * c->border_width);
        wlr_scene_rect_set_size(c->border[3], c->border_width, c->geometry.height - 2 * c->border_width);

        /* Update border positions (bottom and right borders depend on geometry + border width) */
        wlr_scene_node_set_position(&c->border[1]->node, 0, c->geometry.height - c->border_width);
        wlr_scene_node_set_position(&c->border[2]->node, 0, c->border_width);
        wlr_scene_node_set_position(&c->border[3]->node, c->geometry.width - c->border_width, c->border_width);

        /* Update border color if initialized (matches AwesomeWM window_border_refresh pattern) */
        if(c->border_color.initialized) {
            float color_floats[4];
            int i;

            color_to_floats(&c->border_color, color_floats);

            /* Apply color to all 4 border rectangles */
            for(i = 0; i < 4; i++)
                wlr_scene_rect_set_color(c->border[i], color_floats);
        }
    }
}

/** Apply pending geometry changes to wlroots scene graph.
 *
 * This is the Wayland equivalent of AwesomeWM's X11 client_geometry_refresh().
 * Lua layout code calculates positions via c:geometry({...}), which updates
 * c->geometry in the C struct. This function applies those changes to the
 * actual wlroots scene nodes.
 *
 * Called from client_refresh() during the refresh cycle.
 */
void
client_geometry_refresh(void)
{
    foreach(_c, globalconf.clients)
    {
        client_t *c = *_c;

        if (!c || !c->mon)
            continue;

        /* Apply c->geometry to wlroots scene graph */
        apply_geometry_to_wlroots(c);
    }
}

void
client_refresh(void)
{
    client_geometry_refresh();
    client_border_refresh();
    client_focus_refresh();
}

/** Destroy windows queued for deferred destruction (AwesomeWM pattern).
 *
 * This implements AwesomeWM's deferred window destruction to avoid race conditions
 * during Lua callbacks. Windows (X11/XWayland only) are queued during client_unmanage()
 * and destroyed here during the refresh cycle.
 *
 * For native Wayland clients, there are no X11 windows to destroy - cleanup happens
 * via wlroots scene graph and listener cleanup in destroynotify().
 */
void
client_destroy_later(void)
{
    bool ignored_enterleave = false;

    /* Early return if nothing to destroy */
    if(globalconf.destroy_later_windows.len == 0)
        return;

#ifdef XWAYLAND
    /* Only destroy if we have an X11 connection (XWayland is enabled and connected) */
    if(!globalconf.connection)
    {
        globalconf.destroy_later_windows.len = 0;
        return;
    }

    foreach(window, globalconf.destroy_later_windows)
    {
        if (!ignored_enterleave) {
            client_ignore_enterleave_events();
            ignored_enterleave = true;
        }
        xcb_destroy_window(globalconf.connection, *window);
    }
    if (ignored_enterleave)
        client_restore_enterleave_events();
#endif

    /* Everything's done, clear the list */
    globalconf.destroy_later_windows.len = 0;
}

/** Unban a client and move it back into the viewport.
 * \param c The client.
 */
void
client_unban(client_t *c)
{
    lua_State *L = globalconf_get_lua_State();
    if(c->isbanned)
    {
        /* Wayland deviation: see comment in client_ban() */
        if(!c->scene)
            return;

        /* Wayland: show in scene graph (equivalent to xcb_map_window) */
        wlr_scene_node_set_enabled(&c->scene->node, true);

        c->isbanned = false;

        /* An unbanned client shouldn't be minimized or hidden */
        luaA_object_push(L, c);
        client_set_minimized(L, -1, false);
        client_set_hidden(L, -1, false);
        lua_pop(L, 1);

        if (globalconf.focus.client == c)
            globalconf.focus.need_update = true;
    }
}
