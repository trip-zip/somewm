/*
 * wibox.c - Wibox (widget box) implementation
 *
 * Creates layer shell surfaces that can be drawn on from Lua using LGI/Cairo.
 * This is the minimal "picture frame" that displays what Lua draws.
 */

#define _GNU_SOURCE  /* for memfd_create */

#include "wibox.h"
#include "drawable.h"
#include "luaa.h"
#include "../somewm_api.h"
#include "../somewm_types.h"
#include "../common/util.h"

#include <cairo.h>
#include <wayland-server-core.h>
#include <wayland-client.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output.h>
#include <wlr/backend.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/render/allocator.h>
#include <wlr/types/wlr_shm.h>
#include <wlr/util/box.h>
#include <drm_fourcc.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>

/* Wibox structure - supports multiple instances */
typedef struct Wibox {
	/* Cairo drawing surface */
	cairo_surface_t *cairo_surface;
	cairo_t *cr;
	uint8_t *data;

	/* Geometry */
	int x, y;
	int width;
	int height;
	int stride;

	/* Visibility */
	int visible;

	/* Positioning */
	enum {
		WIBOX_POSITION_TOP,
		WIBOX_POSITION_BOTTOM,
		WIBOX_POSITION_LEFT,
		WIBOX_POSITION_RIGHT,
		WIBOX_POSITION_FLOATING  /* No exclusive zone */
	} position;

	/* Exclusive zone - reserves screen space (like Wayland layer shell) */
	int exclusive_zone;  /* Height/width to reserve, 0 = don't reserve */

	/* Scene graph nodes for display */
	struct wlr_scene_tree *tree;
	struct wlr_scene_rect *background;
	struct wlr_scene_buffer *buffer_node;

	/* Buffer for displaying Cairo content */
	struct wlr_texture *texture;
	struct wlr_buffer *buffer;

	/* Monitor this wibox is on */
	Monitor *mon;

	/* Lua reference to keep the wibox table alive */
	int lua_ref;
} Wibox;

/* Forward declarations */
/* Disabled with test functions */
/* static struct wlr_buffer *create_buffer_from_cairo(Wibox *wb); */

/**
 * Create a new wibox instance
 * Arguments: table with { x, y, width, height, visible }
 * Returns: lightuserdata (Wibox pointer)
 */
static int
luaA_wibox_create(lua_State *L)
{
	Wibox *wb;
	Monitor *mon;

	/* Argument should be a table */
	luaL_checktype(L, 1, LUA_TTABLE);

	/* Allocate new wibox */
	wb = calloc(1, sizeof(Wibox));
	if (!wb) {
		return luaL_error(L, "Failed to allocate wibox");
	}

	/* Get monitor */
	mon = some_get_focused_monitor();
	if (!mon) {
		free(wb);
		return luaL_error(L, "No monitor available");
	}
	wb->mon = mon;

	/* Get geometry from table */
	lua_getfield(L, 1, "x");
	wb->x = luaL_optinteger(L, -1, 0);
	lua_pop(L, 1);

	lua_getfield(L, 1, "y");
	wb->y = luaL_optinteger(L, -1, 0);
	lua_pop(L, 1);

	lua_getfield(L, 1, "width");
	wb->width = luaL_optinteger(L, -1, 100);
	lua_pop(L, 1);

	lua_getfield(L, 1, "height");
	wb->height = luaL_optinteger(L, -1, 30);
	lua_pop(L, 1);

	lua_getfield(L, 1, "visible");
	wb->visible = lua_toboolean(L, -1);
	lua_pop(L, 1);

	/* Set stride for ARGB32 format */
	wb->stride = wb->width * 4;

	/* Allocate buffer for Cairo surface */
	wb->data = calloc(1, wb->stride * wb->height);
	if (!wb->data) {
		free(wb);
		return luaL_error(L, "Failed to allocate buffer");
	}

	/* Create Cairo surface */
	wb->cairo_surface = cairo_image_surface_create_for_data(
		wb->data,
		CAIRO_FORMAT_ARGB32,
		wb->width,
		wb->height,
		wb->stride
	);

	if (cairo_surface_status(wb->cairo_surface) != CAIRO_STATUS_SUCCESS) {
		free(wb->data);
		free(wb);
		return luaL_error(L, "Failed to create Cairo surface");
	}

	/* Create Cairo context */
	wb->cr = cairo_create(wb->cairo_surface);

	/* Initialize to transparent */
	cairo_set_source_rgba(wb->cr, 0, 0, 0, 0);
	cairo_set_operator(wb->cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(wb->cr);

	log_debug("wibox created: %dx%d at %d,%d", wb->width, wb->height, wb->x, wb->y);

	/* Return as lightuserdata */
	lua_pushlightuserdata(L, wb);
	return 1;
}

/**
 * Get the Cairo surface from a wibox for drawing
 * Arguments: wibox (lightuserdata)
 * Returns: Cairo surface (lightuserdata) for LGI
 */
static int
luaA_wibox_get_surface(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);
	if (!wb || !wb->cairo_surface) {
		return luaL_error(L, "Invalid wibox or no surface");
	}

	lua_pushlightuserdata(L, wb->cairo_surface);
	return 1;
}

