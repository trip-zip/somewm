/*
 * systray.c - StatusNotifierItem (SNI) systray support
 *
 * Implements a first-class widget approach where each tray icon
 * is a proper Lua object that can be styled individually.
 *
 * Copyright © 2024 somewm contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "systray.h"
#include "luaa.h"
#include "signal.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "../globalconf.h"
#include "../util.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* Systray item class */
lua_class_t systray_item_class;

/* Global array of all systray items */
static systray_item_array_t systray_items;
static bool systray_initialized = false;

/* Generate systray_item_new(), luaA_systray_item_gc(), etc. via LUA_OBJECT_FUNCS macro */
LUA_OBJECT_FUNCS(systray_item_class, systray_item_t, systray_item)

/* Array functions with custom destructor */
static void systray_item_ptr_wipe(systray_item_t **item) {
	/* Items are ref-counted by Lua, don't free here */
	(void)item;
}

ARRAY_FUNCS(systray_item_t *, systray_item, systray_item_ptr_wipe)

/**
 * Wipe a systray_item when it's garbage collected
 */
static void
systray_item_wipe(systray_item_t *item)
{
	p_delete(&item->bus_name);
	p_delete(&item->object_path);
	p_delete(&item->id);
	p_delete(&item->title);
	p_delete(&item->status);
	p_delete(&item->category);
	p_delete(&item->icon_name);
	p_delete(&item->attention_icon_name);
	p_delete(&item->tooltip_title);
	p_delete(&item->tooltip_body);
	p_delete(&item->tooltip_icon_name);
	p_delete(&item->menu_path);
	p_delete(&item->icon_theme_path);

	if (item->icon) {
		cairo_surface_destroy(item->icon);
		item->icon = NULL;
	}
	if (item->attention_icon) {
		cairo_surface_destroy(item->attention_icon);
		item->attention_icon = NULL;
	}
	p_delete(&item->overlay_icon_name);
	if (item->overlay_icon) {
		cairo_surface_destroy(item->overlay_icon);
		item->overlay_icon = NULL;
	}
}

/* ========================================================================
 * Property Getters
 * ======================================================================== */

static int
luaA_systray_item_get_id(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->id ? item->id : "");
	return 1;
}

static int
luaA_systray_item_get_title(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->title ? item->title : "");
	return 1;
}

static int
luaA_systray_item_get_app_name(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->app_name ? item->app_name : "");
	return 1;
}

static int
luaA_systray_item_get_status(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->status ? item->status : "Active");
	return 1;
}

static int
luaA_systray_item_get_category(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->category ? item->category : "ApplicationStatus");
	return 1;
}

static int
luaA_systray_item_get_icon_name(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->icon_name ? item->icon_name : "");
	return 1;
}

static int
luaA_systray_item_get_attention_icon_name(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->attention_icon_name ? item->attention_icon_name : "");
	return 1;
}

static int
luaA_systray_item_get_attention_icon(lua_State *L, systray_item_t *item)
{
	if (item->attention_icon) {
		lua_pushlightuserdata(L, item->attention_icon);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int
luaA_systray_item_get_overlay_icon_name(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->overlay_icon_name ? item->overlay_icon_name : "");
	return 1;
}

static int
luaA_systray_item_get_overlay_icon(lua_State *L, systray_item_t *item)
{
	if (item->overlay_icon) {
		lua_pushlightuserdata(L, item->overlay_icon);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int
luaA_systray_item_get_icon(lua_State *L, systray_item_t *item)
{
	if (item->icon) {
		/* Push cairo surface as light userdata for now
		 * TODO: Wrap in proper lgi cairo surface object */
		lua_pushlightuserdata(L, item->icon);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int
luaA_systray_item_get_icon_width(lua_State *L, systray_item_t *item)
{
	lua_pushinteger(L, item->icon_width);
	return 1;
}

static int
luaA_systray_item_get_icon_height(lua_State *L, systray_item_t *item)
{
	lua_pushinteger(L, item->icon_height);
	return 1;
}

static int
luaA_systray_item_get_tooltip_title(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->tooltip_title ? item->tooltip_title : "");
	return 1;
}

static int
luaA_systray_item_get_tooltip_body(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->tooltip_body ? item->tooltip_body : "");
	return 1;
}

static int
luaA_systray_item_get_bus_name(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->bus_name ? item->bus_name : "");
	return 1;
}

static int
luaA_systray_item_get_object_path(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->object_path ? item->object_path : "");
	return 1;
}

static int
luaA_systray_item_get_menu_path(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->menu_path ? item->menu_path : "");
	return 1;
}

static int
luaA_systray_item_get_icon_theme_path(lua_State *L, systray_item_t *item)
{
	lua_pushstring(L, item->icon_theme_path ? item->icon_theme_path : "");
	return 1;
}

