/*
 * focus.h - Focus policy for somewm compositor
 *
 * Client focus, activation, stacking order updates.
 */
#ifndef FOCUS_H
#define FOCUS_H

#include "somewm_types.h"

void focusclient(Client *c, int lift);
Client *focustop(Monitor *m);
void focus_restore(Monitor *m);

#endif /* FOCUS_H */
