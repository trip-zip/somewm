/*
 * systray.c - systray handling
 *
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
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

#include "systray.h"
#include "widget.h"
#include "globalconf.h"
#include "color.h"
#include "objects/drawin.h"
#include "objects/drawable.h"
#include "objects/systray.h"
#include "common/luaobject.h"

#include <string.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <drm_fourcc.h>
#include <cairo/cairo.h>

/** Initialize the systray (X11-only).
 * X11: Creates systray manager window, acquires _NET_SYSTEM_TRAY_Sn selection.
 * Wayland: Systray uses StatusNotifierItem protocol instead.
 */
void
systray_init(void)
{
    /* X11-only: xcb_create_window, xcb_set_selection_owner.
     * Wayland systray is initialized in systray_class_setup. */
}

/** Cleanup the systray (X11-only).
 * X11: Destroys systray window, releases selection.
 * Wayland: Cleanup handled by D-Bus disconnect.
 */
void
systray_cleanup(void)
{
    /* X11-only: xcb_destroy_window.
     * Wayland cleanup happens in globalconf teardown. */
}

/** Process systray client messages (X11-only).
 * \param ev The client message event.
 * \return 0 on success.
 */
int
systray_process_client_message(xcb_client_message_event_t *ev)
{
    /* X11-only: Handles _NET_SYSTEM_TRAY_OPCODE messages.
     * Wayland uses D-Bus StatusNotifierItem interface. */
    (void)ev;
    return 0;
}

/** Process XEMBED client messages (X11-only).
 * \param ev The client message event.
 * \return 0 on success.
 */
int
xembed_process_client_message(xcb_client_message_event_t *ev)
{
    /* X11-only: Handles _XEMBED messages for embedded systray icons.
     * Wayland StatusNotifierItem doesn't use embedding. */
    (void)ev;
    return 0;
}

/** Helper to count visible systray entries */
static int
systray_count_visible(void)
{
	systray_item_array_t *items = systray_get_items();
	int count = 0;
	int i;

	if (!items)
		return 0;

	for (i = 0; i < items->len; i++) {
		systray_item_t *item = items->tab[i];
		if (item && item->is_valid) {
			if (!item->status || strcmp(item->status, "Passive") != 0)
				count++;
		}
	}
	return count;
}

/** Paint the visible tray icons into the hosting drawin's content pixels.
 * Called from drawin_refresh_drawable() after the widget pixels landed in
 * the content entry, so the icons sit on top exactly where the old scene
 * overlay stacked them. target holds device pixels with no device scale
 * set, so every coordinate scales by the drawable's surface scale. */
void
systray_composite(drawin_t *drawin, cairo_surface_t *target)
{
	systray_item_array_t *items;
	cairo_t *cr;
	int i, idx;
	int base_size, spacing, rows;
	bool horizontal;
	float scale;

	if (!drawin || drawin != globalconf.systray.parent)
		return;

	items = systray_get_items();
	if (!items || items->len == 0)
		return;

	base_size = globalconf.systray.layout.base_size;
	spacing = globalconf.systray.layout.spacing;
	horizontal = globalconf.systray.layout.horizontal;
	rows = globalconf.systray.layout.rows;

	if (base_size <= 0)
		base_size = 24;
	if (rows <= 0)
		rows = 1;
	scale = drawin->drawable && drawin->drawable->surface_scale > 0
		? drawin->drawable->surface_scale : 1.0f;

	cr = cairo_create(target);
	cairo_scale(cr, scale, scale);
	cairo_translate(cr, globalconf.systray.layout.x,
	                globalconf.systray.layout.y);

	idx = 0;
	for (i = 0; i < items->len; i++) {
		systray_item_t *item = items->tab[i];
		int row, col, pos_x, pos_y;

		if (!item || !item->is_valid)
			continue;
		if (item->status && strcmp(item->status, "Passive") == 0)
			continue;

		if (horizontal) {
			col = idx / rows;
			row = idx % rows;
		} else {
			row = idx / rows;
			col = idx % rows;
		}
		pos_x = col * (base_size + spacing);
		pos_y = row * (base_size + spacing);

		cairo_save(cr);
		cairo_translate(cr, pos_x, pos_y);
		if (item->icon
				&& cairo_surface_status(item->icon) == CAIRO_STATUS_SUCCESS
				&& item->icon_width > 0 && item->icon_height > 0) {
			cairo_scale(cr, (double)base_size / item->icon_width,
			            (double)base_size / item->icon_height);
			cairo_set_source_surface(cr, item->icon, 0, 0);
			cairo_paint(cr);
		} else {
			/* No icon yet: the old path's placeholder tile */
			cairo_set_source_rgba(cr, 0.5, 0.5, 0.8, 1.0);
			cairo_rectangle(cr, 0, 0, base_size, base_size);
			cairo_fill(cr);
		}
		cairo_restore(cr);

		idx++;
	}
	cairo_destroy(cr);
}