static int
luaA_systray_item_set_icon_theme_path(lua_State *L, systray_item_t *item)
{
	const char *path = luaL_checkstring(L, -1);
	p_delete(&item->icon_theme_path);
	item->icon_theme_path = a_strdup(path);
	return 0;
}

static int
luaA_systray_item_get_item_is_menu(lua_State *L, systray_item_t *item)
{
	lua_pushboolean(L, item->item_is_menu);
	return 1;
}

static int
luaA_systray_item_set_item_is_menu(lua_State *L, systray_item_t *item)
{
	item->item_is_menu = lua_toboolean(L, -1);
	return 0;
}

static int
luaA_systray_item_get_is_valid(lua_State *L, systray_item_t *item)
{
	lua_pushboolean(L, item->is_valid);
	return 1;
}

/* ========================================================================
 * Property Setters (internal use - properties set from D-Bus callbacks)
 * ======================================================================== */

static int
luaA_systray_item_set_title(lua_State *L, systray_item_t *item)
{
	const char *title = luaL_checkstring(L, -1);
	p_delete(&item->title);
	item->title = a_strdup(title);
	luaA_object_emit_signal(L, -3, "property::title", 0);
	return 0;
}

static int
luaA_systray_item_set_app_name(lua_State *L, systray_item_t *item)
{
	const char *app_name = luaL_checkstring(L, -1);
	p_delete(&item->app_name);
	item->app_name = a_strdup(app_name);
	luaA_object_emit_signal(L, -3, "property::app_name", 0);
	return 0;
}

static int
luaA_systray_item_set_status(lua_State *L, systray_item_t *item)
{
	const char *status = luaL_checkstring(L, -1);
	p_delete(&item->status);
	item->status = a_strdup(status);
	luaA_object_emit_signal(L, -3, "property::status", 0);
	return 0;
}

static int
luaA_systray_item_set_icon_name(lua_State *L, systray_item_t *item)
{
	const char *icon_name = luaL_checkstring(L, -1);
	p_delete(&item->icon_name);
	item->icon_name = a_strdup(icon_name);
	luaA_object_emit_signal(L, -3, "property::icon_name", 0);
	luaA_object_emit_signal(L, -3, "property::icon", 0);
	return 0;
}

static int
luaA_systray_item_set_attention_icon_name(lua_State *L, systray_item_t *item)
{
	const char *icon_name = luaL_checkstring(L, -1);
	p_delete(&item->attention_icon_name);
	item->attention_icon_name = a_strdup(icon_name);
	luaA_object_emit_signal(L, -3, "property::attention_icon_name", 0);
	return 0;
}

static int
luaA_systray_item_set_overlay_icon_name(lua_State *L, systray_item_t *item)
{
	const char *icon_name = luaL_checkstring(L, -1);
	p_delete(&item->overlay_icon_name);
	item->overlay_icon_name = a_strdup(icon_name);
	luaA_object_emit_signal(L, -3, "property::overlay_icon_name", 0);
	luaA_object_emit_signal(L, -3, "property::overlay_icon", 0);
	return 0;
}

/* D-Bus identification property setters - used by Lua systray watcher */
static int
luaA_systray_item_set_bus_name(lua_State *L, systray_item_t *item)
{
	const char *bus_name = luaL_checkstring(L, -1);
	p_delete(&item->bus_name);
	item->bus_name = a_strdup(bus_name);
	return 0;
}

static int
luaA_systray_item_set_object_path(lua_State *L, systray_item_t *item)
{
	const char *object_path = luaL_checkstring(L, -1);
	p_delete(&item->object_path);
	item->object_path = a_strdup(object_path);
	return 0;
}

static int
luaA_systray_item_set_id(lua_State *L, systray_item_t *item)
{
	const char *id = luaL_checkstring(L, -1);
	p_delete(&item->id);
	item->id = a_strdup(id);
	return 0;
}

static int
luaA_systray_item_set_category(lua_State *L, systray_item_t *item)
{
	const char *category = luaL_checkstring(L, -1);
	p_delete(&item->category);
	item->category = a_strdup(category);
	return 0;
}

static int
luaA_systray_item_set_menu_path(lua_State *L, systray_item_t *item)
{
	const char *menu_path = luaL_checkstring(L, -1);
	p_delete(&item->menu_path);
	item->menu_path = a_strdup(menu_path);
	return 0;
}

/* ========================================================================
 * Methods - Lua callable functions
 * ======================================================================== */

/**
 * Activate the item (primary click action)
 * Lua: item:activate(x, y)
 *
 * This will call the D-Bus Activate method on the StatusNotifierItem.
 * The actual D-Bus call is handled in Lua using lgi.Gio.
 */
static int
luaA_systray_item_activate(lua_State *L)
{
	int x, y;

	luaA_checkudata(L, 1, &systray_item_class);
	x = luaL_optinteger(L, 2, 0);
	y = luaL_optinteger(L, 3, 0);

	/* Emit signal that Lua D-Bus code will handle */
	lua_pushinteger(L, x);
	lua_pushinteger(L, y);
	luaA_object_emit_signal(L, 1, "request::activate", 2);

	return 0;
}

