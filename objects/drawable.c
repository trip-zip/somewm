/*
 * drawable.c - Drawable object implementation
 *
 * Manages Cairo surfaces for rendering widgets. This is the "canvas" that
 * Lua draws on via Cairo, which then gets displayed on screen.
 *
 * Based on AwesomeWM's drawable but adapted for Wayland/wlroots.
 */

#define _GNU_SOURCE
#include "drawable.h"
#include "drawin.h"
#include "screen.h"
#include "client.h"
#include "luaa.h"
#include "common/util.h"
#include "../x11_compat.h"
#include "common/luaclass.h"
#include "common/luaobject.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <lauxlib.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <drm_fourcc.h>

/* Drawable class (AwesomeWM class system) */
lua_class_t drawable_class;

/* Forward declarations for internal functions */
static drawable_t *luaA_checkdrawable(lua_State *L, int idx);

/* Generate LUA_OBJECT helper functions (drawable_new, drawable_ref, etc.) */
LUA_OBJECT_FUNCS(drawable_class, drawable_t, drawable)

/* Ensure MFD_CLOEXEC is defined (for older systems) */
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif

/* ============================================================================
 * HiDPI Support
 * ============================================================================
 *
 * Get the output scale factor for a drawable based on its owner (drawin/client).
 * Used to create Cairo surfaces at native resolution for sharp rendering.
 */
static float
drawable_get_scale(drawable_t *d)
{
	if (!d)
		return 1.0f;

	/* Check for drawin-level scale override (somewm extension).
	 * Allows Lua to force a specific scale for performance-sensitive drawins
	 * like screenshot overlays that don't benefit from HiDPI upscaling. */
	if (d->owner_type == DRAWABLE_OWNER_DRAWIN && d->owner.drawin) {
		if (d->owner.drawin->scale_override > 0.0f)
			return d->owner.drawin->scale_override;
	}

	/* Default: use output scale for HiDPI rendering */
	screen_t *screen = NULL;

	if (d->owner_type == DRAWABLE_OWNER_DRAWIN && d->owner.drawin) {
		screen = d->owner.drawin->screen;
	} else if (d->owner_type == DRAWABLE_OWNER_CLIENT && d->owner.client) {
		screen = d->owner.client->screen;
	}

	if (screen && screen->monitor && screen->monitor->wlr_output) {
		return screen->monitor->wlr_output->scale;
	}

	return 1.0f;
}

/* ============================================================================
 * SHM Buffer Implementation
 * ============================================================================
 *
 * Custom SHM (shared memory) buffer for CPU-accessible rendering.
 * This allows Cairo pixel data to be efficiently displayed via the scene graph.
 *
 * Based on wlroots cairo-buffer.c example and adapted for drawable integration.
 */

typedef struct {
	struct wlr_buffer base;
	void *data;          /* mmap'd shared memory */
	int fd;              /* memfd file descriptor */
	uint32_t format;     /* DRM_FORMAT_ARGB8888 */
	int width, height;
	size_t stride;
	bool accessed;       /* Track if currently being accessed */
} DrawableShmBuffer;

static void
drawable_shm_buffer_destroy(struct wlr_buffer *wlr_buffer)
{
	DrawableShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);

	if (buffer->data) {
		munmap(buffer->data, buffer->height * buffer->stride);
	}
	if (buffer->fd >= 0) {
		close(buffer->fd);
	}
	free(buffer);
}

static bool
drawable_shm_buffer_get_shm(struct wlr_buffer *wlr_buffer,
		struct wlr_shm_attributes *attribs)
{
	DrawableShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);

	attribs->fd = buffer->fd;
	attribs->format = buffer->format;
	attribs->width = buffer->width;
	attribs->height = buffer->height;
	attribs->stride = buffer->stride;
	attribs->offset = 0;
	return true;
}

static bool
drawable_shm_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buffer,
		uint32_t flags, void **data, uint32_t *format, size_t *stride)
{
	DrawableShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);

	if (buffer->accessed) {
		return false;  /* Already being accessed */
	}

	*data = buffer->data;
	*format = buffer->format;
	*stride = buffer->stride;
	buffer->accessed = true;
	return true;
}

static void
drawable_shm_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer)
{
	DrawableShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);
	buffer->accessed = false;
}

