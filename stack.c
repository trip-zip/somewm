/*
 * stack.c - client stack management for somewm
 *
 * Manages Z-order (stacking) of windows using wlroots scene graph layers.
 * Ported from AwesomeWM's stack.c (lines 1-203), adapted for Wayland.
 *
 * Key differences from AwesomeWM:
 * - Uses wlroots scene graph layers instead of XCB stacking
 * - No EWMH updates
 */

#include "stack.h"
#include "somewm_types.h"
#include "objects/client.h"  /* For complete client_t definition */
#include "objects/drawin.h"  /* For drawin stacking */
#include "globalconf.h"      /* For globalconf.drawins */
#include "somewm_api.h"
#include "util.h"
#include <stdlib.h>
#include <stdbool.h>
#include <wlr/types/wlr_scene.h>

/* Global client stack - ordered from bottom to top */
static Client **stack = NULL;
static size_t stack_len = 0;
static size_t stack_capacity = 0;

/* Flag to mark stack as needing refresh */
static bool need_stack_refresh = false;

/* External references */
extern struct wlr_scene_tree *layers[NUM_LAYERS];

/*
 * Stack array management
 */

void
stack_init(void)
{
	stack_capacity = 32;  /* Initial capacity */
	stack = ecalloc(stack_capacity, sizeof(Client *));
	stack_len = 0;
	need_stack_refresh = false;
}

void
stack_cleanup(void)
{
	if (stack) {
		free(stack);
		stack = NULL;
	}
	stack_len = 0;
	stack_capacity = 0;
}

/** Find client in stack
 * \param c Client to find
 * \return Index in stack, or -1 if not found
 */
static int
stack_find(Client *c)
{
	size_t i;

	for (i = 0; i < stack_len; i++) {
		if (stack[i] == c)
			return (int)i;
	}
	return -1;
}

/** Remove client from stack without refresh
 * \param c Client to remove
 */
static void
stack_remove_internal(Client *c)
{
	int idx;
	size_t i;

	idx = stack_find(c);
	if (idx < 0)
		return;

	/* Shift elements down */
	for (i = (size_t)idx; i < stack_len - 1; i++) {
		stack[i] = stack[i + 1];
	}
	stack_len--;
}

void
stack_client_remove(Client *c)
{
	stack_remove_internal(c);
	/* TODO: ewmh_update_net_client_list_stacking(); */
	stack_windows();
}

void
stack_client_push(Client *c)
{
	size_t i;

	/* Remove if already in stack */
	stack_remove_internal(c);

	/* Grow array if needed */
	if (stack_len >= stack_capacity) {
		stack_capacity *= 2;
		stack = realloc(stack, stack_capacity * sizeof(Client *));
		if (!stack)
			die("stack_client_push: realloc failed");
	}

	/* Shift all elements up to make room at beginning */
	for (i = stack_len; i > 0; i--) {
		stack[i] = stack[i - 1];
	}

	/* Add to beginning (bottom of stack) - matches AwesomeWM */
	stack[0] = c;
	stack_len++;

	/* TODO: ewmh_update_net_client_list_stacking(); */
	stack_windows();
}

void
stack_client_append(Client *c)
{
	/* Remove if already in stack */
	stack_remove_internal(c);

	/* Grow array if needed */
	if (stack_len >= stack_capacity) {
		stack_capacity *= 2;
		stack = realloc(stack, stack_capacity * sizeof(Client *));
		if (!stack)
			die("stack_client_append: realloc failed");
	}

	/* Add to end (top of stack) - matches AwesomeWM */
	stack[stack_len++] = c;

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
 * Ported from AwesomeWM stack.c:client_layer_translator (lines 129-156)
 * \param c The client
 * \return The layer this client belongs in
 */
window_layer_t
client_get_layer(Client *c)
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
		/* Return LyrTile for now; floating is handled elsewhere */
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
		/* Place this client above the previous one */
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
	size_t i;
	Client *transient;

	if (!c)
		return previous;

	/* Stack this client first */
	stack_client_relative(c, previous);
	previous = c;

	/* Then stack all transients above it */
	for (i = 0; i < stack_len; i++) {
		transient = stack[i];
		if (transient->transient_for == c) {
			/* Recursively stack this transient and its transients */
			previous = stack_transients_above(transient, previous);
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
	size_t i;
	Client *c;
	Client *prev_in_layer[WINDOW_LAYER_COUNT];
	int scene_layer;

	if (!need_stack_refresh)
		return;

	/* Initialize previous pointers for each layer */
	for (layer = 0; layer < WINDOW_LAYER_COUNT; layer++) {
		prev_in_layer[layer] = NULL;
	}

	/* Process stack from bottom to top, organizing by layer */
	for (i = 0; i < stack_len; i++) {
		c = stack[i];
		if (!c || !c->scene)
			continue;

		layer = client_get_layer(c);

		/* Skip IGNORE layer (transients are handled with their parents) */
		if (layer == WINDOW_LAYER_IGNORE)
			continue;

		/* Move client to correct scene graph layer if needed */
		scene_layer = get_scene_layer(layer);
		/* Check if client is in wrong layer - skip the check if already correct
		 * to avoid unnecessary reparenting */
		if ((void *)c->scene->node.parent != (void *)layers[scene_layer]) {
			wlr_scene_node_reparent(&c->scene->node, layers[scene_layer]);
		}

		/* Stack client and its transients */
		prev_in_layer[layer] = stack_transients_above(c, prev_in_layer[layer]);
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