/**
 * Secondary activate (middle click action)
 * Lua: item:secondary_activate(x, y)
 */
static int
luaA_systray_item_secondary_activate(lua_State *L)
{
	int x, y;

	luaA_checkudata(L, 1, &systray_item_class);
	x = luaL_optinteger(L, 2, 0);
	y = luaL_optinteger(L, 3, 0);

	lua_pushinteger(L, x);
	lua_pushinteger(L, y);
	luaA_object_emit_signal(L, 1, "request::secondary_activate", 2);

	return 0;
}

/**
 * Show context menu (right click action)
 * Lua: item:context_menu(x, y)
 */
static int
luaA_systray_item_context_menu(lua_State *L)
{
	int x, y;

	luaA_checkudata(L, 1, &systray_item_class);
	x = luaL_optinteger(L, 2, 0);
	y = luaL_optinteger(L, 3, 0);

	lua_pushinteger(L, x);
	lua_pushinteger(L, y);
	luaA_object_emit_signal(L, 1, "request::context_menu", 2);

	return 0;
}

/**
 * Handle scroll event
 * Lua: item:scroll(delta, orientation)
 * orientation: "vertical" or "horizontal"
 */
static int
luaA_systray_item_scroll(lua_State *L)
{
	int delta;
	const char *orientation;

	luaA_checkudata(L, 1, &systray_item_class);
	delta = luaL_checkinteger(L, 2);
	orientation = luaL_optstring(L, 3, "vertical");

	lua_pushinteger(L, delta);
	lua_pushstring(L, orientation);
	luaA_object_emit_signal(L, 1, "request::scroll", 2);

	return 0;
}

/**
 * Set attention icon from ARGB32 pixmap data (Lua-callable)
 * Lua: item:set_attention_pixmap(width, height, data_string)
 */
static int
luaA_systray_item_set_attention_pixmap(lua_State *L)
{
	systray_item_t *item;
	int width, height;
	size_t data_len;
	const char *data;
	int stride;
	unsigned char *cairo_data;
	int x, y;
	static cairo_user_data_key_t attention_data_key;

	item = luaA_checkudata(L, 1, &systray_item_class);
	width = luaL_checkinteger(L, 2);
	height = luaL_checkinteger(L, 3);
	data = luaL_checklstring(L, 4, &data_len);

	/* Verify data length */
	if ((size_t)(width * height * 4) > data_len) {
		return luaL_error(L, "pixmap data too short: need %d bytes, got %d",
		                  width * height * 4, (int)data_len);
	}

	/* Free old attention icon */
	if (item->attention_icon) {
		cairo_surface_destroy(item->attention_icon);
		item->attention_icon = NULL;
	}

	/* Create cairo surface from ARGB32 data */
	stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
	cairo_data = malloc((size_t)stride * (size_t)height);
	if (!cairo_data)
		return 0;

	/* Convert from network byte order ARGB to native ARGB */
	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			int src_idx = (y * width + x) * 4;
			int dst_idx = y * stride + x * 4;

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
			cairo_data[dst_idx + 0] = (unsigned char)data[src_idx + 3];
			cairo_data[dst_idx + 1] = (unsigned char)data[src_idx + 2];
			cairo_data[dst_idx + 2] = (unsigned char)data[src_idx + 1];
			cairo_data[dst_idx + 3] = (unsigned char)data[src_idx + 0];
#else
			cairo_data[dst_idx + 0] = (unsigned char)data[src_idx + 0];
			cairo_data[dst_idx + 1] = (unsigned char)data[src_idx + 1];
			cairo_data[dst_idx + 2] = (unsigned char)data[src_idx + 2];
			cairo_data[dst_idx + 3] = (unsigned char)data[src_idx + 3];
#endif
		}
	}

	item->attention_icon = cairo_image_surface_create_for_data(
		cairo_data, CAIRO_FORMAT_ARGB32, width, height, stride);

	if (cairo_surface_status(item->attention_icon) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(item->attention_icon);
		item->attention_icon = NULL;
		free(cairo_data);
		return 0;
	}

	cairo_surface_set_user_data(item->attention_icon, &attention_data_key, cairo_data, free);

	luaA_object_emit_signal(L, 1, "property::attention_icon", 0);

	return 0;
}

/**
 * Set overlay icon from ARGB32 pixmap data (Lua-callable)
 * Lua: item:set_overlay_pixmap(width, height, data_string)
 */
