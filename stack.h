/*
 * stack.h - client stack management for somewm
 *
 * Manages Z-order (stacking) of windows using wlroots scene graph layers.
 * Ported from AwesomeWM's stack.c, adapted for Wayland.
 */
#ifndef STACK_H
#define STACK_H

#include "somewm_types.h"

/* Stacking layers - matches AwesomeWM's stack.c
 * Order from bottom to top:
 * DESKTOP -> BELOW -> NORMAL -> ABOVE -> FULLSCREEN -> ONTOP
 *
 * Note: Floating is a LAYOUT concept, not a STACKING concept.
 * Floating windows go to NORMAL layer. Use c.above/c.ontop for Z-order.
 */
typedef enum {
	WINDOW_LAYER_IGNORE,      /* Special: transient windows (follow parent) */
	WINDOW_LAYER_DESKTOP,     /* Desktop windows (wallpaper) */
	WINDOW_LAYER_BELOW,       /* Below normal */
	WINDOW_LAYER_NORMAL,      /* Normal windows (tiled and floating) */
	WINDOW_LAYER_ABOVE,       /* Above normal */
	WINDOW_LAYER_FULLSCREEN,  /* Fullscreen (only when focused) */
	WINDOW_LAYER_ONTOP,       /* Always on top */
	WINDOW_LAYER_COUNT        /* Not a real layer, just for counting */
} window_layer_t;

/* Stack management functions - uses globalconf.stack (matches AwesomeWM) */

/** Push the client at the beginning of the client stack.
 * \param c The client to push.
 */
void stack_client_push(Client *c);

/** Push the client at the end of the client stack.
 * \param c The client to push.
 */
void stack_client_append(Client *c);

/** Remove client from the stack
 * \param c Client to remove
 */
void stack_client_remove(Client *c);

/** Mark stack as needing refresh
 * Actual restacking happens in stack_refresh()
 */
void stack_windows(void);

/** Refresh stacking order
 * Applies computed stack order to wlroots scene graph
 * Call after property changes (ontop, above, below, fullscreen, focus)
 */
void stack_refresh(void);

/** Get the layer a client should be in
 * \param c Client to check
 * \return Layer for this client
 */
window_layer_t client_get_layer(Client *c);

#endif /* STACK_H */