/** Systray kickout - remove systray from a drawin */
static void
systray_kickout(drawin_t *drawin)
{
	if (globalconf.systray.parent != drawin)
		return;

	globalconf.systray.parent = NULL;
	/* The icons are baked into the old parent's content entry. Repaint it
	 * now: systray_composite() is a no-op for it from here, so the widget
	 * pixels land without them. Waiting for an unrelated redraw leaves the
	 * tray drawn in two places. */
	drawin_refresh_drawable(drawin);
}

/** awesome.systray() - Manage the system tray */
int
luaA_systray(lua_State *L)
{
	int nargs = lua_gettop(L);
	drawin_t *drawin;
	int x, y, base_size, spacing, rows;
	bool horizontal, reverse;
	const char *bg_color;
	color_t bg;

	if (nargs == 0) {
		lua_pushinteger(L, systray_count_visible());
		if (globalconf.systray.parent)
			luaA_object_push(L, globalconf.systray.parent);
		else
			lua_pushnil(L);
		return 2;
	}

	drawin = luaA_todrawin(L, 1);
	if (!drawin) {
		lua_pushinteger(L, systray_count_visible());
		lua_pushnil(L);
		return 2;
	}

	if (nargs == 1) {
		systray_kickout(drawin);
		widget_nodes_gate(L, drawin, 1);
		lua_pushinteger(L, systray_count_visible());
		lua_pushnil(L);
		return 2;
	}

	x = luaL_checkinteger(L, 2);
	y = luaL_checkinteger(L, 3);
	base_size = luaL_checkinteger(L, 4);
	horizontal = lua_toboolean(L, 5);
	bg_color = luaL_optstring(L, 6, "#000000");
	reverse = lua_toboolean(L, 7);
	spacing = luaL_optinteger(L, 8, 0);
	rows = luaL_optinteger(L, 9, 1);

	if (globalconf.systray.parent != drawin) {
		drawin_t *old = globalconf.systray.parent;

		if (old)
			systray_kickout(old);
		globalconf.systray.parent = drawin;
		/* The host paints itself whole (widget.c); the tree is refused
		 * on the new one and allowed again on the old. */
		if (old)
			widget_nodes_gate(L, old, 0);
		widget_nodes_gate(L, drawin, 1);
	}

	if (color_init_from_string(&bg, bg_color)) {
		globalconf.systray.background_pixel =
			((uint32_t)(bg.alpha * 255) << 24) |
			((uint32_t)(bg.red * 255) << 16) |
			((uint32_t)(bg.green * 255) << 8) |
			((uint32_t)(bg.blue * 255));
	}

	globalconf.systray.layout.x = x;
	globalconf.systray.layout.y = y;
	globalconf.systray.layout.base_size = base_size;
	globalconf.systray.layout.horizontal = horizontal;
	globalconf.systray.layout.reverse = reverse;
	globalconf.systray.layout.spacing = spacing;
	globalconf.systray.layout.rows = rows > 0 ? rows : 1;

	/* Layout recorded; the icons composite into the drawin content entry
	 * on its next drawable refresh, which the widget draw that called us
	 * triggers. */

	lua_pushinteger(L, systray_count_visible());
	luaA_object_push(L, drawin);
	return 2;
}