static int
luaA_systray_item_set_overlay_pixmap(lua_State *L)
{
	systray_item_t *item;
	int width, height;
	size_t data_len;
	const char *data;

	item = luaA_checkudata(L, 1, &systray_item_class);
	width = luaL_checkinteger(L, 2);
	height = luaL_checkinteger(L, 3);
	data = luaL_checklstring(L, 4, &data_len);

	/* Verify data length */
	if ((size_t)(width * height * 4) > data_len) {
		return luaL_error(L, "pixmap data too short: need %d bytes, got %d",
		                  width * height * 4, (int)data_len);
	}

	systray_item_set_overlay_from_pixmap(item,
	                                     (const unsigned char *)data,
	                                     width, height);

	return 0;
}

/**
 * Clear overlay icon (Lua-callable)
 * Lua: item:clear_overlay()
 */
static int
luaA_systray_item_clear_overlay(lua_State *L)
{
	systray_item_t *item;

	item = luaA_checkudata(L, 1, &systray_item_class);
	systray_item_clear_overlay(item);

	return 0;
}

/**
 * Set icon from ARGB32 pixmap data (Lua-callable)
 * Lua: item:set_icon_pixmap(width, height, data_string)
 * data_string is raw bytes in network byte order (big-endian ARGB)
 */
static int
luaA_systray_item_set_icon_pixmap(lua_State *L)
{
	systray_item_t *item;
	int width, height;
	size_t data_len;
	const char *data;

	item = luaA_checkudata(L, 1, &systray_item_class);
	width = luaL_checkinteger(L, 2);
	height = luaL_checkinteger(L, 3);
	data = luaL_checklstring(L, 4, &data_len);

	/* Verify data length */
	if ((size_t)(width * height * 4) > data_len) {
		return luaL_error(L, "pixmap data too short: need %d bytes, got %d",
		                  width * height * 4, (int)data_len);
	}

	systray_item_set_icon_from_pixmap(item,
	                                  (const unsigned char *)data,
	                                  width, height);

	return 0;
}

/**
 * Draw the item's icon to a cairo context
 * Lua: item:draw_icon(cr, width, height)
 * cr is a cairo context (lightuserdata from lgi)
 * Returns true if icon was drawn, false otherwise
 */
static int
luaA_systray_item_draw_icon(lua_State *L)
{
	systray_item_t *item;
	cairo_t *cr;
	double width, height;
	double scale, dx, dy;
	int iw, ih;

	item = luaA_checkudata(L, 1, &systray_item_class);

	/* Get cairo context - lgi passes it as lightuserdata */
	if (!lua_islightuserdata(L, 2)) {
		return luaL_error(L, "expected cairo context as lightuserdata");
	}
	cr = lua_touserdata(L, 2);
	if (!cr) {
		lua_pushboolean(L, 0);
		return 1;
	}

	width = luaL_checknumber(L, 3);
	height = luaL_checknumber(L, 4);

	/* Check if we have an icon */
	if (!item->icon) {
		lua_pushboolean(L, 0);
		return 1;
	}

	/* Get icon dimensions */
	iw = item->icon_width > 0 ? item->icon_width : cairo_image_surface_get_width(item->icon);
	ih = item->icon_height > 0 ? item->icon_height : cairo_image_surface_get_height(item->icon);

	if (iw <= 0 || ih <= 0) {
		lua_pushboolean(L, 0);
		return 1;
	}

	/* Calculate scale to fit */
	scale = fmin(width / iw, height / ih);

	/* Center the image */
	dx = (width - iw * scale) / 2;
	dy = (height - ih * scale) / 2;

	/* Draw the icon */
	cairo_save(cr);
	cairo_translate(cr, dx, dy);
	cairo_scale(cr, scale, scale);
	cairo_set_source_surface(cr, item->icon, 0, 0);
	cairo_paint(cr);
	cairo_restore(cr);

	lua_pushboolean(L, 1);
	return 1;
}

/**
 * Draw the item's overlay icon to a cairo context
 * Lua: item:draw_overlay(cr, x, y, size)
 * cr is a cairo context (lightuserdata from lgi)
 * Returns true if overlay was drawn, false otherwise
 */
static int
luaA_systray_item_draw_overlay(lua_State *L)
{
	systray_item_t *item;
	cairo_t *cr;
	double x, y, size;
	int iw, ih;
	double scale;

	item = luaA_checkudata(L, 1, &systray_item_class);

	/* Get cairo context */
	if (!lua_islightuserdata(L, 2)) {
		return luaL_error(L, "expected cairo context as lightuserdata");
	}
	cr = lua_touserdata(L, 2);
	if (!cr) {
		lua_pushboolean(L, 0);
		return 1;
	}

	x = luaL_checknumber(L, 3);
	y = luaL_checknumber(L, 4);
	size = luaL_checknumber(L, 5);

	/* Check if we have an overlay icon */
	if (!item->overlay_icon) {
		lua_pushboolean(L, 0);
		return 1;
	}

	/* Get overlay icon dimensions */
	iw = cairo_image_surface_get_width(item->overlay_icon);
	ih = cairo_image_surface_get_height(item->overlay_icon);

	if (iw <= 0 || ih <= 0) {
		lua_pushboolean(L, 0);
		return 1;
	}

	/* Calculate scale to fit within size */
	scale = size / fmax(iw, ih);

	/* Draw the overlay icon */
	cairo_save(cr);
	cairo_translate(cr, x, y);
	cairo_scale(cr, scale, scale);
	cairo_set_source_surface(cr, item->overlay_icon, 0, 0);
	cairo_paint(cr);
	cairo_restore(cr);

	lua_pushboolean(L, 1);
	return 1;
}