static bool
drawable_shm_buffer_get_dmabuf(struct wlr_buffer *wlr_buffer,
		struct wlr_dmabuf_attributes *attribs)
{
	return false;  /* SHM buffer, not DMA-BUF */
}

static const struct wlr_buffer_impl drawable_shm_buffer_impl = {
	.destroy = drawable_shm_buffer_destroy,
	.get_shm = drawable_shm_buffer_get_shm,
	.begin_data_ptr_access = drawable_shm_buffer_begin_data_ptr_access,
	.end_data_ptr_access = drawable_shm_buffer_end_data_ptr_access,
	.get_dmabuf = drawable_shm_buffer_get_dmabuf,
};

/**
 * Create an empty SHM buffer for rendering into.
 * The buffer is zeroed and ready to be used as a render target.
 *
 * Returns a wlr_buffer that supports CPU data pointer access.
 * The caller must call wlr_buffer_drop() when done with the buffer.
 */
struct wlr_buffer *
drawable_create_empty_buffer(int width, int height)
{
	DrawableShmBuffer *buffer;
	size_t size;
	int fd;
	void *data;

	if (width <= 0 || height <= 0) {
		fprintf(stderr, "drawable_create_empty_buffer: invalid dimensions\n");
		return NULL;
	}

	/* Allocate buffer structure */
	buffer = calloc(1, sizeof(DrawableShmBuffer));
	if (!buffer) {
		return NULL;
	}

	/* Calculate buffer size */
	buffer->stride = width * 4;  /* 4 bytes per pixel (ARGB8888) */
	size = buffer->stride * height;

	/* Create anonymous file in memory */
	fd = memfd_create("screenshot-shm", MFD_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "drawable_create_empty_buffer: memfd_create failed: %s\n", strerror(errno));
		free(buffer);
		return NULL;
	}

	/* Set file size */
	if (ftruncate(fd, size) < 0) {
		fprintf(stderr, "drawable_create_empty_buffer: ftruncate failed: %s\n", strerror(errno));
		close(fd);
		free(buffer);
		return NULL;
	}

	/* Map into memory */
	data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "drawable_create_empty_buffer: mmap failed: %s\n", strerror(errno));
		close(fd);
		free(buffer);
		return NULL;
	}

	/* Zero buffer */
	memset(data, 0, size);

	/* Initialize buffer fields */
	buffer->data = data;
	buffer->fd = fd;
	buffer->format = DRM_FORMAT_ARGB8888;
	buffer->width = width;
	buffer->height = height;
	buffer->accessed = false;

	/* Initialize wlr_buffer */
	wlr_buffer_init(&buffer->base, &drawable_shm_buffer_impl, width, height);

	return &buffer->base;
}

/**
 * Create an SHM buffer from raw Cairo pixel data.
 * This is the low-level function that handles the actual buffer creation.
 *
 * Returns a wlr_buffer that supports CPU data pointer access.
 * The caller must call wlr_buffer_drop() when done with the buffer.
 */
struct wlr_buffer *
drawable_create_buffer_from_data(int width, int height, const void *cairo_data, size_t cairo_stride)
{
	DrawableShmBuffer *buffer;
	size_t size;
	int fd;
	void *data;

	if (!cairo_data || width <= 0 || height <= 0) {
		return NULL;
	}

	/* Allocate buffer structure */
	buffer = calloc(1, sizeof(DrawableShmBuffer));
	if (!buffer) {
		return NULL;
	}

	/* Calculate buffer size */
	buffer->stride = width * 4;  /* 4 bytes per pixel (ARGB8888) */
	size = buffer->stride * height;

	/* Create anonymous file in memory */
	fd = memfd_create("drawable-shm", MFD_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "drawable_create_buffer: memfd_create failed: %s\n", strerror(errno));
		free(buffer);
		return NULL;
	}

	/* Set file size */
	if (ftruncate(fd, size) < 0) {
		fprintf(stderr, "drawable_create_buffer: ftruncate failed: %s\n", strerror(errno));
		close(fd);
		free(buffer);
		return NULL;
	}

	/* Map into memory */
	data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "drawable_create_buffer: mmap failed: %s\n", strerror(errno));
		close(fd);
		free(buffer);
		return NULL;
	}

	/* Copy Cairo pixel data into shared memory.
	 * No memset needed: buffer->stride == width * 4, so every byte is
	 * overwritten by the memcpy loop below (destination is fully covered). */
	for (int y = 0; y < height; y++) {
		memcpy((uint8_t *)data + y * buffer->stride,
		       (const uint8_t *)cairo_data + y * cairo_stride,
		       width * 4);
	}

	/* Initialize buffer fields */
	buffer->data = data;
	buffer->fd = fd;
	buffer->format = DRM_FORMAT_ARGB8888;
	buffer->width = width;
	buffer->height = height;
	buffer->accessed = false;

	/* Initialize wlr_buffer */
	wlr_buffer_init(&buffer->base, &drawable_shm_buffer_impl, width, height);

	return &buffer->base;
}

