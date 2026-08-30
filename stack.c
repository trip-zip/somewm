/*
 * stack.c - client stack management for somewm
 *
 * Maintains globalconf.stack (bottom to top) and the layer classification.
 * The declare pass (declare.c) walks both per dirty frame and expresses the
 * order as declaration order, so a stacking change is just a dirty mark;
 * ported from AwesomeWM's stack.c.
 */

#include "stack.h"
#include "declare.h"
#include "ewmh.h"
#include "somewm_types.h"
#include "objects/client.h"  /* For complete client_t definition */
#include "objects/drawin.h"  /* For drawin stacking */
#include "globalconf.h"      /* For globalconf.stack and globalconf.drawins */
#include "somewm_api.h"
#include <stdbool.h>

/* Flag to mark stack as needing refresh */
static bool need_stack_refresh = false;

/*
 * Stack management - uses globalconf.stack (matches AwesomeWM)
 */

void
stack_client_remove(Client *c)
{
	foreach(client, globalconf.stack)
		if (*client == c)
		{
			client_array_remove(&globalconf.stack, client);
			break;
		}
	stack_windows();
}

/** Push the client at the beginning of the client stack.
 * \param c The client to push.
 */
void
stack_client_push(Client *c)
{
	stack_client_remove(c);
	client_array_push(&globalconf.stack, c);
	stack_windows();
}

/** Push the client at the end of the client stack.
 * \param c The client to push.
 */
void
stack_client_append(Client *c)
{
	stack_client_remove(c);
	client_array_append(&globalconf.stack, c);
	stack_windows();
}

void
stack_windows(void)
{
	need_stack_refresh = true;
}

/*
 * Layer classification
 */

/** Get the real layer of a client according to its attributes
 * Matches AwesomeWM stack.c:client_layer_translator (lines 129-156)
 * \param c The client
 * \return The layer this client belongs in
 */
window_layer_t
stack_client_layer(Client *c)
{
	Client *focused;

	if (!c)
		return WINDOW_LAYER_NORMAL;

	/* First deal with user-set attributes */
	if (c->ontop)
		return WINDOW_LAYER_ONTOP;

	/* Fullscreen windows only get their own layer when they have focus.
	 * On Wayland, we also keep the fullscreen layer when the focused client
	 * is on a different screen, since the declare pass keeps per-band
	 * ordering (unlike X11's flat stacking model where wibars are below all
	 * clients). */
	focused = some_get_focused_client();
	if (c->fullscreen && (focused == c || !focused || focused->screen != c->screen))
		return WINDOW_LAYER_FULLSCREEN;

	if (c->above)
		return WINDOW_LAYER_ABOVE;

	if (c->below)
		return WINDOW_LAYER_BELOW;

	/* Check for transient attribute */
	if (c->transient_for)
		return WINDOW_LAYER_IGNORE;

	/* Then deal with window type */
	switch (c->type) {
	case WINDOW_TYPE_DESKTOP:
		return WINDOW_LAYER_DESKTOP;
	default:
		break;
	}

	return WINDOW_LAYER_NORMAL;
}

/* The drawin band policy (AwesomeWM compat): desktop/splash below clients
 * like wallpaper, ontop above everything but fullscreen, dock above normal
 * windows, everything else in the wibox layer. */
int
stack_drawin_layer(struct drawin_t *d)
{
	if (d->type == WINDOW_TYPE_DESKTOP || d->type == WINDOW_TYPE_SPLASH)
		return LyrBg;
	if (d->ontop)
		return LyrOverlay;
	if (d->type == WINDOW_TYPE_DOCK)
		return LyrTop;
	return LyrWibox;
}

/** Refresh stacking order
 * The declare pass reads globalconf.stack per dirty frame and the
 * reconciler restacks the scene from declaration order, so applying a stack
 * change is a dirty mark on every output plus the EWMH mirror.
 */
void
stack_refresh(void)
{
	if (!need_stack_refresh)
		return;

	declare_mark_all_dirty();
	ewmh_update_net_client_list_stacking();

	need_stack_refresh = false;
}