/* ========================================================================
 * Systray module functions (not on item instances)
 * ======================================================================== */

/**
 * Unregister/destroy a systray item (Lua-callable).
 * Removes from tracking array and invalidates the item.
 * Lua: systray_item.unregister(item)
 */
static int
luaA_systray_item_unregister(lua_State *L)
{
	systray_item_t *item = luaA_checkudata(L, 1, &systray_item_class);
	systray_item_destroy(item);
	return 0;
}

/**
 * Get all systray items
 * Lua: systray_item.get_items() -> table of items
 */
static int
luaA_systray_item_get_items(lua_State *L)
{
	int i;

	lua_newtable(L);

	for (i = 0; i < systray_items.len; i++) {
		luaA_object_push(L, systray_items.tab[i]);
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

/**
 * Get item count
 * Lua: systray_item.count() -> number
 */
static int
luaA_systray_item_count(lua_State *L)
{
	lua_pushinteger(L, systray_items.len);
	return 1;
}

/* ========================================================================
 * C API for D-Bus watcher to create/destroy items
 * ======================================================================== */

/**
 * Simple allocator for systray_item class.
 * Just creates the object - does NOT add to tracking array.
 * Used when Lua code calls systray_item{}.
 */
static systray_item_t *
systray_item_allocator(lua_State *L)
{
	systray_item_t *item = systray_item_new(L);

	/* Initialize fields */
	item->bus_name = NULL;
	item->object_path = NULL;
	item->id = NULL;
	item->title = NULL;
	item->status = a_strdup("Active");
	item->category = a_strdup("ApplicationStatus");
	item->icon_name = NULL;
	item->icon = NULL;
	item->icon_width = 0;
	item->icon_height = 0;
	item->attention_icon_name = NULL;
	item->attention_icon = NULL;
	item->overlay_icon_name = NULL;
	item->overlay_icon = NULL;
	item->tooltip_title = NULL;
	item->tooltip_body = NULL;
	item->tooltip_icon_name = NULL;
	item->menu_path = NULL;
	item->icon_theme_path = NULL;
	item->item_is_menu = false;
	item->is_valid = true;

	return item;
}

/**
 * Create and register a new systray item (Lua-callable).
 * This is for D-Bus watcher to create tracked items.
 * Lua: systray_item.register() -> item
 */
static int
luaA_systray_item_register(lua_State *L)
{
	systray_item_t *item = systray_item_new(L);

	/* Initialize fields */
	item->bus_name = NULL;
	item->object_path = NULL;
	item->id = NULL;
	item->title = NULL;
	item->status = a_strdup("Active");
	item->category = a_strdup("ApplicationStatus");
	item->icon_name = NULL;
	item->icon = NULL;
	item->icon_width = 0;
	item->icon_height = 0;
	item->attention_icon_name = NULL;
	item->attention_icon = NULL;
	item->overlay_icon_name = NULL;
	item->overlay_icon = NULL;
	item->tooltip_title = NULL;
	item->tooltip_body = NULL;
	item->tooltip_icon_name = NULL;
	item->menu_path = NULL;
	item->icon_theme_path = NULL;
	item->item_is_menu = false;
	item->is_valid = true;

	/* Register in Lua registry for luaA_object_push */
	luaA_object_ref(L, -1);
	luaA_object_push(L, item);

	/* Add to global tracking array */
	systray_item_array_append(&systray_items, item);

	return 1;
}

/**
 * Remove item from tracking and invalidate it
 * Called when StatusNotifierItemUnregistered
 */
void
systray_item_destroy(systray_item_t *item)
{
	lua_State *L;
	int i;

	if (!item)
		return;

	item->is_valid = false;

	/* Remove from global array */
	for (i = 0; i < systray_items.len; i++) {
		if (systray_items.tab[i] == item) {
			systray_item_array_take(&systray_items, i);
			break;
		}
	}

	/* Emit removed signal before unreffing */
	L = globalconf_get_lua_State();
	if (L) {
		luaA_object_push(L, item);
		luaA_object_emit_signal(L, -1, "removed", 0);
		lua_pop(L, 1);

		/* Unref so it can be garbage collected */
		luaA_object_unref(L, item);
	}
}

/**
 * Set icon from ARGB32 pixmap data (from D-Bus IconPixmap)
 * Data is in network byte order (big-endian ARGB)
 */
void
systray_item_set_icon_from_pixmap(systray_item_t *item,
                                  const unsigned char *data,
                                  int width, int height)
{
	int stride;
	unsigned char *cairo_data;
	int x, y;
	lua_State *L;
	static cairo_user_data_key_t data_key;

	if (!item || !data || width <= 0 || height <= 0)
		return;

	/* Free old icon */
	if (item->icon) {
		cairo_surface_destroy(item->icon);
		item->icon = NULL;
	}

	/* Create cairo surface from ARGB32 data
	 * D-Bus sends ARGB in network byte order (big-endian)
	 * Cairo wants native byte order, so we need to convert */
	stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
	cairo_data = malloc((size_t)stride * (size_t)height);
	if (!cairo_data)
		return;

	/* Convert from network byte order ARGB to native ARGB */
	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			int src_idx = (y * width + x) * 4;
			int dst_idx = y * stride + x * 4;

			/* Network byte order: ARGB (big endian)
			 * On little-endian systems, we need to swap to BGRA */
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
			cairo_data[dst_idx + 0] = data[src_idx + 3]; /* B <- B */
			cairo_data[dst_idx + 1] = data[src_idx + 2]; /* G <- G */
			cairo_data[dst_idx + 2] = data[src_idx + 1]; /* R <- R */
			cairo_data[dst_idx + 3] = data[src_idx + 0]; /* A <- A */
#else
			cairo_data[dst_idx + 0] = data[src_idx + 0];
			cairo_data[dst_idx + 1] = data[src_idx + 1];
			cairo_data[dst_idx + 2] = data[src_idx + 2];
			cairo_data[dst_idx + 3] = data[src_idx + 3];
#endif
		}
	}

	item->icon = cairo_image_surface_create_for_data(
		cairo_data, CAIRO_FORMAT_ARGB32, width, height, stride);

	if (cairo_surface_status(item->icon) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(item->icon);
		item->icon = NULL;
		free(cairo_data);
		return;
	}

	/* Cairo surface now owns the data - set user data to free it */
	cairo_surface_set_user_data(item->icon, &data_key, cairo_data, free);

	item->icon_width = width;
	item->icon_height = height;

	/* Emit property::icon signal */
	L = globalconf_get_lua_State();
	if (L) {
		luaA_object_push(L, item);
		luaA_object_emit_signal(L, -1, "property::icon", 0);
		lua_pop(L, 1);
	}
}