/**
 * Create an SHM buffer from a drawable's Cairo surface data.
 * This is a convenience wrapper around drawable_create_buffer_from_data().
 *
 * Returns a wlr_buffer that supports CPU data pointer access.
 * The caller must call wlr_buffer_drop() when done with the buffer.
 */
struct wlr_buffer *
drawable_create_buffer(drawable_t *d)
{
	const void *cairo_data;
	size_t cairo_stride;

	if (!d || !d->surface) {
		fprintf(stderr, "drawable_create_buffer: invalid drawable or no surface\n");
		return NULL;
	}

	/* Ensure Cairo surface is flushed */
	cairo_surface_flush(d->surface);

	/* Get Cairo surface data and actual dimensions (may be scaled for HiDPI) */
	cairo_data = cairo_image_surface_get_data(d->surface);
	cairo_stride = cairo_image_surface_get_stride(d->surface);
	int surface_width = cairo_image_surface_get_width(d->surface);
	int surface_height = cairo_image_surface_get_height(d->surface);

	/* Use actual surface dimensions (includes HiDPI scaling) */
	return drawable_create_buffer_from_data(surface_width, surface_height, cairo_data, cairo_stride);
}

/* ============================================================================
 * Object Signal Support - Per-instance signals
 * ============================================================================ */

/* Forward declarations for signal array helpers */
extern void signal_array_init(signal_array_t *arr);
extern void signal_array_wipe(signal_array_t *arr);

/* Forward declarations for internal helpers */
/* ============================================================================
 * Drawable Object Lifecycle
 * ============================================================================ */

/** Create a new drawable object
 * This is called by drawable_allocator, not directly from Lua
 */

/** Allocate a new drawable with a refresh callback
 * This is the public API used by drawin
 */
drawable_t *
drawable_allocator(lua_State *L, drawable_refresh_callback callback, void *data)
{
	drawable_t *d = drawable_new(L);
	d->refresh_callback = callback;
	d->refresh_data = data;
	d->refreshed = false;
	d->valid = true;  /* Drawable is valid when created */
	d->surface = NULL;
	d->buffer = NULL;
	d->surface_scale = 0.0f;  /* Will be set when surface is created */
	d->geometry.width = 0;
	d->geometry.height = 0;
	d->geometry.x = 0;
	d->geometry.y = 0;

	/* Initialize owner tracking (AwesomeWM pattern) */
	d->owner_type = DRAWABLE_OWNER_NONE;
	d->owner.ptr = NULL;

	/* Signal array already initialized by LUA_OBJECT_HEADER via drawable_new() */
	/* DO NOT call signal_array_init() - it corrupts class system initialization */

	return d;
}

/** Wrapper allocator for class system (matches lua_class_allocator_t signature) */
static lua_object_t *
drawable_allocator_wrapper(lua_State *L)
{
	/* Call existing allocator with NULL callback/data (drawins set these later) */
	drawable_t *d = drawable_allocator(L, NULL, NULL);
	return (lua_object_t *)d;
}

/** Unset drawable surface (AwesomeWM API - cleanup surface and buffer) */
static void
drawable_unset_surface(drawable_t *d)
{
	if (d->surface) {
		cairo_surface_finish(d->surface);
		cairo_surface_destroy(d->surface);
		d->surface = NULL;
	}
	if (d->buffer) {
		wlr_buffer_drop(d->buffer);
		d->buffer = NULL;
	}
	d->refreshed = false;
}

