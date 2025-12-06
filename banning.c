/*
 * banning.c - client banning/visibility management
 *
 * Implementation for somewm (Wayland compositor)
 * Based on AwesomeWM's banning.c
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 */

#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_scene.h>

#include "banning.h"
#include "globalconf.h"
#include "objects/client.h"

/* Declare seat extern before including client.h */
extern struct wlr_seat *seat;

#include "client.h"  /* For client_set_suspended */

/** Mark that client visibility needs to be refreshed.
 *
 * This sets a flag that will be checked in the main event loop.
 * Also preemptively unfocuses clients that will become invisible
 * to prevent focus artifacts.
 */
void
banning_need_update(void)
{
    client_t *c;
    bool visible;

    globalconf.need_lazy_banning = true;

    /* Preemptive unfocus: immediately unfocus clients that will be hidden */
    foreach(item, globalconf.clients) {
        c = *item;
        if (!c || !c->mon)
            continue;

        /* Check if client will be invisible */
        visible = !c->hidden && !c->minimized && client_on_selected_tags(c);

        /* If focused client will become invisible, unfocus it now */
        if (!visible && c == globalconf.focus.client) {
            client_ban_unfocus(c);
        }
    }
}

/** Refresh client visibility for all clients.
 *
 * This implements the two-phase visibility update from AwesomeWM:
 * Phase 1: Unban (show) all visible clients
 * Phase 2: Ban (hide) all invisible clients
 *
 * The order prevents flicker during tag switches.
 */
void
banning_refresh(void)
{
    client_t *c;
    bool visible;

    if (!globalconf.need_lazy_banning)
        return;

    /* Phase 1: Unban all visible clients first (prevents flicker) */
    foreach(item, globalconf.clients) {
        c = *item;
        if (!c || !c->mon)
            continue;

        /* Check visibility: not hidden, not minimized, on selected tags */
        visible = !c->hidden && !c->minimized && client_on_selected_tags(c);

        if (visible && c->isbanned) {
            /* Make visible in scene graph */
            wlr_scene_node_set_enabled(&c->scene->node, true);
            client_set_suspended(c, false);
            c->isbanned = false;

            /* Clear minimized/hidden flags when unbanning */
            c->minimized = false;
            c->hidden = false;
        }
    }

    /* Phase 2: Ban all invisible clients */
    foreach(item, globalconf.clients) {
        c = *item;
        if (!c || !c->mon)
            continue;

        visible = !c->hidden && !c->minimized && client_on_selected_tags(c);

        if (!visible && !c->isbanned) {
            /* Hide from scene graph */
            wlr_scene_node_set_enabled(&c->scene->node, false);
            client_set_suspended(c, true);
            c->isbanned = true;

            /* Unfocus if this was the focused client */
            if (c == globalconf.focus.client) {
                client_ban_unfocus(c);
            }
        }
    }

    globalconf.need_lazy_banning = false;
}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