/**
 * Set icon from icon name (theme lookup done in Lua)
 */
void
systray_item_set_icon_from_name(systray_item_t *item,
                                const char *icon_name,
                                int size)
{
	lua_State *L;

	if (!item)
		return;

	p_delete(&item->icon_name);
	if (icon_name)
		item->icon_name = a_strdup(icon_name);

	/* Store requested size */
	item->icon_width = size;
	item->icon_height = size;

	/* Emit signal - Lua code will do theme lookup and set surface */
	L = globalconf_get_lua_State();
	if (L) {
		luaA_object_push(L, item);
		luaA_object_emit_signal(L, -1, "property::icon_name", 0);
		luaA_object_emit_signal(L, -1, "property::icon", 0);
		lua_pop(L, 1);
	}
}

/**
 * Set overlay icon from ARGB32 pixmap data (from D-Bus OverlayIconPixmap)
 * Data is in network byte order (big-endian ARGB)
 */
void
systray_item_set_overlay_from_pixmap(systray_item_t *item,
                                     const unsigned char *data,
                                     int width, int height)
{
	int stride;
	unsigned char *cairo_data;
	int x, y;
	lua_State *L;
	static cairo_user_data_key_t overlay_data_key;

	if (!item || !data || width <= 0 || height <= 0)
		return;

	/* Free old overlay icon */
	if (item->overlay_icon) {
		cairo_surface_destroy(item->overlay_icon);
		item->overlay_icon = NULL;
	}

	/* Create cairo surface from ARGB32 data */
	stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
	cairo_data = malloc((size_t)stride * (size_t)height);
	if (!cairo_data)
		return;

	/* Convert from network byte order ARGB to native ARGB */
	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			int src_idx = (y * width + x) * 4;
			int dst_idx = y * stride + x * 4;

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
			cairo_data[dst_idx + 0] = data[src_idx + 3]; /* B <- B */
			cairo_data[dst_idx + 1] = data[src_idx + 2]; /* G <- G */
			cairo_data[dst_idx + 2] = data[src_idx + 1]; /* R <- R */
			cairo_data[dst_idx + 3] = data[src_idx + 0]; /* A <- A */
#else
			cairo_data[dst_idx + 0] = data[src_idx + 0];
			cairo_data[dst_idx + 1] = data[src_idx + 1];
			cairo_data[dst_idx + 2] = data[src_idx + 2];
			cairo_data[dst_idx + 3] = data[src_idx + 3];
#endif
		}
	}

	item->overlay_icon = cairo_image_surface_create_for_data(
		cairo_data, CAIRO_FORMAT_ARGB32, width, height, stride);

	if (cairo_surface_status(item->overlay_icon) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(item->overlay_icon);
		item->overlay_icon = NULL;
		free(cairo_data);
		return;
	}

	/* Cairo surface now owns the data */
	cairo_surface_set_user_data(item->overlay_icon, &overlay_data_key, cairo_data, free);

	/* Emit property::overlay_icon signal */
	L = globalconf_get_lua_State();
	if (L) {
		luaA_object_push(L, item);
		luaA_object_emit_signal(L, -1, "property::overlay_icon", 0);
		lua_pop(L, 1);
	}
}