/** Cleanup drawable resources */
static void
drawable_wipe(drawable_t *d)
{
	drawable_unset_surface(d);
}

/** Garbage collection */
static int
luaA_drawable_gc(lua_State *L)
{
	drawable_t *d = luaA_checkdrawable(L, 1);
	drawable_wipe(d);
	return 0;
}

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

/** Check if value at index is a drawable */
static drawable_t *
luaA_checkdrawable(lua_State *L, int idx)
{
	return (drawable_t *)luaL_checkudata(L, idx, drawable_class.name);
}

/* ============================================================================
 * Drawable Properties
 * ============================================================================ */

/** Set drawable geometry
 * When geometry or scale changes, the surface needs to be recreated
 */
/** Set drawable geometry (AwesomeWM pattern - area_t parameter) */
void
drawable_set_geometry(lua_State *L, int didx, area_t geom)
{
	drawable_t *d = luaA_checkudata(L, didx, &drawable_class);
	area_t old = d->geometry;
	bool area_changed;
	float scale = drawable_get_scale(d);
	bool scale_changed = (d->surface_scale != scale);

	d->geometry = geom;
	area_changed = !wlr_box_equal(&old, &geom);

	bool size_changed = (old.width != geom.width || old.height != geom.height);
	bool need_new_surface = size_changed || scale_changed;

	/* Clean up old surface if size or scale changed */
	if (need_new_surface)
		drawable_unset_surface(d);

	/* Create new surface if dimensions are valid and surface needs recreation */
	if (need_new_surface && geom.width > 0 && geom.height > 0) {
		/* Get scale for HiDPI support.
		 * Use floorf to match what Cairo will actually draw with device_scale.
		 * Using ceilf creates extra pixels that Cairo won't fully draw to,
		 * causing antialiased edges with wrong alpha values. */
		int scaled_width = (int)floorf(geom.width * scale);
		int scaled_height = (int)floorf(geom.height * scale);
		if (scaled_width < 1) scaled_width = 1;
		if (scaled_height < 1) scaled_height = 1;

		d->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
		                                         scaled_width, scaled_height);
		if (cairo_surface_status(d->surface) == CAIRO_STATUS_SUCCESS) {
			/* Set device scale so Cairo draws in logical coordinates */
			cairo_surface_set_device_scale(d->surface, scale, scale);
			d->surface_scale = scale;

			/* Clear surface to transparent black.
			 * Cairo should initialize ARGB32 surfaces to transparent, but
			 * we do this explicitly to ensure no garbage alpha values. */
			cairo_t *cr = cairo_create(d->surface);
			cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
			cairo_set_source_rgba(cr, 0, 0, 0, 0);
			cairo_paint(cr);
			cairo_destroy(cr);

			d->refreshed = false;
			/* Emit property::surface signal (AwesomeWM pattern) */
			luaA_object_emit_signal(L, didx, "property::surface", 0);
		} else {
			cairo_surface_destroy(d->surface);
			d->surface = NULL;
		}
	}

	/* Emit property signals (AwesomeWM pattern) */
	if (area_changed)
		luaA_object_emit_signal(L, didx, "property::geometry", 0);
	if (old.x != geom.x)
		luaA_object_emit_signal(L, didx, "property::x", 0);
	if (old.y != geom.y)
		luaA_object_emit_signal(L, didx, "property::y", 0);
	if (old.width != geom.width)
		luaA_object_emit_signal(L, didx, "property::width", 0);
	if (old.height != geom.height)
		luaA_object_emit_signal(L, didx, "property::height", 0);
}