/**
 * Show a wibox on screen
 * Arguments: wibox (lightuserdata)
 */
static int
luaA_wibox_show(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);
	struct wlr_scene_tree **layers;
	struct wlr_renderer *renderer;
	struct wlr_texture *texture;

	if (!wb) {
		return luaL_error(L, "Invalid wibox");
	}

	if (!wb->mon) {
		return luaL_error(L, "No monitor for wibox");
	}

	/* Get scene graph layers */
	layers = some_get_layers();
	if (!layers) {
		return luaL_error(L, "Failed to get scene layers");
	}

	/* Clean up any existing tree */
	if (wb->tree) {
		wlr_scene_node_destroy(&wb->tree->node);
		wb->tree = NULL;
		wb->background = NULL;
		wb->buffer_node = NULL;
	}

	/* Create scene tree in TOP layer */
	wb->tree = wlr_scene_tree_create(layers[LyrTop]);
	if (!wb->tree) {
		return luaL_error(L, "Failed to create scene tree");
	}

	/* Get the renderer */
	renderer = some_get_renderer();
	if (!renderer) {
		return luaL_error(L, "Failed to get renderer");
	}

	/* Ensure Cairo has flushed all operations */
	cairo_surface_flush(wb->cairo_surface);

	/* Clean up old texture if it exists */
	if (wb->texture) {
		wlr_texture_destroy(wb->texture);
		wb->texture = NULL;
	}

	/* Create texture from Cairo pixel data */
	texture = wlr_texture_from_pixels(renderer,
		DRM_FORMAT_ARGB8888,
		wb->stride,
		wb->width,
		wb->height,
		wb->data);

	if (!texture) {
		/* Fall back to colored rectangle if texture creation fails */
		float color[4] = {0.8f, 0.2f, 0.2f, 0.9f}; /* Red to show error */
		wb->background = wlr_scene_rect_create(wb->tree, wb->width, wb->height, color);
		if (!wb->background) {
			wlr_scene_node_destroy(&wb->tree->node);
			wb->tree = NULL;
			return luaL_error(L, "Failed to create scene rect");
		}
	} else {
		struct wlr_buffer *buffer;

		/* Store texture for cleanup */
		wb->texture = texture;

		/* Create SHM buffer from Cairo data using shared implementation */
		buffer = drawable_create_buffer_from_data(wb->width, wb->height, wb->data, wb->stride);
		if (!buffer) {
			goto fallback_rect;
		}

		/* Create scene buffer */
		wb->buffer = buffer;
		wb->buffer_node = wlr_scene_buffer_create(wb->tree, buffer);
		if (!wb->buffer_node) {
			wlr_buffer_drop(buffer);
			wb->buffer = NULL;
			goto fallback_rect;
		}

		goto success;

fallback_rect:
		{
			float color[4] = {0.0f, 0.0f, 0.0f, 0.8f}; /* Semi-transparent black background */
			wb->background = wlr_scene_rect_create(wb->tree, wb->width, wb->height, color);
			if (!wb->background) {
				if (wb->texture) {
					wlr_texture_destroy(wb->texture);
					wb->texture = NULL;
				}
				wlr_scene_node_destroy(&wb->tree->node);
				wb->tree = NULL;
				return luaL_error(L, "Failed to create scene rect");
			}
		}
	}

success:

	/* Position the wibox */
	wlr_scene_node_set_position(&wb->tree->node, wb->x, wb->y);

	/* Make it visible */
	wlr_scene_node_set_enabled(&wb->tree->node, true);
	wb->visible = 1;

	log_debug("wibox shown at %d,%d", wb->x, wb->y);
	return 0;
}

/**
 * Hide a wibox (keep it alive but invisible)
 * Arguments: wibox (lightuserdata)
 */