/**
 * Clear overlay icon
 */
void
systray_item_clear_overlay(systray_item_t *item)
{
	lua_State *L;

	if (!item)
		return;

	p_delete(&item->overlay_icon_name);
	if (item->overlay_icon) {
		cairo_surface_destroy(item->overlay_icon);
		item->overlay_icon = NULL;
	}

	/* Emit property::overlay_icon signal */
	L = globalconf_get_lua_State();
	if (L) {
		luaA_object_push(L, item);
		luaA_object_emit_signal(L, -1, "property::overlay_icon", 0);
		lua_pop(L, 1);
	}
}

/**
 * Emit systray::added global signal
 */
void
systray_emit_item_added(systray_item_t *item)
{
	lua_State *L = globalconf_get_lua_State();
	if (!L || !item)
		return;

	/* Use awesome.emit_signal pattern via Lua */
	lua_getglobal(L, "awesome");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "emit_signal");
		if (lua_isfunction(L, -1)) {
			lua_pushstring(L, "systray::added");
			luaA_object_push(L, item);
			lua_call(L, 2, 0);
		} else {
			lua_pop(L, 1);
		}
	}
	lua_pop(L, 1);
}

/**
 * Emit systray::removed global signal
 */
void
systray_emit_item_removed(systray_item_t *item)
{
	lua_State *L = globalconf_get_lua_State();
	if (!L || !item)
		return;

	/* Use awesome.emit_signal pattern via Lua */
	lua_getglobal(L, "awesome");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "emit_signal");
		if (lua_isfunction(L, -1)) {
			lua_pushstring(L, "systray::removed");
			luaA_object_push(L, item);
			lua_call(L, 2, 0);
		} else {
			lua_pop(L, 1);
		}
	}
	lua_pop(L, 1);
}

/**
 * Get array of all items
 */
systray_item_array_t *
systray_get_items(void)
{
	return &systray_items;
}

/* ========================================================================
 * Class setup
 * ======================================================================== */

/**
 * __call metamethod - constructor for systray_item class
 * Lua: local item = systray_item{...}
 */
static int
luaA_systray_item_call(lua_State *L)
{
	return luaA_class_new(L, &systray_item_class);
}

