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
#include "globalconf.h"
#include "color.h"
#include "objects/drawin.h"
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

/** Handle a systray dock request (X11-only).
 * \param win The X11 window requesting to dock.
 * \return 0 on success.
 */
int
systray_request_handle(xcb_window_t win)
{
    /* X11-only: Handles _NET_SYSTEM_TRAY_OPCODE ClientMessage.
     * Wayland uses StatusNotifierItem RegisterStatusNotifierItem. */
    (void)win;
    return 0;
}

/** Check if a window is a KDE dock app (X11-only).
 * \param win The X11 window to check.
 * \return true if window has _KDE_NET_WM_SYSTEM_TRAY_WINDOW_FOR property.
 */
bool
systray_iskdedockapp(xcb_window_t win)
{
    /* X11-only: Checks _KDE_NET_WM_SYSTEM_TRAY_WINDOW_FOR property.
     * Not applicable to Wayland StatusNotifierItem. */
    (void)win;
    return false;
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

/* Systray icon buffer wrapper for wlr_scene_buffer */
struct systray_icon_buffer {
	struct wlr_buffer base;
	void *data;
	int width;
	int height;
	size_t stride;
};

static void systray_icon_buffer_destroy(struct wlr_buffer *wlr_buffer)
{
	struct systray_icon_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	free(buffer->data);
	free(buffer);
}

static bool systray_icon_buffer_begin_data_ptr_access(
	struct wlr_buffer *wlr_buffer, uint32_t flags, void **data,
	uint32_t *format, size_t *stride)
{
	struct systray_icon_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	*data = buffer->data;
	*format = DRM_FORMAT_ARGB8888;
	*stride = buffer->stride;
	return true;
}

static void systray_icon_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer)
{
	/* Nothing to do */
}

static const struct wlr_buffer_impl systray_icon_buffer_impl = {
	.destroy = systray_icon_buffer_destroy,
	.begin_data_ptr_access = systray_icon_buffer_begin_data_ptr_access,
	.end_data_ptr_access = systray_icon_buffer_end_data_ptr_access,
};

/** Create a wlr_buffer from a cairo surface */
static struct wlr_buffer *
systray_buffer_from_cairo(cairo_surface_t *surface)
{
	struct systray_icon_buffer *buffer;
	int width, height;
	size_t stride, size;
	unsigned char *src_data;

	if (!surface || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		return NULL;

	if (cairo_image_surface_get_format(surface) != CAIRO_FORMAT_ARGB32)
		return NULL;

	width = cairo_image_surface_get_width(surface);
	height = cairo_image_surface_get_height(surface);
	stride = (size_t)cairo_image_surface_get_stride(surface);
	src_data = cairo_image_surface_get_data(surface);

	if (width <= 0 || height <= 0 || !src_data)
		return NULL;

	buffer = calloc(1, sizeof(*buffer));
	if (!buffer)
		return NULL;

	size = stride * (size_t)height;
	buffer->data = malloc(size);
	if (!buffer->data) {
		free(buffer);
		return NULL;
	}

	memcpy(buffer->data, src_data, size);
	buffer->width = width;
	buffer->height = height;
	buffer->stride = stride;

	wlr_buffer_init(&buffer->base, &systray_icon_buffer_impl, width, height);

	return &buffer->base;
}

/** Render systray icons to scene graph */
static void
systray_render_icons(drawin_t *drawin)
{
	systray_item_array_t *items;
	int i, pos_x, pos_y, idx;
	int base_size, spacing, rows;
	bool horizontal;

	if (!drawin || !drawin->scene_tree)
		return;

	items = systray_get_items();
	if (!items || items->len == 0)
		return;

	if (!globalconf.systray.scene_tree) {
		globalconf.systray.scene_tree = wlr_scene_tree_create(drawin->scene_tree);
		if (!globalconf.systray.scene_tree)
			return;
		globalconf.systray.scene_tree->node.data = drawin;
	}

	base_size = globalconf.systray.layout.base_size;
	spacing = globalconf.systray.layout.spacing;
	horizontal = globalconf.systray.layout.horizontal;
	rows = globalconf.systray.layout.rows;

	if (base_size <= 0)
		base_size = 24;
	if (rows <= 0)
		rows = 1;

	wlr_scene_node_set_position(&globalconf.systray.scene_tree->node,
	                            globalconf.systray.layout.x,
	                            globalconf.systray.layout.y);

	{
		struct wlr_scene_node *child, *tmp;
		wl_list_for_each_safe(child, tmp, &globalconf.systray.scene_tree->children, link) {
			wlr_scene_node_destroy(child);
		}
	}

	idx = 0;
	for (i = 0; i < items->len; i++) {
		systray_item_t *item = items->tab[i];
		int row, col;

		if (!item || !item->is_valid)
			continue;
		if (item->status && strcmp(item->status, "Passive") == 0)
			continue;

		if (horizontal) {
			col = idx / rows;
			row = idx % rows;
			pos_x = col * (base_size + spacing);
			pos_y = row * (base_size + spacing);
		} else {
			row = idx / rows;
			col = idx % rows;
			pos_x = col * (base_size + spacing);
			pos_y = row * (base_size + spacing);
		}

		if (item->icon) {
			struct wlr_buffer *icon_buffer = systray_buffer_from_cairo(item->icon);
			if (icon_buffer) {
				struct wlr_scene_buffer *scene_buf;
				scene_buf = wlr_scene_buffer_create(globalconf.systray.scene_tree,
				                                    icon_buffer);
				if (scene_buf) {
					wlr_scene_node_set_position(&scene_buf->node, pos_x, pos_y);
					scene_buf->node.data = drawin->drawable;
					if (item->icon_width != base_size || item->icon_height != base_size) {
						wlr_scene_buffer_set_dest_size(scene_buf, base_size, base_size);
					}
				}
				wlr_buffer_drop(icon_buffer);
			}
		} else {
			float color[4] = {0.5f, 0.5f, 0.8f, 1.0f};
			struct wlr_scene_rect *rect;
			rect = wlr_scene_rect_create(globalconf.systray.scene_tree,
			                             base_size, base_size, color);
			if (rect) {
				wlr_scene_node_set_position(&rect->node, pos_x, pos_y);
				rect->node.data = drawin->drawable;
			}
		}

		idx++;
	}
}

/** Systray kickout - remove systray from a drawin */
static void
systray_kickout(drawin_t *drawin)
{
	if (globalconf.systray.parent != drawin)
		return;

	if (globalconf.systray.scene_tree) {
		wlr_scene_node_destroy(&globalconf.systray.scene_tree->node);
		globalconf.systray.scene_tree = NULL;
	}

	globalconf.systray.parent = NULL;
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
		if (globalconf.systray.parent)
			systray_kickout(globalconf.systray.parent);
		globalconf.systray.parent = drawin;
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

	systray_render_icons(drawin);

	lua_pushinteger(L, systray_count_visible());
	luaA_object_push(L, drawin);
	return 2;
}