static int
luaA_wibox_hide(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);

	if (!wb) {
		return luaL_error(L, "Invalid wibox");
	}

	if (wb->tree) {
		wlr_scene_node_set_enabled(&wb->tree->node, false);
	}

	wb->visible = 0;
	log_debug("wibox hidden");
	return 0;
}

/**
 * Check if wibox is visible
 * Arguments: wibox (lightuserdata)
 * Returns: boolean
 */
static int
luaA_wibox_is_visible(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);

	if (!wb) {
		return luaL_error(L, "Invalid wibox");
	}

	lua_pushboolean(L, wb->visible);
	return 1;
}

/**
 * Update the wibox display after drawing changes
 * This recreates the buffer from the Cairo surface
 * Arguments: wibox (lightuserdata)
 */
static int
luaA_wibox_update(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);
	struct wlr_buffer *buffer;

	if (!wb) {
		return luaL_error(L, "Invalid wibox");
	}

	/* Only update if visible and we have a buffer node */
	if (!wb->visible || !wb->buffer_node) {
		return 0;
	}

	/* Ensure Cairo has flushed all operations */
	cairo_surface_flush(wb->cairo_surface);

	/* Create SHM buffer from updated Cairo data using shared implementation */
	buffer = drawable_create_buffer_from_data(wb->width, wb->height, wb->data, wb->stride);
	if (!buffer) {
		return luaL_error(L, "Failed to create SHM buffer");
	}

	/* Drop old buffer if it exists */
	if (wb->buffer) {
		wlr_buffer_drop(wb->buffer);
	}

	/* Update the scene buffer with new buffer and damage whole region */
	wb->buffer = buffer;
	wlr_scene_buffer_set_buffer_with_damage(wb->buffer_node, buffer, NULL);

	return 0;
}

/**
 * Move a wibox to a new position
 * Arguments: wibox (lightuserdata), x (number), y (number)
 */
static int
luaA_wibox_move(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);
	int new_x, new_y;

	if (!wb) {
		return luaL_error(L, "Invalid wibox");
	}

	/* Get new coordinates */
	new_x = luaL_checkinteger(L, 2);
	new_y = luaL_checkinteger(L, 3);

	/* Update stored position */
	wb->x = new_x;
	wb->y = new_y;

	/* If wibox is visible, update scene node position immediately */
	if (wb->visible && wb->tree) {
		wlr_scene_node_set_position(&wb->tree->node, wb->x, wb->y);
	}

	return 0;
}

/**
 * Destroy a wibox and free all resources
 * Arguments: wibox (lightuserdata)
 */
static int
luaA_wibox_destroy(lua_State *L)
{
	Wibox *wb = lua_touserdata(L, 1);

	if (!wb) {
		return luaL_error(L, "Invalid wibox");
	}

	/* Clean up scene graph nodes */
	if (wb->tree) {
		wlr_scene_node_destroy(&wb->tree->node);
		wb->tree = NULL;
		wb->background = NULL;
		wb->buffer_node = NULL;
	}

	/* Clean up buffer */
	if (wb->buffer) {
		wlr_buffer_drop(wb->buffer);
		wb->buffer = NULL;
	}

	/* Clean up Cairo resources */
	if (wb->cr) {
		cairo_destroy(wb->cr);
		wb->cr = NULL;
	}
	if (wb->cairo_surface) {
		cairo_surface_destroy(wb->cairo_surface);
		wb->cairo_surface = NULL;
	}
	if (wb->data) {
		free(wb->data);
		wb->data = NULL;
	}

	/* Free the wibox itself */
	free(wb);

	log_debug("wibox destroyed");
	return 0;
}


/* Wibox module methods */
static const luaL_Reg wibox_methods[] = {
	/* TODO: Implement proper wibox rendering API */
	{ "create", luaA_wibox_create },
	{ "get_surface", luaA_wibox_get_surface },
	{ "show", luaA_wibox_show },
	{ "hide", luaA_wibox_hide },
	{ "is_visible", luaA_wibox_is_visible },
	{ "move", luaA_wibox_move },
	{ "update", luaA_wibox_update },
	{ "destroy", luaA_wibox_destroy },
	/* Test functions removed - use drawin objects instead */
	{ NULL, NULL }
};

/**
 * Setup the wibox Lua module.
 */
void
luaA_wibox_setup(lua_State *L)
{
	luaA_openlib(L, "_wibox", wibox_methods, NULL);
}