/*
 * stack.h - client stack management for somewm
 *
 * Manages Z-order (stacking) of windows using wlroots scene graph layers.
 * Ported from AwesomeWM's stack.c, adapted for Wayland.
 */
#ifndef STACK_H
#define STACK_H

#include "somewm_types.h"

/* Stacking layers - maps to wlroots scene graph layers
 * Order from bottom to top:
 * DESKTOP -> BELOW -> NORMAL -> ABOVE -> FULLSCREEN -> ONTOP
 */
typedef enum {
	WINDOW_LAYER_IGNORE,      /* Special: transient windows (follow parent) */
	WINDOW_LAYER_DESKTOP,     /* Desktop windows (wallpaper) -> LyrBg */
	WINDOW_LAYER_BELOW,       /* Below normal -> LyrBottom */
	WINDOW_LAYER_NORMAL,      /* Tiled windows -> LyrTile */
	WINDOW_LAYER_FLOATING,    /* Floating windows -> LyrFloat */
	WINDOW_LAYER_ABOVE,       /* Above normal (panels, docks) -> LyrTop */
	WINDOW_LAYER_FULLSCREEN,  /* Fullscreen (only when focused) -> LyrFS */
	WINDOW_LAYER_ONTOP,       /* Always on top -> LyrOverlay */
	WINDOW_LAYER_COUNT        /* Not a real layer, just for counting */
} window_layer_t;

/* Stack management functions */

/** Initialize the stacking system
 * Call once at compositor startup
 */
void stack_init(void);

/** Cleanup the stacking system
 * Call once at compositor shutdown
 */
void stack_cleanup(void);

/** Add client to the top of the stack
 * \param c Client to add
 */
void stack_client_push(Client *c);

/** Add client to the bottom of the stack
 * \param c Client to add
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
