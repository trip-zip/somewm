/*
 * focus.h - Focus policy for somewm compositor
 *
 * Client focus, activation, stacking order, banning, refresh cycle.
 */
#ifndef FOCUS_H
#define FOCUS_H

#include "somewm_types.h"
#include <stdbool.h>

struct wlr_surface;

/* Main focus functions (from somewm.c) */
void focusclient(Client *c, int lift);
Client *focustop(Monitor *m);
void focus_restore(Monitor *m);
void some_update_pointer_constraint(struct wlr_surface *surface);

/* Client focus functions (from objects/client.c) */
void client_unfocus_internal(client_t *c);
void client_unfocus(client_t *c);
void client_ban_unfocus(client_t *c);
void client_ban(client_t *c);
void client_unban(client_t *c);
void client_ignore_enterleave_events(void);
void client_restore_enterleave_events(void);
bool client_focus_update(client_t *c);
void client_focus(client_t *c);
void client_focus_refresh(void);
void client_border_refresh(void);
void client_geometry_refresh(void);
void client_refresh(void);
void client_destroy_later(void);

#endif /* FOCUS_H */