void
systray_item_class_setup(lua_State *L)
{
	static const struct luaL_Reg systray_item_methods[] = {
		LUA_CLASS_METHODS(systray_item)
		{ "__call", luaA_systray_item_call },
		{ "get_items", luaA_systray_item_get_items },
		{ "count", luaA_systray_item_count },
		{ "register", luaA_systray_item_register },
		{ "unregister", luaA_systray_item_unregister },
		{ NULL, NULL }
	};

	static const struct luaL_Reg systray_item_meta[] = {
		LUA_OBJECT_META(systray_item)
		LUA_CLASS_META
		{ "activate", luaA_systray_item_activate },
		{ "secondary_activate", luaA_systray_item_secondary_activate },
		{ "context_menu", luaA_systray_item_context_menu },
		{ "scroll", luaA_systray_item_scroll },
		{ "set_icon_pixmap", luaA_systray_item_set_icon_pixmap },
		{ "set_attention_pixmap", luaA_systray_item_set_attention_pixmap },
		{ "set_overlay_pixmap", luaA_systray_item_set_overlay_pixmap },
		{ "clear_overlay", luaA_systray_item_clear_overlay },
		{ "draw_icon", luaA_systray_item_draw_icon },
		{ "draw_overlay", luaA_systray_item_draw_overlay },
		{ NULL, NULL }
	};

	/* Initialize global items array */
	if (!systray_initialized) {
		systray_item_array_init(&systray_items);
		systray_initialized = true;
	}

	/* Setup class - use simple allocator that doesn't track items.
	 * D-Bus watcher uses systray_item.register() to create tracked items. */
	luaA_class_setup(L, &systray_item_class, "systray_item", NULL,
	                 (lua_class_allocator_t) systray_item_allocator,
	                 (lua_class_collector_t) systray_item_wipe,
	                 NULL,
	                 luaA_class_index_miss_property,
	                 luaA_class_newindex_miss_property,
	                 systray_item_methods, systray_item_meta);

	/* Register read-only properties */
	luaA_class_add_property(&systray_item_class, "item_is_menu",
	                        (lua_class_propfunc_t) luaA_systray_item_set_item_is_menu,
	                        (lua_class_propfunc_t) luaA_systray_item_get_item_is_menu,
	                        (lua_class_propfunc_t) luaA_systray_item_set_item_is_menu);
	luaA_class_add_property(&systray_item_class, "is_valid",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_is_valid,
	                        NULL);

	/* Register read/write properties (D-Bus identification - set once by watcher) */
	luaA_class_add_property(&systray_item_class, "id",
	                        (lua_class_propfunc_t) luaA_systray_item_set_id,
	                        (lua_class_propfunc_t) luaA_systray_item_get_id,
	                        (lua_class_propfunc_t) luaA_systray_item_set_id);
	luaA_class_add_property(&systray_item_class, "bus_name",
	                        (lua_class_propfunc_t) luaA_systray_item_set_bus_name,
	                        (lua_class_propfunc_t) luaA_systray_item_get_bus_name,
	                        (lua_class_propfunc_t) luaA_systray_item_set_bus_name);
	luaA_class_add_property(&systray_item_class, "object_path",
	                        (lua_class_propfunc_t) luaA_systray_item_set_object_path,
	                        (lua_class_propfunc_t) luaA_systray_item_get_object_path,
	                        (lua_class_propfunc_t) luaA_systray_item_set_object_path);
	luaA_class_add_property(&systray_item_class, "menu_path",
	                        (lua_class_propfunc_t) luaA_systray_item_set_menu_path,
	                        (lua_class_propfunc_t) luaA_systray_item_get_menu_path,
	                        (lua_class_propfunc_t) luaA_systray_item_set_menu_path);
	luaA_class_add_property(&systray_item_class, "icon_theme_path",
	                        (lua_class_propfunc_t) luaA_systray_item_set_icon_theme_path,
	                        (lua_class_propfunc_t) luaA_systray_item_get_icon_theme_path,
	                        (lua_class_propfunc_t) luaA_systray_item_set_icon_theme_path);
	luaA_class_add_property(&systray_item_class, "category",
	                        (lua_class_propfunc_t) luaA_systray_item_set_category,
	                        (lua_class_propfunc_t) luaA_systray_item_get_category,
	                        (lua_class_propfunc_t) luaA_systray_item_set_category);

	/* Register read/write properties (dynamic - updated by D-Bus signals) */
	luaA_class_add_property(&systray_item_class, "title",
	                        (lua_class_propfunc_t) luaA_systray_item_set_title,
	                        (lua_class_propfunc_t) luaA_systray_item_get_title,
	                        (lua_class_propfunc_t) luaA_systray_item_set_title);
	luaA_class_add_property(&systray_item_class, "app_name",
	                        (lua_class_propfunc_t) luaA_systray_item_set_app_name,
	                        (lua_class_propfunc_t) luaA_systray_item_get_app_name,
	                        (lua_class_propfunc_t) luaA_systray_item_set_app_name);
	luaA_class_add_property(&systray_item_class, "status",
	                        (lua_class_propfunc_t) luaA_systray_item_set_status,
	                        (lua_class_propfunc_t) luaA_systray_item_get_status,
	                        (lua_class_propfunc_t) luaA_systray_item_set_status);
	luaA_class_add_property(&systray_item_class, "icon_name",
	                        (lua_class_propfunc_t) luaA_systray_item_set_icon_name,
	                        (lua_class_propfunc_t) luaA_systray_item_get_icon_name,
	                        (lua_class_propfunc_t) luaA_systray_item_set_icon_name);
	luaA_class_add_property(&systray_item_class, "attention_icon_name",
	                        (lua_class_propfunc_t) luaA_systray_item_set_attention_icon_name,
	                        (lua_class_propfunc_t) luaA_systray_item_get_attention_icon_name,
	                        (lua_class_propfunc_t) luaA_systray_item_set_attention_icon_name);
	luaA_class_add_property(&systray_item_class, "attention_icon",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_attention_icon,
	                        NULL);
	luaA_class_add_property(&systray_item_class, "overlay_icon_name",
	                        (lua_class_propfunc_t) luaA_systray_item_set_overlay_icon_name,
	                        (lua_class_propfunc_t) luaA_systray_item_get_overlay_icon_name,
	                        (lua_class_propfunc_t) luaA_systray_item_set_overlay_icon_name);
	luaA_class_add_property(&systray_item_class, "overlay_icon",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_overlay_icon,
	                        NULL);
	luaA_class_add_property(&systray_item_class, "icon",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_icon,
	                        NULL);
	luaA_class_add_property(&systray_item_class, "icon_width",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_icon_width,
	                        NULL);
	luaA_class_add_property(&systray_item_class, "icon_height",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_icon_height,
	                        NULL);
	luaA_class_add_property(&systray_item_class, "tooltip_title",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_tooltip_title,
	                        NULL);
	luaA_class_add_property(&systray_item_class, "tooltip_body",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_systray_item_get_tooltip_body,
	                        NULL);
}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
