/*
 * drawable.c - Drawable object implementation
 *
 * Stores widget geometry and connects its owner to the declared tree.
 * Lua supplies descriptions and receives solved boxes for placement.
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
#include "../widget.h"
#include "../declare.h"
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

/** Allocate a drawable
 * This is the public API used by drawin
 */
drawable_t *
drawable_allocator(lua_State *L)
{
	drawable_t *d = drawable_new(L);
	d->valid = true;  /* Drawable is valid when created */
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
	drawable_t *d = drawable_allocator(L);
	return (lua_object_t *)d;
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

/** Set drawable geometry (AwesomeWM pattern - area_t parameter). A size
 * change emits property::surface, the redraw trigger lua/wibox/drawable.lua
 * listens to; a move alone redraws nothing, since the tree does not depend
 * on where it is. */
void
drawable_set_geometry(lua_State *L, int didx, area_t geom)
{
	drawable_t *d = luaA_checkudata(L, didx, &drawable_class);
	area_t old = d->geometry;
	bool area_changed;

	d->geometry = geom;
	area_changed = !wlr_box_equal(&old, &geom);

	if ((old.width != geom.width || old.height != geom.height)
			&& geom.width > 0 && geom.height > 0)
		luaA_object_emit_signal(L, didx, "property::surface", 0);

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

	size_changed = (old_width != width || old_height != height);
	if (size_changed && width > 0 && height > 0)
		luaA_object_emit_signal(L, didx, "property::surface", 0);

}

/** Get or set drawable geometry
 * With no args: Returns table with {x=, y=, width=, height=}
 * With table arg: Sets geometry and emits the redraw trigger
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

/* Push the drawable: an item of its owner's environment, not a registry
 * object of its own. Pushes nil for an orphan. */
int
drawable_push(lua_State *L, drawable_t *d)
{
	void *owner = d->owner_type == DRAWABLE_OWNER_NONE ? NULL : d->owner.ptr;

	if (!owner) {
		lua_pushnil(L);
		return 1;
	}
	luaA_object_push(L, owner);
	luaA_object_push_item(L, -1, d);
	lua_remove(L, -2);
	return 1;
}

bool
drawable_widget_host(drawable_t *d, struct widget_host *out)
{
	if (!d)
		return false;
	if (d->owner_type == DRAWABLE_OWNER_DRAWIN)
		return drawin_widget_host(d->owner.drawin, out);
	if (d->owner_type == DRAWABLE_OWNER_CLIENT)
		return client_titlebar_host(d->owner.client, d, out);
	return false;
}

/** Store the converted widget tree for the renderer.
 * lua/wibox/drawable.lua calls this with the tree lua/wibox/clay.lua
 * compiled, from the frame's clay::declare. The frame declares the tree
 * from the store and, once solved, sends the drawable clay::solved with the
 * boxes (declare.h). Image entries reference their widget surfaces. Returns
 * false when no tree or host is available, or false with a reason ("budget"
 * or "malformed") when the tree is refused. These states show nothing.
 *
 * \param L The Lua VM state.
 * \param tree The node tree, or nil.
 * \return Whether a tree was stored.
 * \return The reason nothing shows, when the tree was refused.
 */
static int
luaA_drawable_clay_nodes(lua_State *L)
{
	drawable_t *d = (drawable_t *)lua_touserdata(L, 1);
	struct widget_host host = { 0 };

	if (!d) {
		return luaL_error(L, "expected drawable, got %s",
			lua_typename(L, lua_type(L, 1)));
	}

	if (!drawable_widget_host(d, &host)
			|| !widget_nodes_set(L, host.tree, host.m, 2)) {
		lua_pushboolean(L, false);
		if (host.tree && (host.tree->state == WIDGET_NODES_OVER_BUDGET
				|| host.tree->state == WIDGET_NODES_MALFORMED)) {
			lua_pushstring(L, host.tree->state == WIDGET_NODES_OVER_BUDGET
				? "budget" : "malformed");
			return 2;
		}
		return 1;
	}
	widget_leaves_set(host.tree);
	lua_pushboolean(L, true);
	return 1;
}

/** The size the stored tree's root takes, from a solve of its own now
 * (declare_widget_measure): what an awful.popup sizes itself by before any
 * frame. Nil for a drawable with no stored tree or no output.
 * \param L The Lua VM state.
 * \return The width and height, or nil.
 */
static int
luaA_drawable_clay_measure(lua_State *L)
{
	drawable_t *d = (drawable_t *)lua_touserdata(L, 1);
	struct widget_host host;
	int w, h;

	if (!drawable_widget_host(d, &host)
			|| !declare_widget_measure(&host, &w, &h))
		return 0;
	lua_pushinteger(L, w);
	lua_pushinteger(L, h);
	return 2;
}

/** Mark the drawable's output dirty, so a frame comes to compile and
 * declare it. Nothing for a drawable without an output.
 * \param L The Lua VM state.
 */
static int
luaA_drawable_clay_dirty(lua_State *L)
{
	drawable_t *d = (drawable_t *)lua_touserdata(L, 1);
	struct widget_host host;

	if (drawable_widget_host(d, &host) && host.m->declare)
		declare_output_mark_dirty(host.m->declare);
	return 0;
}

/** The widget nodes under a drawable-local point, as Clay's pointer query
 * answers it (declare_widget_hits): the preorder index of each, from 1,
 * outermost first. Empty for a drawable without a declared tree.
 * \param L The Lua VM state.
 * \param x The point, drawable-local.
 * \param y
 * \return The indices.
 */
static int
luaA_drawable_clay_hits(lua_State *L)
{
	static int hits[WIDGET_NODES_MAX];
	drawable_t *drawable = (drawable_t *)lua_touserdata(L, 1);
	double x = luaL_checknumber(L, 2), y = luaL_checknumber(L, 3);
	struct widget_host host;
	int n = drawable_widget_host(drawable, &host)
		? declare_widget_hits(&host, x, y, hits,
		WIDGET_NODES_MAX) : 0;

	lua_createtable(L, n, 0);
	for (int i = 0; i < n; i++) {
		lua_pushinteger(L, hits[i] + 1);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

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
		{ "__index", luaA_drawable_index },
		{ "__newindex", luaA_drawable_newindex },
		{ "geometry", luaA_drawable_geometry },
		{ "_clay_nodes", luaA_drawable_clay_nodes },
		{ "_clay_measure", luaA_drawable_clay_measure },
		{ "_clay_dirty", luaA_drawable_clay_dirty },
		{ "_clay_hits", luaA_drawable_clay_hits },
		LUA_OBJECT_META(drawable)
		{ NULL, NULL }
	};

	/* Initialize drawable class using AwesomeWM class system */
	luaA_class_setup(L, &drawable_class, "drawable", NULL,
	                 (lua_class_allocator_t) drawable_allocator_wrapper,
	                 NULL,
	                 NULL,  /* no checker */
	                 luaA_class_index_miss_property, luaA_class_newindex_miss_property,
	                 drawable_methods, drawable_meta);

	/* Register tostring callback with class system (matches client.c pattern) */
	luaA_class_set_tostring(&drawable_class, (lua_class_propfunc_t) luaA_drawable_tostring);

	const lua_class_property_t properties[] = {
		{ "valid", (lua_class_propfunc_t) luaA_drawable_get_valid_prop, NULL, NULL },
	};
	luaA_class_add_properties(&drawable_class, properties, countof(properties));
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