/** Set drawable geometry (legacy wrapper for compatibility) */
void
luaA_drawable_set_geometry(lua_State *L, int didx, int x, int y, int width, int height)
{
	drawable_t *d = luaA_checkdrawable(L, didx);
	int old_width = d->geometry.width;
	int old_height = d->geometry.height;
	bool size_changed;

	d->geometry.x = x;
	d->geometry.y = y;
	d->geometry.width = width;
	d->geometry.height = height;

	/* If size changed, recreate surface */
	size_changed = (old_width != width || old_height != height);
	if (size_changed) {
		drawable_unset_surface(d);

		/* Create new surface if we have valid dimensions */
		if (width > 0 && height > 0) {
			/* Get scale for HiDPI support.
			 * Use floorf to match what Cairo will actually draw with device_scale. */
			float scale = drawable_get_scale(d);
			int scaled_width = (int)floorf(width * scale);
			int scaled_height = (int)floorf(height * scale);
			if (scaled_width < 1) scaled_width = 1;
			if (scaled_height < 1) scaled_height = 1;

			/* Create Cairo image surface at scaled resolution */
			d->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, scaled_width, scaled_height);
			if (cairo_surface_status(d->surface) != CAIRO_STATUS_SUCCESS) {
				cairo_surface_destroy(d->surface);
				d->surface = NULL;
			} else {
				/* Set device scale so Cairo draws in logical coordinates */
				cairo_surface_set_device_scale(d->surface, scale, scale);
				d->surface_scale = scale;  /* Track scale for recreation on change */

				/* Clear surface to transparent black.
				 * Cairo should initialize ARGB32 surfaces to transparent, but
				 * we do this explicitly to ensure no garbage alpha values. */
				cairo_t *cr = cairo_create(d->surface);
				cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
				cairo_set_source_rgba(cr, 0, 0, 0, 0);
				cairo_paint(cr);
				cairo_destroy(cr);
			}
			d->refreshed = false;

			/* Emit property::surface signal (matches AwesomeWM drawable.c:155)
			 * This notifies wibox/drawable.lua:413 to trigger widget repaint */
			luaA_object_emit_signal(L, didx, "property::surface", 0);

			/* Buffer will be created in refresh callback when content is ready */
		}
	}

	/* Emit signals (stub - Signal emission not required from drawable) */
	/* In AwesomeWM this would emit property::geometry, property::x, etc. */
}

/** Get or set drawable geometry
 * With no args: Returns table with {x=, y=, width=, height=}
 * With table arg: Sets geometry and recreates surface if scale changed
 */
static int
luaA_drawable_geometry(lua_State *L)
{
	drawable_t *d = (drawable_t *)lua_touserdata(L, 1);
	if (!d) {
		return luaL_error(L, "expected drawable, got %s", lua_typename(L, lua_type(L, 1)));
	}

	/* If a table argument is provided, this is a setter */
	if (lua_gettop(L) >= 2 && lua_istable(L, 2)) {
		area_t geom = d->geometry;

		lua_getfield(L, 2, "x");
		if (!lua_isnil(L, -1)) geom.x = lua_tointeger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "y");
		if (!lua_isnil(L, -1)) geom.y = lua_tointeger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "width");
		if (!lua_isnil(L, -1)) geom.width = lua_tointeger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "height");
		if (!lua_isnil(L, -1)) geom.height = lua_tointeger(L, -1);
		lua_pop(L, 1);

		/* Call drawable_set_geometry which handles scale detection */
		drawable_set_geometry(L, 1, geom);
	}

	/* Return current geometry */
	lua_createtable(L, 0, 4);
	lua_pushinteger(L, d->geometry.x);
	lua_setfield(L, -2, "x");
	lua_pushinteger(L, d->geometry.y);
	lua_setfield(L, -2, "y");
	lua_pushinteger(L, d->geometry.width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, d->geometry.height);
	lua_setfield(L, -2, "height");

	return 1;
}

/** Refresh drawable - mark content as ready to display
 * Calls the refresh callback to update the display
 */
static int
luaA_drawable_refresh(lua_State *L)
{
	drawable_t *d = (drawable_t *)lua_touserdata(L, 1);
	if (!d) {
		return luaL_error(L, "expected drawable, got %s", lua_typename(L, lua_type(L, 1)));
	}

	d->refreshed = true;

	/* Call refresh callback if set */
	if (d->refresh_callback) {
		d->refresh_callback(d->refresh_data);
	}

	return 0;
}

/* ============================================================================
 * Lua Class Setup
 * ============================================================================ */

/** Drawable constructor (called from Lua as capi.drawable()) */
static int
luaA_drawable_constructor(lua_State *L)
{
	/* Drawables are only created via drawin */
	/* Direct construction from Lua is not needed yet */
	return luaL_error(L, "drawable objects are created automatically by drawin");
}

