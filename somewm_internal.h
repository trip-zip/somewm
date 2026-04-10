/*
 * somewm_internal.h - Coordinator functions defined in somewm.c
 *
 * Functions that live in somewm.c but are called from extracted modules
 * (input.c, window.c, focus.c, monitor.c, protocols.c, xwayland.c).
 *
 * For compositor globals (wlr_seat, cursor, etc.), see somewm.h.
 * For the public Lua-facing API, see somewm_api.h.
 */
#ifndef SOMEWM_INTERNAL_H
#define SOMEWM_INTERNAL_H

#include "somewm_types.h"

struct wlr_surface;

/* Status bar update (IPC/Lua) */
void printstatus(void);

/* Process spawning */
void spawn(const Arg *arg);

/* Idle inhibition coordinator (checks wlroots + Lua inhibitors, emits signals) */
void some_recompute_idle_inhibit(struct wlr_surface *exclude);

/* Convert cursor position to client-relative coordinates */
void cursor_to_client_coordinates(Client *client, double *sx, double *sy);

/* Drag-and-drop source client (set in requeststartdrag, cleared in destroydrag) */
extern Client *drag_source_client;

#endif /* SOMEWM_INTERNAL_H */
