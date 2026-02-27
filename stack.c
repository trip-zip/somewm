/*
 * stack.c - client stack management for somewm
 *
 * Manages Z-order (stacking) of windows using wlroots scene graph layers.
 * Ported from AwesomeWM's stack.c, adapted for Wayland.
 *
 * Key differences from AwesomeWM:
 * - Uses wlroots scene graph layers instead of XCB stacking
 * - No EWMH updates (TODO)
 */

#include "stack.h"
#include "somewm_types.h"
#include "objects/client.h"  /* For complete client_t definition */
#include "objects/drawin.h"  /* For drawin stacking */
#include "globalconf.h"      /* For globalconf.stack and globalconf.drawins */
#include "somewm_api.h"
#include <stdbool.h>
#include <wlr/types/wlr_scene.h>

/* Flag to mark stack as needing refresh */
static bool need_stack_refresh = false;

/* External references */
extern struct wlr_scene_tree *layers[NUM_LAYERS];

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
	/* TODO: ewmh_update_net_client_list_stacking(); */
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
	/* TODO: ewmh_update_net_client_list_stacking(); */
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
	/* TODO: ewmh_update_net_client_list_stacking(); */
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
static window_layer_t
client_layer_translator(Client *c)
{
	Client *focused;

	if (!c)
		return WINDOW_LAYER_NORMAL;

	/* First deal with user-set attributes */
	if (c->ontop)
		return WINDOW_LAYER_ONTOP;

	/* Fullscreen windows only get their own layer when they have focus */
	focused = some_get_focused_client();
	if (c->fullscreen && focused == c)
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

/*
 * Scene graph integration
 */

/** Get the wlroots scene layer for a window layer
 * Maps our logical layers to wlroots scene graph layers
 * \param layer Window layer
 * \return Scene graph layer index
 */
static int
get_scene_layer(window_layer_t layer)
{
	switch (layer) {
	case WINDOW_LAYER_DESKTOP:
		return LyrBg;
	case WINDOW_LAYER_BELOW:
		return LyrBottom;
	case WINDOW_LAYER_NORMAL:
		return LyrTile;
	case WINDOW_LAYER_ABOVE:
		return LyrTop;
	case WINDOW_LAYER_FULLSCREEN:
		return LyrFS;
	case WINDOW_LAYER_ONTOP:
		return LyrOverlay;
	case WINDOW_LAYER_IGNORE:
	case WINDOW_LAYER_COUNT:
	default:
		return LyrTile;
	}
}

/** Stack a client relative to another within the same scene layer
 * \param c Client to stack
 * \param previous Previous client (stack above this one), or NULL
 */
static void
stack_client_relative(Client *c, Client *previous)
{
	if (!c || !c->scene)
		return;

	if (previous && previous->scene) {
		/* Ensure both nodes share the same scene parent.
		 * In X11, stacking is flat (xcb_configure_window works on any two windows).
		 * In wlroots, wlr_scene_node_place_above requires shared parents.
		 * Transients should visually stack with their parent regardless of
		 * which layer they were initially placed in. */
		if (c->scene->node.parent != previous->scene->node.parent) {
			wlr_scene_node_reparent(&c->scene->node, previous->scene->node.parent);
		}
		wlr_scene_node_place_above(&c->scene->node, &previous->scene->node);
	} else {
		/* No previous client, raise to top of layer */
		wlr_scene_node_raise_to_top(&c->scene->node);
	}
}

/** Stack transient windows above their parent
 * Recursively stacks all transients above c
 * \param c Parent client
 * \param previous Last stacked window
 * \return Last stacked transient (or c if no transients)
 */
static Client *
stack_transients_above(Client *c, Client *previous)
{
	if (!c)
		return previous;

	/* Stack this client first */
	stack_client_relative(c, previous);
	previous = c;

	/* Then stack all transients above it */
	foreach(node, globalconf.stack) {
		if ((*node)->transient_for == c) {
			/* Recursively stack this transient and its transients */
			previous = stack_transients_above(*node, previous);
		}
	}

	return previous;
}

/** Refresh stacking order
 * Ported from AwesomeWM stack.c:stack_refresh (lines 162-199)
 * Applies computed stack order to wlroots scene graph
 */
void
stack_refresh(void)
{
	window_layer_t layer;
	Client *prev_in_layer[WINDOW_LAYER_COUNT];
	int scene_layer;

	if (!need_stack_refresh)
		return;

	/* Initialize previous pointers for each layer */
	for (layer = 0; layer < WINDOW_LAYER_COUNT; layer++) {
		prev_in_layer[layer] = NULL;
	}

	/* Process stack from bottom to top, organizing by layer */
	foreach(node, globalconf.stack) {
		if (!(*node) || !(*node)->scene)
			continue;

		layer = client_layer_translator(*node);

		/* Skip IGNORE layer (transients are handled with their parents) */
		if (layer == WINDOW_LAYER_IGNORE)
			continue;

		/* Move client to correct scene graph layer if needed */
		scene_layer = get_scene_layer(layer);
		/* Check if client is in wrong layer - skip the check if already correct
		 * to avoid unnecessary reparenting */
		if ((void *)(*node)->scene->node.parent != (void *)layers[scene_layer]) {
			wlr_scene_node_reparent(&(*node)->scene->node, layers[scene_layer]);
		}

		/* Stack client and its transients */
		prev_in_layer[layer] = stack_transients_above(*node, prev_in_layer[layer]);
	}

	/* Stack drawins (wiboxes) - AwesomeWM stacks these after clients
	 * Layer is determined by: ontop property AND type property (AwesomeWM compat)
	 * - type="desktop" → LyrBg (below everything, like wallpaper)
	 * - type="dock" → LyrTop (above normal windows, like panels)
	 * - ontop=true → LyrOverlay (above everything except fullscreen)
	 * - otherwise → LyrTile (same as normal clients) */
	foreach(drawin, globalconf.drawins) {
		if (!(*drawin)->scene_tree)
			continue;

		/* Determine layer based on type and ontop (AwesomeWM compatibility) */
		if ((*drawin)->type == WINDOW_TYPE_DESKTOP ||
		    (*drawin)->type == WINDOW_TYPE_SPLASH) {
			/* Desktop/splash type goes to background layer (below clients) */
			scene_layer = LyrBg;
		} else if ((*drawin)->ontop) {
			/* ontop drawins go to overlay layer */
			scene_layer = LyrOverlay;
		} else if ((*drawin)->type == WINDOW_TYPE_DOCK) {
			/* Dock type goes above normal windows */
			scene_layer = LyrTop;
		} else {
			/* Normal drawins go to wibox layer (above clients but below ontop) */
			scene_layer = LyrWibox;
		}

		/* Reparent to correct layer if needed */
		if ((void *)(*drawin)->scene_tree->node.parent != (void *)layers[scene_layer]) {
			wlr_scene_node_reparent(&(*drawin)->scene_tree->node, layers[scene_layer]);
		}

		/* Raise to top of its layer (drawins stack above clients in same layer) */
		wlr_scene_node_raise_to_top(&(*drawin)->scene_tree->node);
	}

	/* TODO: Call ewmh_update_net_client_list_stacking() */

	need_stack_refresh = false;
}
