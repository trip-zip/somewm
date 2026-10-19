/*
 * xkb.c - keyboard layout control functions
 *
 * Copyright © 2015 Aleksey Fedotov <lexa@cfotr.com>
 * Copyright © 2024 somewm contributors
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

/**
 * @module awesome
 */

#include "xkb.h"
#include "globalconf.h"
#include "luaa.h"
#include "event_queue.h"

#include <glib.h>
#include <stdbool.h>
#include <xkbcommon/xkbcommon.h>

/* Forward declaration for signal emission */
void luaA_emit_signal_global(const char *name);

/* Deferred XKB signal emission (matches AwesomeWM's xkb_refresh pattern) */
static guint xkb_refresh_source_id;

static gboolean
xkb_refresh(gpointer unused)
{
    (void)unused;
    xkb_refresh_source_id = 0;
    globalconf.xkb.update_pending = false;

    if (globalconf.xkb.map_changed)
        some_event_queue_global(SIG_XKB_MAP_CHANGED);

    if (globalconf.xkb.group_changed)
        some_event_queue_global(SIG_XKB_GROUP_CHANGED);

    globalconf.xkb.map_changed = false;
    globalconf.xkb.group_changed = false;

    return G_SOURCE_REMOVE;
}

static void
xkb_schedule_refresh(void)
{
    if (globalconf.xkb.update_pending)
        return;
    globalconf.xkb.update_pending = true;
    xkb_refresh_source_id = g_idle_add_full(G_PRIORITY_LOW, xkb_refresh, NULL, NULL);
}

/** Drop a pending refresh at a Lua state swap.
 *
 * The idle is attached at runtime, so it sits above the GLib source baseline
 * the reload sweep works from, and it is not one of the two sources that can be
 * protected from it. Left to the sweep, the idle dies with update_pending still
 * set and every later xkb_schedule_refresh() early-returns for the rest of the
 * process: no xkb::map_changed, no xkb::group_changed, ever again. The pending
 * signals are dropped with it, which is right - they belong to the state being
 * torn down.
 */
void
xkb_reset_pending(void)
{
    if (xkb_refresh_source_id) {
        g_source_remove(xkb_refresh_source_id);
        xkb_refresh_source_id = 0;
    }
    globalconf.xkb.update_pending = false;
    globalconf.xkb.map_changed = false;
    globalconf.xkb.group_changed = false;
}

/*
 * somewm Wayland-specific functions
 */

void
xkb_schedule_group_changed(void)
{
    globalconf.xkb.group_changed = true;
    xkb_schedule_refresh();
}

void
xkb_schedule_map_changed(void)
{
    globalconf.xkb.map_changed = true;
    xkb_schedule_refresh();
}
