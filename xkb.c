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

#include "xkb.h"
#include "globalconf.h"
#include "luaa.h"

#include <glib.h>

/* Forward declaration for signal emission */
void luaA_emit_signal_global(const char *name);

/* Deferred XKB signal emission (matches AwesomeWM's xkb_refresh pattern) */
static gboolean
xkb_refresh(gpointer unused)
{
	globalconf.xkb.update_pending = false;

	if (globalconf.xkb.map_changed)
		luaA_emit_signal_global("xkb::map_changed");

	if (globalconf.xkb.group_changed)
		luaA_emit_signal_global("xkb::group_changed");

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
	g_idle_add_full(G_PRIORITY_LOW, xkb_refresh, NULL, NULL);
}

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
