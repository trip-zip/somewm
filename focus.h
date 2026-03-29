/*
 * focus.h - Focus policy for somewm compositor
 *
 * Client focus, activation, stacking order updates.
 */
#ifndef FOCUS_H
#define FOCUS_H

#include "somewm_types.h"

struct wlr_surface;

void focusclient(Client *c, int lift);
Client *focustop(Monitor *m);
void focus_restore(Monitor *m);
void some_update_pointer_constraint(struct wlr_surface *surface);

#endif /* FOCUS_H */