/** Drawable tostring (class system signature: takes lua_State + lua_object_t) */
static int
luaA_drawable_tostring(lua_State *L, lua_object_t *obj)
{
	drawable_t *d = (drawable_t *)obj;
	lua_pushfstring(L, "drawable: %p %dx%d", (void*)d, d->geometry.width, d->geometry.height);
	return 1;
}

/** Property getter: surface (class system signature) */
static int
luaA_drawable_get_surface(lua_State *L, lua_object_t *obj)
{
	drawable_t *d = (drawable_t *)obj;
	if (d->surface) {
		/* Return a new reference for Lua - increment Cairo refcount */
		lua_pushlightuserdata(L, cairo_surface_reference(d->surface));
		return 1;
	}
	lua_pushnil(L);
	return 1;
}

/** Property getter: valid (class system signature) */
static int
luaA_drawable_get_valid_prop(lua_State *L, lua_object_t *obj)
{
	drawable_t *d = (drawable_t *)obj;
	lua_pushboolean(L, d->valid);
	return 1;
}

/** __index metamethod for property access */
static int
luaA_drawable_index(lua_State *L)
{
	const char *key;
	drawable_t *d;

	/* Get drawable (don't use luaA_checkdrawable - it's too strict with metatables) */
	d = (drawable_t *)lua_touserdata(L, 1);
	if (!d) {
		return luaL_error(L, "expected drawable, got %s", lua_typename(L, lua_type(L, 1)));
	}
	key = luaL_checkstring(L, 2);


	/* Check for methods first */
	lua_getmetatable(L, 1);
	lua_getfield(L, -1, key);
	if (!lua_isnil(L, -1)) {
		return 1;
	}
	lua_pop(L, 2);

	/* Check for properties */
	if (strcmp(key, "surface") == 0) {
		return luaA_drawable_get_surface(L, (lua_object_t *)d);
	}
	if (strcmp(key, "valid") == 0) {
		return luaA_drawable_get_valid_prop(L, (lua_object_t *)d);
	}

	/* Not found */
	return 0;
}

/** __newindex metamethod for property setting */
static int
luaA_drawable_newindex(lua_State *L)
{
	/* Drawable properties are read-only for now */
	const char *key = luaL_checkstring(L, 2);
	return luaL_error(L, "drawable property '%s' is read-only", key);
}

/** Setup drawable class */
void
drawable_class_setup(lua_State *L)
{
	static const struct luaL_Reg drawable_methods[] = {
		{ NULL, NULL }
	};

	static const struct luaL_Reg drawable_meta[] = {
		{ "__gc", luaA_drawable_gc },
		{ "__index", luaA_drawable_index },
		{ "__newindex", luaA_drawable_newindex },
		{ "refresh", luaA_drawable_refresh },
		{ "geometry", luaA_drawable_geometry },
		LUA_OBJECT_META(drawable)
		{ NULL, NULL }
	};

	/* Initialize drawable class using AwesomeWM class system */
	luaA_class_setup(L, &drawable_class, "drawable", NULL,
	                 (lua_class_allocator_t) drawable_allocator_wrapper,
	                 (lua_class_collector_t) drawable_wipe,
	                 NULL,  /* no checker */
	                 luaA_class_index_miss_property, luaA_class_newindex_miss_property,
	                 drawable_methods, drawable_meta);

	/* Register tostring callback with class system (matches client.c pattern) */
	luaA_class_set_tostring(&drawable_class, (lua_class_propfunc_t) luaA_drawable_tostring);

	/* Register read-only properties via class system */
	luaA_class_add_property(&drawable_class, "surface",
	                        (lua_class_propfunc_t) luaA_drawable_get_surface,
	                        NULL,  /* read-only, no setter */
	                        NULL);

	luaA_class_add_property(&drawable_class, "valid",
	                        (lua_class_propfunc_t) luaA_drawable_get_valid_prop,
	                        NULL,  /* read-only, no setter */
	                        NULL);
}

/** Register drawable in capi table */
void
luaA_drawable_setup(lua_State *L)
{
	drawable_class_setup(L);

	/* Register constructor in capi.drawable */
	lua_getglobal(L, "capi");
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setglobal(L, "capi");
	}

	lua_pushcfunction(L, luaA_drawable_constructor);
	lua_setfield(L, -2, "drawable");
	lua_pop(L, 1);
}
