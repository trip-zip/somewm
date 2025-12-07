#include "drawin.h"
#include "drawable.h"
#include "screen.h"
#include "signal.h"
#include "button.h"
#include "luaa.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "../somewm_api.h"
#include "../util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_buffer.h>
#include <drm_fourcc.h>

/* Access to global state from somewm.c */
extern struct wlr_scene_tree *layers[];
extern struct wlr_renderer *drw;
extern struct wlr_allocator *alloc;

/* AwesomeWM class system - drawin class */
lua_class_t drawin_class;

/* NOTE: LUA_OBJECT_FUNCS is now in drawin.h, not here */

/* Global array of drawin objects - stores Lua registry references
 * NOTE: This will be REMOVED once we fully migrate to luaA_class_setup()
 * The class system handles object tracking internally. */
static int *drawin_refs = NULL;
static size_t drawin_count = 0;
static size_t drawin_capacity = 0;

/* Forward declarations for signal array helpers (shared with screen.c) */
extern void signal_array_init(signal_array_t *arr);
extern void signal_array_wipe(signal_array_t *arr);

/* Forward declarations for internal helpers */
/* NOTE: Old signal_array_t system is DEPRECATED - class system uses environment tables now */
#if 0
static void signal_array_connect(lua_State *L, signal_array_t *arr, const char *name, int func_idx);
static void signal_array_emit(lua_State *L, signal_array_t *arr, const char *name, int obj_idx, int nargs);
static signal_t *signal_find(signal_array_t *arr, const char *name);
static signal_t *signal_create(signal_array_t *arr, const char *name);
static void signal_add_ref(signal_t *sig, int ref);
#endif

/* Forward declarations for workarea updates */
extern void luaA_screen_update_workarea_for_drawin(lua_State *L, drawin_t *drawin);

/* Forward declaration for drawable refresh callback */
static void drawin_refresh_drawable(drawin_t *drawin);

/* ========================================================================
 * Object signal support - DEPRECATED old signal_array_t system
 * ========================================================================
 *
 * The class system now handles signals via environment table storage.
 * These functions are deprecated and wrapped in #if 0 to prevent compilation.
 * DO NOT re-enable without understanding the dual signal system conflict!
 */
#if 0

/** Find a signal by name in an array */
static signal_t *
signal_find(signal_array_t *arr, const char *name)
{
	for (size_t i = 0; i < arr->count; i++) {
		if (strcmp(arr->signals[i].name, name) == 0)
			return &arr->signals[i];
	}
	return NULL;
}

/** Create a new signal in an array */
static signal_t *
signal_create(signal_array_t *arr, const char *name)
{
	signal_t *sig;

	/* Grow array if needed */
	if (arr->count >= arr->capacity) {
		size_t new_cap = arr->capacity == 0 ? 4 : arr->capacity * 2;
		signal_t *new_signals = realloc(arr->signals, new_cap * sizeof(signal_t));
		if (!new_signals) {
			fprintf(stderr, "somewm: failed to allocate signal array\n");
			return NULL;
		}
		arr->signals = new_signals;
		arr->capacity = new_cap;
	}

	/* Initialize new signal */
	sig = &arr->signals[arr->count++];
	sig->name = strdup(name);
	sig->refs = NULL;
	sig->ref_count = 0;
	sig->ref_capacity = 0;

	return sig;
}

/** Add a Lua callback reference to a signal */
static void
signal_add_ref(signal_t *sig, int ref)
{
	/* Grow refs array if needed */
	if (sig->ref_count >= sig->ref_capacity) {
		size_t new_cap = sig->ref_capacity == 0 ? 2 : sig->ref_capacity * 2;
		intptr_t *new_refs = realloc(sig->refs, new_cap * sizeof(intptr_t));
		if (!new_refs) {
			fprintf(stderr, "somewm: failed to allocate signal refs\n");
			return;
		}
		sig->refs = new_refs;
		sig->ref_capacity = new_cap;
	}

	sig->refs[sig->ref_count++] = ref;
}

/** Connect a signal handler to an object's signal array */
static void
signal_array_connect(lua_State *L, signal_array_t *arr, const char *name, int func_idx)
{
	signal_t *sig;
	int ref;

	/* Find or create signal */
	sig = signal_find(arr, name);
	if (!sig)
		sig = signal_create(arr, name);

	if (!sig)
		return;

	/* Store function in registry and get reference */
	lua_pushvalue(L, func_idx);  /* Duplicate function on stack */
	ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Add reference to signal */
	signal_add_ref(sig, ref);
}

/** Emit a signal from an object's signal array */
static void
signal_array_emit(lua_State *L, signal_array_t *arr, const char *name, int obj_idx, int nargs)
{
	signal_t *sig = signal_find(arr, name);
	fprintf(stderr, "[DRAWIN_SIGNAL_EMIT] Emitting signal '%s', sig=%p\n", name, (void*)sig);
	if (!sig) {
		fprintf(stderr, "[DRAWIN_SIGNAL_EMIT] No signal '%s' found, returning\n", name);
		return;  /* No callbacks connected, silently return */
	}

	fprintf(stderr, "[DRAWIN_SIGNAL_EMIT] Signal '%s' has %zu handlers\n", name, sig->ref_count);

	/* Normalize object index to absolute */
	if (obj_idx < 0)
		obj_idx = lua_gettop(L) + obj_idx + 1;

	/* Call each connected callback */
	for (size_t i = 0; i < sig->ref_count; i++) {
		fprintf(stderr, "[DRAWIN_SIGNAL_EMIT] Calling handler %zu for signal '%s'\n", i, name);
		/* Get callback function from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Push object as first argument */
		lua_pushvalue(L, obj_idx);

		/* Push additional arguments */
		for (int arg = 0; arg < nargs; arg++) {
			lua_pushvalue(L, obj_idx + 1 + arg);
		}

		/* Call the callback */
		if (lua_pcall(L, 1 + nargs, 0, 0) != 0) {
			fprintf(stderr, "somewm: error calling drawin signal '%s': %s\n",
			        name, lua_tostring(L, -1));
			lua_pop(L, 1);  /* Pop error message */
		}
		fprintf(stderr, "[DRAWIN_SIGNAL_EMIT] Handler %zu complete\n", i);
	}
	fprintf(stderr, "[DRAWIN_SIGNAL_EMIT] Signal '%s' emission complete\n", name);
}

/** Emit a signal from a drawin object (helper for internal use) */
static void
drawin_emit_signal(lua_State *L, int obj_idx, const char *name, int nargs)
{
	drawin_t *drawin = luaA_todrawin(L, obj_idx);
	fprintf(stderr, "[DRAWIN_EMIT_SIGNAL] Called with name='%s', obj_idx=%d, drawin=%p\n",
	        name, obj_idx, (void*)drawin);
	if (!drawin) {
		fprintf(stderr, "[DRAWIN_EMIT_SIGNAL] drawin is NULL, returning\n");
		return;
	}

	fprintf(stderr, "[DRAWIN_EMIT_SIGNAL] Calling signal_array_emit for signal '%s'\n", name);
	signal_array_emit(L, &drawin->signals, name, obj_idx, nargs);
	fprintf(stderr, "[DRAWIN_EMIT_SIGNAL] signal_array_emit returned\n");
}

#endif /* End deprecated signal_array_t system */

/** Refresh callback for drawable - called when drawable content should be displayed
 * This updates the scene graph buffer with new Cairo-rendered content
 */
static void
drawin_refresh_drawable(drawin_t *drawin)
{
	drawable_t *d;
	struct wlr_buffer *buffer;

	fprintf(stderr, "[DRAWIN_REFRESH] Called for drawin %p\n", (void*)drawin);

	if (!drawin || !drawin->scene_buffer || !drawin->drawable) {
		fprintf(stderr, "[DRAWIN_REFRESH] Early return: drawin=%p scene_buffer=%p drawable=%p\n",
		        (void*)drawin, (void*)(drawin ? drawin->scene_buffer : NULL),
		        (void*)(drawin ? drawin->drawable : NULL));
		return;
	}

	d = drawin->drawable;

	fprintf(stderr, "[DRAWIN_REFRESH] drawin geometry: %dx%d\n",
	        drawin->width, drawin->height);
	fprintf(stderr, "[DRAWIN_REFRESH] drawable geometry: %dx%d\n",
	        d->geometry.width, d->geometry.height);

	/* Ensure we have a Cairo surface with content */
	if (!d->surface || !d->refreshed) {
		fprintf(stderr, "[DRAWIN_REFRESH] No surface or not refreshed: surface=%p refreshed=%d\n",
		        (void*)d->surface, d->refreshed);
		return;
	}

	fprintf(stderr, "[DRAWIN_REFRESH] Creating buffer from surface %dx%d\n",
	        d->geometry.width, d->geometry.height);

	/* DEBUG: Save menu surface to PNG for inspection */
	if (drawin->width == 100 && drawin->height == 30) {
		static int menu_count = 0;
		char filename[256];
		snprintf(filename, sizeof(filename), "/tmp/menu_surface_%d.png", menu_count++);
		cairo_surface_write_to_png(d->surface, filename);
		fprintf(stderr, "[DRAWIN_REFRESH] Saved menu surface to %s\n", filename);
	}

	/* Create SHM buffer from drawable's Cairo surface
	 * This uses the shared buffer implementation in drawable.c */
	buffer = drawable_create_buffer(d);
	if (!buffer) {
		fprintf(stderr, "[DRAWIN_REFRESH] ERROR: Failed to create buffer from drawable\n");
		return;
	}

	fprintf(stderr, "[DRAWIN_REFRESH] Setting buffer on scene_buffer\n");

	/* Update scene buffer with new content
	 * NULL damage region means entire buffer is new */
	wlr_scene_buffer_set_buffer_with_damage(drawin->scene_buffer, buffer, NULL);

	/* Set the destination size to match drawin geometry for proper hit-testing
	 * Without this, wlroots uses the buffer's intrinsic size for hit detection,
	 * which breaks mouse input on the wibox */
	wlr_scene_buffer_set_dest_size(drawin->scene_buffer, drawin->width, drawin->height);

	/* Apply opacity if set (native Wayland compositing - no picom needed) */
	if (drawin->opacity >= 0)
		wlr_scene_buffer_set_opacity(drawin->scene_buffer, (float)drawin->opacity);

	fprintf(stderr, "[DRAWIN_REFRESH] Buffer attached successfully (dest size: %dx%d)\n",
	        drawin->width, drawin->height);

	/* Verify scene node state for debugging */
	fprintf(stderr, "[DRAWIN_REFRESH] Scene node enabled: %d\n",
	        drawin->scene_tree->node.enabled);
	fprintf(stderr, "[DRAWIN_REFRESH] Scene node position: %d,%d\n",
	        drawin->scene_tree->node.x, drawin->scene_tree->node.y);
	fprintf(stderr, "[DRAWIN_REFRESH] Scene buffer size: %dx%d\n",
	        buffer->width, buffer->height);
	fprintf(stderr, "[DRAWIN_REFRESH] *** WIBAR SHOULD BE VISIBLE AT %d,%d with size %dx%d ***\n",
	        drawin->x, drawin->y, drawin->width, drawin->height);

	/* Drop our reference - scene buffer holds its own reference */
	wlr_buffer_drop(buffer);
}

/** Assign screen to drawin based on its position
 * Called when drawin geometry changes
 */
static void
drawin_assign_screen(lua_State *L, drawin_t *drawin, int drawin_idx)
{
	Monitor *m;
	screen_t *new_screen;
	screen_t *old_screen = drawin->screen;

	/* Get monitor at drawin's position */
	m = some_monitor_at((double)drawin->x, (double)drawin->y);
	if (!m) {
		/* No monitor at this position, try getting focused monitor */
		m = some_get_focused_monitor();
	}

	if (m) {
		new_screen = luaA_screen_get_by_monitor(L, m);
	} else {
		new_screen = NULL;
	}

	/* If screen changed, update and emit signal */
	if (old_screen != new_screen) {
		drawin->screen = new_screen;

		/* Emit property::screen signal */
		if (drawin_idx != 0) {
			luaA_awm_object_emit_signal(L, drawin_idx, "property::screen", 0);
		}
	}
}

/* ========================================================================
 * Drawin object management - AwesomeWM class system
 * ======================================================================== */

/** Allocator for drawin objects (AwesomeWM class system)
 * This is called by luaA_class_setup() when a new drawin is created
 * \param L Lua state
 * \return Pointer to new drawin object
 */
static drawin_t *
drawin_allocator(lua_State *L)
{
	drawin_t *drawin;

	fprintf(stderr, "[DRAWIN_ALLOCATOR] Creating new drawin object\n");

	/* Call macro-generated drawin_new() to create and initialize the object
	 * This sets up the userdata, metatable, and basic class infrastructure */
	drawin = drawin_new(L);

	/* Initialize drawin object with AwesomeWM defaults */
	drawin->x = 0;
	drawin->y = 0;
	drawin->width = 1;
	drawin->height = 1;
	drawin->geometry_dirty = false;
	drawin->visible = false;
	drawin->ontop = false;
	drawin->opacity = -1.0;  /* -1 = inherit from parent/theme */
	drawin->cursor = strdup("left_ptr");
	drawin->type = WINDOW_TYPE_NORMAL;
	drawin->border_width = 0;
	drawin->border_color = (color_t){0, 0, 0, 255, false};  /* Uninitialized color */
	drawin->border_color_parsed = (color_t){0, 0, 0, 255, false};
	drawin->strut.left = 0;
	drawin->strut.right = 0;
	drawin->strut.top = 0;
	drawin->strut.bottom = 0;
	drawin->strut.left_start_y = 0;
	drawin->strut.left_end_y = 0;
	drawin->strut.right_start_y = 0;
	drawin->strut.right_end_y = 0;
	drawin->strut.top_start_x = 0;
	drawin->strut.top_end_x = 0;
	drawin->strut.bottom_start_x = 0;
	drawin->strut.bottom_end_x = 0;
	drawin->screen = NULL;
	drawin->drawable_ref = LUA_NOREF;
	drawin->drawable = NULL;  /* Set after drawable creation */

	/* Initialize signal and button arrays */
	signal_array_init(&drawin->signals);
	button_array_init(&drawin->buttons);

	fprintf(stderr, "[DRAWIN_ALLOCATOR] Initialized fields, creating scene graph nodes\n");

	/* Create scene graph nodes for rendering (Wayland-specific)
	 * This replaces AwesomeWM's X11 window creation */
	drawin->scene_tree = wlr_scene_tree_create(layers[LyrWibox]);
	drawin->scene_buffer = wlr_scene_buffer_create(drawin->scene_tree, NULL);
	drawin->scene_tree->node.data = drawin;

	/* Set initial position */
	wlr_scene_node_set_position(&drawin->scene_tree->node, drawin->x, drawin->y);

	/* Start disabled (not visible until visible=true) */
	wlr_scene_node_set_enabled(&drawin->scene_tree->node, false);

	/* Create border scene rects (mirrors client border pattern)
	 * Border layout: [0]=top, [1]=bottom, [2]=left, [3]=right
	 * Created as children of scene_tree so they move with the drawin */
	{
		float default_border_color[4] = {0.0f, 0.0f, 0.0f, 0.0f};  /* Transparent until set */
		int i;
		for (i = 0; i < 4; i++) {
			drawin->border[i] = wlr_scene_rect_create(drawin->scene_tree, 0, 0, default_border_color);
			drawin->border[i]->node.data = drawin;
		}
		drawin->border_need_update = false;
		drawin->border_color_parsed.initialized = false;
	}

	fprintf(stderr, "[DRAWIN_ALLOCATOR] Scene graph created, creating drawable\n");

	/* Create drawable object for rendering
	 * Stack: [drawin] */
	drawin->drawable = luaA_drawable_allocator(L, (drawable_refresh_callback)drawin_refresh_drawable, drawin);
	/* Stack: [drawin, drawable] */

	/* Store drawable reference in registry */
	drawin->drawable_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	/* Stack: [drawin] */

	/* Store drawable pointer (not drawin!) and set owner (AwesomeWM pattern)
	 * MUST happen AFTER drawable is created */
	drawin->scene_buffer->node.data = drawin->drawable;
	drawin->drawable->owner_type = DRAWABLE_OWNER_DRAWIN;
	drawin->drawable->owner.drawin = drawin;

	fprintf(stderr, "[DRAWIN_ALLOCATOR] Drawable created and stored, drawin=%p drawable=%p\n",
	        (void*)drawin, (void*)drawin->drawable);

	/* Assign initial screen based on position */
	drawin_assign_screen(L, drawin, -1);

	fprintf(stderr, "[DRAWIN_ALLOCATOR] Drawin allocated successfully\n");

	return drawin;
}

/** Collector for drawin objects (AwesomeWM class system)
 * This is called by the garbage collector to clean up resources
 * \param w Drawin object to destroy
 */
static void
drawin_wipe(drawin_t *w)
{
	fprintf(stderr, "[DRAWIN_WIPE] Cleaning up drawin %p\n", (void*)w);

	if (!w)
		return;

	/* Clean up signals */
	signal_array_wipe(&w->signals);

	/* Note: drawable reference cleanup handled by class system */
	w->drawable = NULL;

	/* Free allocated strings */
	if (w->cursor) {
		free(w->cursor);
		w->cursor = NULL;
	}
	/* Note: type is now an enum, border_color is a struct - no need to free */

	/* Wipe button array */
	button_array_wipe(&w->buttons);

	/* Destroy scene graph nodes */
	if (w->scene_tree) {
		wlr_scene_node_destroy(&w->scene_tree->node);
		w->scene_tree = NULL;
		w->scene_buffer = NULL;  /* Child node destroyed with parent */
		/* Border rects are also children, destroyed with parent */
		for (int i = 0; i < 4; i++)
			w->border[i] = NULL;
	}

	fprintf(stderr, "[DRAWIN_WIPE] Drawin cleanup complete\n");
}

/** Create a new drawin object (LEGACY - will be replaced by allocator)
 * \param L Lua state
 * \return Pointer to new drawin object
 */
drawin_t *
luaA_drawin_new(lua_State *L)
{
	drawin_t *drawin;
	int ref;

	/* Allocate drawin userdata */
	drawin = (drawin_t *)lua_newuserdata(L, sizeof(drawin_t));
	if (!drawin) {
		fprintf(stderr, "somewm: failed to allocate drawin object\n");
		return NULL;
	}

	/* Initialize drawin object with defaults (matching AwesomeWM) */
	drawin->x = 0;
	drawin->y = 0;
	drawin->width = 1;
	drawin->height = 1;
	drawin->geometry_dirty = false;
	drawin->visible = false;
	drawin->ontop = false;
	drawin->opacity = -1.0;  /* -1 = inherit from parent/theme */
	drawin->cursor = strdup("left_ptr");
	drawin->type = WINDOW_TYPE_NORMAL;
	drawin->border_width = 0;
	drawin->border_color = (color_t){0, 0, 0, 255, false};  /* Uninitialized color */
	drawin->border_color_parsed = (color_t){0, 0, 0, 255, false};
	drawin->strut.left = 0;
	drawin->strut.right = 0;
	drawin->strut.top = 0;
	drawin->strut.bottom = 0;
	drawin->strut.left_start_y = 0;
	drawin->strut.left_end_y = 0;
	drawin->strut.right_start_y = 0;
	drawin->strut.right_end_y = 0;
	drawin->strut.top_start_x = 0;
	drawin->strut.top_end_x = 0;
	drawin->strut.bottom_start_x = 0;
	drawin->strut.bottom_end_x = 0;
	drawin->screen = NULL;
	drawin->drawable_ref = LUA_NOREF;
	drawin->drawable = NULL;  /* Set after drawable creation */
	signal_array_init(&drawin->signals);
	button_array_init(&drawin->buttons);

	/* Create scene graph nodes for rendering */
	drawin->scene_tree = wlr_scene_tree_create(layers[LyrWibox]);
	drawin->scene_buffer = wlr_scene_buffer_create(drawin->scene_tree, NULL);
	drawin->scene_tree->node.data = drawin;

	/* Set initial position */
	wlr_scene_node_set_position(&drawin->scene_tree->node, drawin->x, drawin->y);

	/* Start disabled (not visible until visible=true) */
	wlr_scene_node_set_enabled(&drawin->scene_tree->node, false);

	/* Create border scene rects (mirrors client border pattern) */
	{
		float default_border_color[4] = {0.0f, 0.0f, 0.0f, 0.0f};
		int i;
		for (i = 0; i < 4; i++) {
			drawin->border[i] = wlr_scene_rect_create(drawin->scene_tree, 0, 0, default_border_color);
			drawin->border[i]->node.data = drawin;
		}
		drawin->border_need_update = false;
		drawin->border_color_parsed.initialized = false;
	}

	/* Set metatable */
	luaL_getmetatable(L, DRAWIN_MT);
	lua_setmetatable(L, -2);

	/* Initialize environment table for AwesomeWM compatibility */
	luaA_getuservalue(L, -1);

	/* Clear geometry from environment if present (geometry is method-only) */
	lua_pushnil(L);
	lua_setfield(L, -2, "geometry");

	/* Initialize _private table for AwesomeWM wibar compatibility */
	lua_newtable(L);
	lua_setfield(L, -2, "_private");

	lua_pop(L, 1);  /* Pop environment table */

	/* Create drawable object for rendering */
	/* Stack: [drawin] */
	drawin->drawable = luaA_drawable_allocator(L, (drawable_refresh_callback)drawin_refresh_drawable, drawin);
	/* Stack: [drawin, drawable] */

	/* Store drawable reference in registry */
	drawin->drawable_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	/* Stack: [drawin] */

	/* Store drawable pointer (not drawin!) and set owner (AwesomeWM pattern)
	 * MUST happen AFTER drawable is created */
	drawin->scene_buffer->node.data = drawin->drawable;
	drawin->drawable->owner_type = DRAWABLE_OWNER_DRAWIN;
	drawin->drawable->owner.drawin = drawin;

	/* Store in global drawin array */
	if (drawin_count >= drawin_capacity) {
		size_t new_cap = drawin_capacity == 0 ? 4 : drawin_capacity * 2;
		int *new_refs = realloc(drawin_refs, new_cap * sizeof(int));
		if (!new_refs) {
			fprintf(stderr, "somewm: failed to allocate drawin refs\n");
			return drawin;
		}
		drawin_refs = new_refs;
		drawin_capacity = new_cap;
	}

	/* Store reference in registry */
	lua_pushvalue(L, -1);
	ref = luaL_ref(L, LUA_REGISTRYINDEX);
	drawin_refs[drawin_count++] = ref;

	/* Assign initial screen based on position */
	drawin_assign_screen(L, drawin, -1);

	return drawin;
}

/* NOTE: luaA_object_push, luaA_checkdrawin() and luaA_todrawin() are now
 * handled by the class system via luaA_object_push() and LUA_OBJECT_FUNCS
 * macro in drawin.h - no manual implementation needed. This matches AwesomeWM's
 * approach and ensures proper signal emission. */

/* ========================================================================
 * Drawin property getters
 * ======================================================================== */

/** drawin.geometry - Get geometry as table */
static int
luaA_drawin_get_geometry(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	lua_newtable(L);
	lua_pushinteger(L, drawin->x);
	lua_setfield(L, -2, "x");
	lua_pushinteger(L, drawin->y);
	lua_setfield(L, -2, "y");
	lua_pushinteger(L, drawin->width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, drawin->height);
	lua_setfield(L, -2, "height");

	return 1;
}

/** drawin.x - Get x coordinate */
static int
luaA_drawin_get_x(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushinteger(L, drawin->x);
	return 1;
}

/** drawin.y - Get y coordinate */
static int
luaA_drawin_get_y(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushinteger(L, drawin->y);
	return 1;
}

/** drawin.width - Get width */
static int
luaA_drawin_get_width(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushinteger(L, drawin->width);
	return 1;
}

/** drawin.height - Get height */
static int
luaA_drawin_get_height(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushinteger(L, drawin->height);
	return 1;
}

/** drawin.visible - Get visibility */
static int
luaA_drawin_get_visible(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushboolean(L, drawin->visible);
	return 1;
}

/** drawin.ontop - Get ontop flag */
static int
luaA_drawin_get_ontop(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushboolean(L, drawin->ontop);
	return 1;
}

/** drawin.opacity - Get opacity */
static int
luaA_drawin_get_opacity(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	if (drawin->opacity < 0)
		lua_pushnil(L);
	else
		lua_pushnumber(L, drawin->opacity);
	return 1;
}

/** drawin.opacity - Set opacity
 * Applies transparency to the drawin's scene buffer using wlroots compositing.
 * \param L The Lua VM state.
 * \return Number of elements pushed on stack.
 */
static int
luaA_drawin_set_opacity(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	double opacity;

	if (lua_isnil(L, 2)) {
		/* nil = unset, restore to fully opaque */
		drawin->opacity = -1;
		if (drawin->scene_buffer)
			wlr_scene_buffer_set_opacity(drawin->scene_buffer, 1.0f);
	} else {
		opacity = luaL_checknumber(L, 2);
		if (opacity < 0 || opacity > 1)
			return luaL_error(L, "opacity must be between 0 and 1");
		drawin->opacity = opacity;
		if (drawin->scene_buffer)
			wlr_scene_buffer_set_opacity(drawin->scene_buffer, (float)opacity);
	}

	lua_pushvalue(L, 1);  /* Push drawin for signal */
	luaA_object_emit_signal(L, -1, "property::opacity", 0);
	lua_pop(L, 1);

	return 0;
}

/** drawin.cursor - Get cursor name */
static int
luaA_drawin_get_cursor(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushstring(L, drawin->cursor);
	return 1;
}

/** drawin.type - Get window type */
static int
luaA_drawin_get_type(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	/* Convert enum to string */
	const char *type_str = "normal";
	switch (drawin->type) {
		case WINDOW_TYPE_DESKTOP: type_str = "desktop"; break;
		case WINDOW_TYPE_DOCK: type_str = "dock"; break;
		case WINDOW_TYPE_TOOLBAR: type_str = "toolbar"; break;
		case WINDOW_TYPE_MENU: type_str = "menu"; break;
		case WINDOW_TYPE_UTILITY: type_str = "utility"; break;
		case WINDOW_TYPE_SPLASH: type_str = "splash"; break;
		case WINDOW_TYPE_DIALOG: type_str = "dialog"; break;
		case WINDOW_TYPE_DROPDOWN_MENU: type_str = "dropdown_menu"; break;
		case WINDOW_TYPE_POPUP_MENU: type_str = "popup_menu"; break;
		case WINDOW_TYPE_TOOLTIP: type_str = "tooltip"; break;
		case WINDOW_TYPE_NOTIFICATION: type_str = "notification"; break;
		case WINDOW_TYPE_COMBO: type_str = "combo"; break;
		case WINDOW_TYPE_DND: type_str = "dnd"; break;
		default: type_str = "normal"; break;
	}
	lua_pushstring(L, type_str);
	return 1;
}

/** drawin.drawable - Get associated drawable object for rendering */
static int
luaA_drawin_get_drawable(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	fprintf(stderr, "[DRAWIN_GET_DRAWABLE] drawin=%p drawable=%p drawable_ref=%d\n",
	        (void*)drawin, (void*)drawin->drawable, drawin->drawable_ref);

	if (drawin->drawable_ref != LUA_NOREF) {
		/* Push drawable from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, drawin->drawable_ref);
		fprintf(stderr, "[DRAWIN_GET_DRAWABLE] Retrieved from registry, type=%s\n",
		        lua_typename(L, lua_type(L, -1)));
	} else {
		fprintf(stderr, "[DRAWIN_GET_DRAWABLE] drawable_ref is NOREF, returning nil\n");
		lua_pushnil(L);
	}
	return 1;
}

/** drawin.border_width - Get border width */
static int
luaA_drawin_get_border_width(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushinteger(L, drawin->border_width);
	return 1;
}

/** drawin.border_width - Set border width */
static int
luaA_drawin_set_border_width(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	int old_width = drawin->border_width;
	int new_width = luaL_checkinteger(L, 2);

	if (new_width < 0)
		return luaL_error(L, "border_width must be >= 0");

	drawin->border_width = new_width;

	/* Mark for deferred border update (AwesomeWM pattern) */
	if (old_width != new_width) {
		drawin->border_need_update = true;

		lua_pushvalue(L, 1);  /* Push drawin */
		luaA_awm_object_emit_signal(L, -1, "property::border_width", 0);
		lua_pop(L, 1);
	}

	return 0;
}

/** drawin.border_color - Get border color */
static int
luaA_drawin_get_border_color(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	if (drawin->border_color.initialized) {
		return luaA_pushcolor(L, &drawin->border_color);
	} else {
		lua_pushnil(L);
		return 1;
	}
}

/** drawin.screen - Get assigned screen */
static int
luaA_drawin_get_screen(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	if (drawin->screen) {
		luaA_screen_push(L, drawin->screen);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

/** drawin.border_color - Set border color */
static int
luaA_drawin_set_border_color(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	/* Parse color from Lua (can be string or table) */
	if (!luaA_tocolor(L, 2, &drawin->border_color)) {
		return luaL_error(L, "Invalid color format");
	}

	/* Copy to parsed cache */
	drawin->border_color_parsed = drawin->border_color;

	/* Mark for deferred border update */
	if (drawin->border_color.initialized) {
		drawin->border_need_update = true;
	}

	/* Emit signal */
	lua_pushvalue(L, 1);  /* Push drawin */
	luaA_awm_object_emit_signal(L, -1, "property::border_color", 0);
	lua_pop(L, 1);

	return 0;
}

/** drawin:_buttons([buttons]) - Get or set buttons (AwesomeWM method)
 * This is the internal method called by wibox wrapper
 */
static int
luaA_drawin_buttons_method(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	/* If argument provided, set buttons */
	if (lua_gettop(L) >= 2) {
		luaA_button_array_set(L, 1, 2, &drawin->buttons);
		/* Emit property signal */
		luaA_awm_object_emit_signal(L, 1, "property::buttons", 0);
		return 0;
	}

	/* Return current buttons */
	return luaA_button_array_get(L, 1, &drawin->buttons);
}

/** drawin:struts() - Get or set struts */
static int
luaA_drawin_struts(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	/* If argument provided, set struts */
	if (lua_gettop(L) >= 2 && lua_istable(L, 2)) {
		strut_t old_strut = drawin->strut;
		strut_t new_strut = {0};

		lua_getfield(L, 2, "left");
		if (!lua_isnil(L, -1))
			new_strut.left = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "right");
		if (!lua_isnil(L, -1))
			new_strut.right = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "top");
		if (!lua_isnil(L, -1))
			new_strut.top = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "bottom");
		if (!lua_isnil(L, -1))
			new_strut.bottom = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		fprintf(stderr, "[DRAWIN_STRUTS] Setting struts for drawin %p: left=%d right=%d top=%d bottom=%d\n",
		        (void*)drawin, new_strut.left, new_strut.right, new_strut.top, new_strut.bottom);

		/* Update struts */
		drawin->strut = new_strut;

		/* Emit signal if struts changed */
		if (old_strut.left != new_strut.left ||
		    old_strut.right != new_strut.right ||
		    old_strut.top != new_strut.top ||
		    old_strut.bottom != new_strut.bottom) {
			lua_pushvalue(L, 1);  /* Push drawin */
			luaA_awm_object_emit_signal(L, -1, "property::struts", 0);
			lua_pop(L, 1);

			/* Update workarea if drawin is visible */
			if (drawin->visible && drawin->screen) {
				luaA_screen_update_workarea_for_drawin(L, drawin);
			}
		}

		return 0;
	}

	/* Return current struts */
	lua_newtable(L);
	lua_pushinteger(L, drawin->strut.left);
	lua_setfield(L, -2, "left");
	lua_pushinteger(L, drawin->strut.right);
	lua_setfield(L, -2, "right");
	lua_pushinteger(L, drawin->strut.top);
	lua_setfield(L, -2, "top");
	lua_pushinteger(L, drawin->strut.bottom);
	lua_setfield(L, -2, "bottom");

	return 1;
}

/* ========================================================================
 * Drawin property setters (with signal emission)
 * ======================================================================== */

/** Set drawin geometry and emit signals for changed properties
 * This follows AwesomeWM's pattern of emitting both composite and granular signals
 */
void
luaA_drawin_set_geometry(lua_State *L, drawin_t *drawin, int x, int y, int width, int height)
{
	int old_x = drawin->x;
	int old_y = drawin->y;
	int old_width = drawin->width;
	int old_height = drawin->height;
	bool geometry_changed = false;

	fprintf(stderr, "[DRAWIN_GEOM] Setting geometry: %dx%d+%d+%d (was %dx%d+%d+%d)\n",
	        width, height, x, y, old_width, old_height, old_x, old_y);

	/* Update geometry */
	drawin->x = x;
	drawin->y = y;
	drawin->width = width;
	drawin->height = height;
	drawin->geometry_dirty = true;

	/* Propagate geometry to drawable (this creates the Cairo surface) */
	if (drawin->drawable) {
		drawable_t *d = drawin->drawable;
		int old_dwidth = d->geometry.width;
		int old_dheight = d->geometry.height;

		fprintf(stderr, "[DRAWIN_GEOM] Propagating to drawable=%p %dx%d -> %dx%d\n",
		        (void*)d, old_dwidth, old_dheight, width, height);

		d->geometry.x = x;
		d->geometry.y = y;
		d->geometry.width = width;
		d->geometry.height = height;

		fprintf(stderr, "[DRAWIN_GEOM] Set drawable=%p geometry to %dx%d+%d+%d\n",
		        (void*)d, d->geometry.width, d->geometry.height, d->geometry.x, d->geometry.y);

		/* If size changed, recreate surface */
		fprintf(stderr, "[DRAWIN_GEOM] Checking size change: old=%dx%d new=%dx%d changed=%d\n",
		        old_dwidth, old_dheight, width, height, (old_dwidth != width || old_dheight != height));
		if (old_dwidth != width || old_dheight != height) {
			/* Clean up old surface */
			if (d->surface) {
				cairo_surface_finish(d->surface);
				cairo_surface_destroy(d->surface);
				d->surface = NULL;
			}

			/* Clean up old buffer */
			if (d->buffer) {
				wlr_buffer_drop(d->buffer);
				d->buffer = NULL;
			}

			/* Create new surface if we have valid dimensions */
			if (width > 0 && height > 0) {
				fprintf(stderr, "[DRAWIN_GEOM] Creating drawable=%p surface %dx%d\n", (void*)d, width, height);
				d->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
				if (cairo_surface_status(d->surface) != CAIRO_STATUS_SUCCESS) {
					fprintf(stderr, "[DRAWIN_GEOM] ERROR: Failed to create surface\n");
					cairo_surface_destroy(d->surface);
					d->surface = NULL;
				} else {
					fprintf(stderr, "[DRAWIN_GEOM] Surface=%p created successfully on drawable=%p\n",
					        (void*)d->surface, (void*)d);

					/* CRITICAL: Emit property::surface signal to trigger Lua widget repaint
					 * This notifies wibox/drawable.lua:413 to call redraw_callback() */
					fprintf(stderr, "[DRAWIN_GEOM] About to emit property::surface signal for drawable=%p\n", (void*)d);
					luaA_object_push(L, (void *)d);
					fprintf(stderr, "[DRAWIN_GEOM] Pushed drawable to stack\n");
					luaA_object_emit_signal(L, -1, "property::surface", 0);
					fprintf(stderr, "[DRAWIN_GEOM] Emitted property::surface signal\n");
					lua_pop(L, 1);  /* Pop drawable from stack */
				}
				d->refreshed = false;

				/* After creating new surface, trigger refresh to attach new buffer to scene graph
				 * This ensures the buffer with the correct size is displayed
				 */
				if (d->refresh_callback) {
					fprintf(stderr, "[DRAWIN_GEOM] Calling refresh_callback to attach new buffer\n");
					d->refreshed = true;
					d->refresh_callback(d->refresh_data);
				}
			}
		}
	} else {
		fprintf(stderr, "[DRAWIN_GEOM] No drawable to propagate to!\n");
	}

	/* Push drawin object for signal emission */
	luaA_object_push(L, drawin);

	/* Emit property signals for changed values */
	if (old_x != x || old_y != y || old_width != width || old_height != height) {
		luaA_awm_object_emit_signal(L, -1, "property::geometry", 0);
		geometry_changed = true;
	}

	if (old_x != x) {
		luaA_awm_object_emit_signal(L, -1, "property::x", 0);
	}

	if (old_y != y) {
		luaA_awm_object_emit_signal(L, -1, "property::y", 0);
	}

	if (old_width != width) {
		luaA_awm_object_emit_signal(L, -1, "property::width", 0);
	}

	if (old_height != height) {
		luaA_awm_object_emit_signal(L, -1, "property::height", 0);
	}

	/* Update screen assignment if position changed */
	if (old_x != x || old_y != y) {
		drawin_assign_screen(L, drawin, -1);
	}

	lua_pop(L, 1);  /* Pop drawin */

	/* Update workarea if struts are set and drawin is visible */
	if (geometry_changed && drawin->visible && drawin->screen &&
	    (drawin->strut.left || drawin->strut.right || drawin->strut.top || drawin->strut.bottom)) {
		luaA_screen_update_workarea_for_drawin(L, drawin);
	}

	/* Update scene graph node position if position changed */
	if (drawin->scene_tree && (old_x != x || old_y != y)) {
		wlr_scene_node_set_position(&drawin->scene_tree->node, x, y);
	}

	/* Update scene buffer destination size if size changed
	 * This ensures the hit-test region matches the new geometry */
	if (drawin->scene_buffer && (old_width != width || old_height != height)) {
		wlr_scene_buffer_set_dest_size(drawin->scene_buffer, width, height);
		fprintf(stderr, "[DRAWIN_GEOM] Updated scene buffer dest size to %dx%d\n", width, height);
	}

	/* Size changes handled by drawable - will recreate buffer on next refresh */
}

/** drawin.visible = value - Set visibility */
void
luaA_drawin_set_visible(lua_State *L, drawin_t *drawin, bool visible)
{
	fprintf(stderr, "[DRAWIN_SET_VISIBLE] Called: drawin=%p, current_visible=%d, new_visible=%d\n",
	        (void*)drawin, drawin->visible, visible);
	fprintf(stderr, "[DRAWIN_SET_VISIBLE] Stack dump - top=%d:\n", lua_gettop(L));
	for (int i = 1; i <= lua_gettop(L); i++) {
		fprintf(stderr, "[DRAWIN_SET_VISIBLE]   [%d] type=%s\n", i, lua_typename(L, lua_type(L, i)));
		if (lua_type(L, i) == LUA_TUSERDATA) {
			drawin_t *d = luaA_todrawin(L, i);
			fprintf(stderr, "[DRAWIN_SET_VISIBLE]   [%d] drawin=%p (match=%d)\n", i, (void*)d, d == drawin);
		}
	}

	if (drawin->visible == visible) {
		fprintf(stderr, "[DRAWIN_SET_VISIBLE] No change, returning early\n");
		return;  /* No change */
	}

	drawin->visible = visible;

	/* Update globalconf.drawins array to track visible drawins
	 * This matches AwesomeWM's drawin_map/unmap pattern */
	if (visible) {
		/* Add to visible drawins array if not already present */
		bool already_in_array = false;
		foreach(item, globalconf.drawins) {
			if (*item == drawin) {
				already_in_array = true;
				break;
			}
		}
		if (!already_in_array) {
			fprintf(stderr, "[DRAWIN_VISIBLE] Adding drawin %p to globalconf.drawins (count: %d -> %d)\n",
			        (void*)drawin, globalconf.drawins.len, globalconf.drawins.len + 1);
			drawin_array_append(&globalconf.drawins, drawin);
		}
	} else {
		/* Remove from visible drawins array */
		foreach(item, globalconf.drawins) {
			if (*item == drawin) {
				fprintf(stderr, "[DRAWIN_VISIBLE] Removing drawin %p from globalconf.drawins (count: %d -> %d)\n",
				        (void*)drawin, globalconf.drawins.len, globalconf.drawins.len - 1);
				drawin_array_remove(&globalconf.drawins, item);
				break;
			}
		}
	}

	fprintf(stderr, "[DRAWIN_VISIBLE] Setting drawin %p visible=%d, geometry=%dx%d+%d+%d\n",
	        (void*)drawin, visible, drawin->width, drawin->height, drawin->x, drawin->y);

	/* Emit signal on the drawin object (already on stack at index 1 from class property setter) */
	fprintf(stderr, "[DRAWIN_SET_VISIBLE] About to emit property::visible signal (obj at stack index 1)\n");
	luaA_awm_object_emit_signal(L, 1, "property::visible", 0);
	fprintf(stderr, "[DRAWIN_SET_VISIBLE] Signal emitted\n");

	/* Update workarea if struts are set */
	if (drawin->screen &&
	    (drawin->strut.left || drawin->strut.right || drawin->strut.top || drawin->strut.bottom)) {
		luaA_screen_update_workarea_for_drawin(L, drawin);
	}

	/* Enable/disable scene graph node to show/hide drawin */
	if (drawin->scene_tree) {
		fprintf(stderr, "[DRAWIN_VISIBLE] Setting scene_tree node enabled=%d (was: enabled=%d)\n",
		        visible, drawin->scene_tree->node.enabled);
		wlr_scene_node_set_enabled(&drawin->scene_tree->node, visible);
		fprintf(stderr, "[DRAWIN_VISIBLE] After set: scene_tree node enabled=%d\n",
		        drawin->scene_tree->node.enabled);
	} else {
		fprintf(stderr, "[DRAWIN_VISIBLE] ERROR: No scene_tree!\n");
	}
}

/** Helper to set individual drawin property and emit signal
 * Not used yet, reserved for future granular property setters
 */
#if 0
static void
drawin_set_property_int(lua_State *L, drawin_t *drawin, int *field, int value, const char *signal_name)
{
	if (*field == value)
		return;  /* No change */

	*field = value;
	drawin->geometry_dirty = true;

	luaA_object_push(L, drawin);
	luaA_awm_object_emit_signal(L, -1, signal_name, 0);
	lua_pop(L, 1);
}
#endif

/** Helper to set drawin boolean property and emit signal */
static void
drawin_set_property_bool(lua_State *L, drawin_t *drawin, bool *field, bool value, const char *signal_name)
{
	if (*field == value)
		return;  /* No change */

	*field = value;

	luaA_object_push(L, drawin);
	luaA_awm_object_emit_signal(L, -1, signal_name, 0);
	lua_pop(L, 1);
}

/** Helper to set drawin double property and emit signal */
static void
drawin_set_property_double(lua_State *L, drawin_t *drawin, double *field, double value, const char *signal_name)
{
	if (*field == value)
		return;  /* No change */

	*field = value;

	luaA_object_push(L, drawin);
	luaA_awm_object_emit_signal(L, -1, signal_name, 0);
	lua_pop(L, 1);
}

/** Helper to set drawin string property and emit signal */
static void
drawin_set_property_string(lua_State *L, drawin_t *drawin, char **field, const char *value, const char *signal_name)
{
	if (*field && value && strcmp(*field, value) == 0)
		return;  /* No change */

	if (*field)
		free(*field);
	*field = value ? strdup(value) : NULL;

	luaA_object_push(L, drawin);
	luaA_awm_object_emit_signal(L, -1, signal_name, 0);
	lua_pop(L, 1);
}

/** Set strut and update workarea */
void
luaA_drawin_set_strut(lua_State *L, drawin_t *drawin, strut_t strut)
{
	strut_t old_strut = drawin->strut;

	if (old_strut.left == strut.left &&
	    old_strut.right == strut.right &&
	    old_strut.top == strut.top &&
	    old_strut.bottom == strut.bottom)
		return;  /* No change */

	drawin->strut = strut;

	luaA_object_push(L, drawin);
	luaA_awm_object_emit_signal(L, -1, "property::struts", 0);
	lua_pop(L, 1);

	/* Update workarea if drawin is visible */
	if (drawin->visible && drawin->screen) {
		luaA_screen_update_workarea_for_drawin(L, drawin);
	}
}

/** Apply pending geometry changes
 * TODO: This will update wlr_scene_node position when rendering is implemented
 */
void
luaA_drawin_apply_geometry(drawin_t *drawin)
{
	if (!drawin->geometry_dirty)
		return;

	drawin->geometry_dirty = false;

	/* TODO: Update scene graph position when rendering is implemented */
	/* if (drawin->scene_tree) {
		wlr_scene_node_set_position(&drawin->scene_tree->node,
		                             drawin->x, drawin->y);
	} */
}

/** Refresh a single drawin's border visuals
 * Mirrors client_border_refresh() pattern from objects/client.c
 * Border layout: [0]=top, [1]=bottom, [2]=left, [3]=right
 * Borders are positioned OUTSIDE the content area (unlike client borders which are inside)
 */
static void
drawin_border_refresh_single(drawin_t *d)
{
	int bw;
	float color_floats[4];

	/* Skip if no update needed */
	if (!d->border_need_update)
		return;

	d->border_need_update = false;

	/* Skip if no scene tree (not yet created) */
	if (!d->scene_tree || !d->border[0])
		return;

	bw = d->border_width;

	fprintf(stderr, "[DRAWIN_BORDER] Updating borders for drawin %p: width=%d, geo=%dx%d\n",
	        (void*)d, bw, d->width, d->height);

	/* Update border rectangle sizes
	 * Borders go OUTSIDE the content area for drawins/wiboxes
	 * Top/bottom span full outer width, left/right span inner height */
	wlr_scene_rect_set_size(d->border[0], d->width + 2 * bw, bw);   /* top */
	wlr_scene_rect_set_size(d->border[1], d->width + 2 * bw, bw);   /* bottom */
	wlr_scene_rect_set_size(d->border[2], bw, d->height);           /* left */
	wlr_scene_rect_set_size(d->border[3], bw, d->height);           /* right */

	/* Update border positions relative to scene_tree origin (content at 0,0)
	 * Top: above content, left-aligned with outer edge
	 * Bottom: below content, left-aligned with outer edge
	 * Left: beside content on left
	 * Right: beside content on right */
	wlr_scene_node_set_position(&d->border[0]->node, -bw, -bw);      /* top */
	wlr_scene_node_set_position(&d->border[1]->node, -bw, d->height); /* bottom */
	wlr_scene_node_set_position(&d->border[2]->node, -bw, 0);        /* left */
	wlr_scene_node_set_position(&d->border[3]->node, d->width, 0);   /* right */

	/* Update border color if initialized */
	if (d->border_color_parsed.initialized) {
		color_to_floats(&d->border_color_parsed, color_floats);

		for (int i = 0; i < 4; i++)
			wlr_scene_rect_set_color(d->border[i], color_floats);

		fprintf(stderr, "[DRAWIN_BORDER] Applied color #%02x%02x%02x%02x to drawin %p\n",
		        d->border_color_parsed.red, d->border_color_parsed.green,
		        d->border_color_parsed.blue, d->border_color_parsed.alpha, (void*)d);
	}
}

/** Refresh all visible drawins (AwesomeWM compatibility)
 * Applies pending geometry changes for all visible drawins.
 * Called from some_refresh() main loop.
 *
 * In AwesomeWM this does xcb_configure_window and border refresh.
 * In Wayland, geometry is already applied via wlr_scene_node_set_position
 * in luaA_drawin_set_geometry(), borders use wlr_scene_rect.
 */
void
drawin_refresh(void)
{
	fprintf(stderr, "[DRAWIN_REFRESH] Processing %d visible drawins\n",
	        globalconf.drawins.len);

	foreach(item, globalconf.drawins)
	{
		drawin_t *d = *item;

		/* Apply pending geometry changes
		 * In AwesomeWM this does xcb_configure_window
		 * In Wayland, geometry already applied via wlr_scene_node_set_position
		 * in luaA_drawin_set_geometry(), so just clear the flag */
		if (d->geometry_dirty) {
			fprintf(stderr, "[DRAWIN_REFRESH] Clearing geometry_dirty for drawin %p\n",
			        (void*)d);
			d->geometry_dirty = false;
		}

		/* Apply pending border changes (mirrors window_border_refresh in AwesomeWM) */
		drawin_border_refresh_single(d);
	}
}

/* ========================================================================
 * Drawin Lua API - object methods (metamethods)
 * ======================================================================== */

/* REMOVED: Custom signal methods - replaced by class system
 * The class system's LUA_OBJECT_META provides connect_signal/emit_signal/disconnect_signal
 * that use environment table storage. These custom versions used the old signal_array_t
 * which is incompatible with the class system's signal emission.
 */
#if 0
/** drawin:connect_signal(name, callback) - Connect to a drawin signal [DEPRECATED] */
static int
luaA_drawin_connect_signal(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	const char *name = luaL_checkstring(L, 2);
	luaL_checktype(L, 3, LUA_TFUNCTION);

	if (drawin)
		signal_array_connect(L, &drawin->signals, name, 3);

	return 0;
}

/** drawin:emit_signal(name, ...) - Emit a drawin signal [DEPRECATED] */
static int
luaA_drawin_emit_signal_method(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	const char *name = luaL_checkstring(L, 2);
	int nargs = lua_gettop(L) - 2;

	if (drawin)
		signal_array_emit(L, &drawin->signals, name, 1, nargs);

	return 0;
}
#endif

/** drawin:geometry([geom]) - Get or set geometry
 * geom can be {x=, y=, width=, height=} table
 */
static int
luaA_drawin_geometry_method(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	/* If table argument provided, set geometry */
	if (lua_gettop(L) >= 2 && lua_istable(L, 2)) {
		int x = drawin->x, y = drawin->y;
		int width = drawin->width, height = drawin->height;

		lua_getfield(L, 2, "x");
		if (!lua_isnil(L, -1))
			x = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "y");
		if (!lua_isnil(L, -1))
			y = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "width");
		if (!lua_isnil(L, -1))
			width = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "height");
		if (!lua_isnil(L, -1))
			height = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		luaA_drawin_set_geometry(L, drawin, x, y, width, height);

		return 0;
	}

	/* Return current geometry */
	return luaA_drawin_get_geometry(L);
}

/** drawin:__index - Property getter [UNUSED - class system handles this now] */
static int __attribute__((unused))
luaA_drawin_index(lua_State *L)
{
	const char *key;

	/* Validate drawin object */
	luaA_checkdrawin(L, 1);
	key = luaL_checkstring(L, 2);

	/* Check for methods in metatable FIRST (so d:geometry() works) */
	if (strcmp(key, "geometry") == 0) {
		fprintf(stderr, "[DRAWIN_INDEX] Looking up 'geometry'...\n");
	}
	luaL_getmetatable(L, DRAWIN_MT);
	if (strcmp(key, "geometry") == 0) {
		fprintf(stderr, "[DRAWIN_INDEX] Got metatable, checking for geometry...\n");
	}
	lua_getfield(L, -1, key);
	if (strcmp(key, "geometry") == 0) {
		fprintf(stderr, "[DRAWIN_INDEX] geometry lookup result: %s\n",
		        lua_typename(L, lua_type(L, -1)));
	}
	if (!lua_isnil(L, -1)) {
		fprintf(stderr, "[DRAWIN_INDEX] Found '%s' in metatable, type=%s\n",
		        key, lua_typename(L, lua_type(L, -1)));
		return 1;
	}
	lua_pop(L, 2);  /* Pop nil and metatable */

	/* Check for properties */
	/* Special case: geometry is ONLY a method, never a property.
	 * Clear it from environment if present, then return the method function. */
	if (strcmp(key, "geometry") == 0) {
		/* Remove geometry from environment if it exists */
		luaA_getuservalue(L, 1);
		lua_pushnil(L);
		lua_setfield(L, -2, "geometry");
		lua_pop(L, 1);

		/* Return the method function from metatable */
		luaL_getmetatable(L, DRAWIN_MT);
		lua_getfield(L, -1, "geometry");
		lua_remove(L, -2);  /* Remove metatable, leaving just the function */
		return 1;
	}

	if (strcmp(key, "x") == 0)
		return luaA_drawin_get_x(L);
	if (strcmp(key, "y") == 0)
		return luaA_drawin_get_y(L);
	if (strcmp(key, "width") == 0)
		return luaA_drawin_get_width(L);
	if (strcmp(key, "height") == 0)
		return luaA_drawin_get_height(L);
	if (strcmp(key, "visible") == 0)
		return luaA_drawin_get_visible(L);
	if (strcmp(key, "ontop") == 0)
		return luaA_drawin_get_ontop(L);
	if (strcmp(key, "opacity") == 0)
		return luaA_drawin_get_opacity(L);
	if (strcmp(key, "cursor") == 0)
		return luaA_drawin_get_cursor(L);
	if (strcmp(key, "type") == 0)
		return luaA_drawin_get_type(L);
	if (strcmp(key, "drawable") == 0)
		return luaA_drawin_get_drawable(L);
	if (strcmp(key, "border_width") == 0)
		return luaA_drawin_get_border_width(L);
	if (strcmp(key, "border_color") == 0)
		return luaA_drawin_get_border_color(L);
	if (strcmp(key, "screen") == 0)
		return luaA_drawin_get_screen(L);

	/* Check for custom properties in environment table (AwesomeWM compatibility) */
	luaA_getuservalue(L, 1);  /* Get drawin's environment table */
	lua_pushvalue(L, 2);  /* Push key */
	lua_rawget(L, -2);  /* Get env[key] */
	return 1;
}

/** drawin:__newindex - Property setter [UNUSED - class system handles this now] */
static int __attribute__((unused))
luaA_drawin_newindex(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	const char *key = luaL_checkstring(L, 2);

	/* Handle writable properties */
	if (strcmp(key, "x") == 0) {
		int value = luaL_checkinteger(L, 3);
		luaA_drawin_set_geometry(L, drawin, value, drawin->y, drawin->width, drawin->height);
		return 0;
	}

	if (strcmp(key, "y") == 0) {
		int value = luaL_checkinteger(L, 3);
		luaA_drawin_set_geometry(L, drawin, drawin->x, value, drawin->width, drawin->height);
		return 0;
	}

	if (strcmp(key, "width") == 0) {
		int value = luaL_checkinteger(L, 3);
		if (value < 1) value = 1;  /* Minimum width */
		luaA_drawin_set_geometry(L, drawin, drawin->x, drawin->y, value, drawin->height);
		return 0;
	}

	if (strcmp(key, "height") == 0) {
		int value = luaL_checkinteger(L, 3);
		if (value < 1) value = 1;  /* Minimum height */
		luaA_drawin_set_geometry(L, drawin, drawin->x, drawin->y, drawin->width, value);
		return 0;
	}

	if (strcmp(key, "visible") == 0) {
		bool value = lua_toboolean(L, 3);
		luaA_drawin_set_visible(L, drawin, value);
		return 0;
	}

	if (strcmp(key, "ontop") == 0) {
		bool value = lua_toboolean(L, 3);
		drawin_set_property_bool(L, drawin, &drawin->ontop, value, "property::ontop");
		return 0;
	}

	if (strcmp(key, "opacity") == 0) {
		double value = -1.0;
		if (!lua_isnil(L, 3))
			value = luaL_checknumber(L, 3);
		drawin_set_property_double(L, drawin, &drawin->opacity, value, "property::opacity");
		return 0;
	}

	if (strcmp(key, "cursor") == 0) {
		const char *value = luaL_checkstring(L, 3);
		drawin_set_property_string(L, drawin, &drawin->cursor, value, "property::cursor");
		return 0;
	}

	if (strcmp(key, "type") == 0) {
		const char *value = luaL_checkstring(L, 3);
		/* Convert string to enum */
		window_type_t new_type = WINDOW_TYPE_NORMAL;
		if (strcmp(value, "desktop") == 0) new_type = WINDOW_TYPE_DESKTOP;
		else if (strcmp(value, "dock") == 0) new_type = WINDOW_TYPE_DOCK;
		else if (strcmp(value, "toolbar") == 0) new_type = WINDOW_TYPE_TOOLBAR;
		else if (strcmp(value, "menu") == 0) new_type = WINDOW_TYPE_MENU;
		else if (strcmp(value, "utility") == 0) new_type = WINDOW_TYPE_UTILITY;
		else if (strcmp(value, "splash") == 0) new_type = WINDOW_TYPE_SPLASH;
		else if (strcmp(value, "dialog") == 0) new_type = WINDOW_TYPE_DIALOG;
		else if (strcmp(value, "dropdown_menu") == 0) new_type = WINDOW_TYPE_DROPDOWN_MENU;
		else if (strcmp(value, "popup_menu") == 0) new_type = WINDOW_TYPE_POPUP_MENU;
		else if (strcmp(value, "tooltip") == 0) new_type = WINDOW_TYPE_TOOLTIP;
		else if (strcmp(value, "notification") == 0) new_type = WINDOW_TYPE_NOTIFICATION;
		else if (strcmp(value, "combo") == 0) new_type = WINDOW_TYPE_COMBO;
		else if (strcmp(value, "dnd") == 0) new_type = WINDOW_TYPE_DND;

		if (drawin->type != new_type) {
			drawin->type = new_type;
			luaA_awm_object_emit_signal(L, 1, "property::type", 0);
		}
		return 0;
	}

	if (strcmp(key, "border_width") == 0) {
		lua_pushvalue(L, 1);  /* Push drawin to stack position 1 for setter */
		lua_pushvalue(L, 3);  /* Push value to stack position 2 for setter */
		return luaA_drawin_set_border_width(L);
	}

	if (strcmp(key, "border_color") == 0) {
		lua_pushvalue(L, 1);  /* Push drawin to stack position 1 for setter */
		lua_pushvalue(L, 3);  /* Push value to stack position 2 for setter */
		return luaA_drawin_set_border_color(L);
	}

	/* For AwesomeWM compatibility: Allow arbitrary properties to be stored
	 * in the userdata environment table. This allows Lua code to attach
	 * methods/properties like get_wibox() that aren't in C.
	 *
	 * EXCEPTION: Don't allow "geometry" to be stored, as it should only
	 * be accessible as a method from the metatable. */
	if (strcmp(key, "geometry") == 0) {
		fprintf(stderr, "[DRAWIN_NEWINDEX] Attempt to set geometry blocked! type=%s\n",
		        lua_typename(L, lua_type(L, 3)));
		return luaL_error(L, "drawin property 'geometry' is read-only (use d:geometry() method)");
	}

	luaA_getuservalue(L, 1);  /* Get drawin's environment table */
	lua_pushvalue(L, 2);  /* Push key */
	lua_pushvalue(L, 3);  /* Push value */
	lua_rawset(L, -3);  /* env[key] = value */
	lua_pop(L, 1);  /* Pop environment table */

	return 0;
}

/** drawin:__tostring - Convert to string */
static int
luaA_drawin_tostring(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);
	lua_pushfstring(L, "drawin{x=%d, y=%d, width=%d, height=%d, visible=%s}",
	                drawin->x, drawin->y, drawin->width, drawin->height,
	                drawin->visible ? "true" : "false");
	return 1;
}

/** drawin:__gc - Garbage collector */
static int
luaA_drawin_gc(lua_State *L)
{
	drawin_t *drawin = luaA_todrawin(L, 1);

	if (drawin) {
		/* Clean up signals */
		signal_array_wipe(&drawin->signals);

		/* Unref drawable */
		if (drawin->drawable_ref != LUA_NOREF) {
			luaL_unref(L, LUA_REGISTRYINDEX, drawin->drawable_ref);
			drawin->drawable_ref = LUA_NOREF;
		}
		drawin->drawable = NULL;  /* Drawable will be GC'd separately */

		/* Free allocated strings */
		if (drawin->cursor) {
			free(drawin->cursor);
			drawin->cursor = NULL;
		}
		/* Note: type is enum, border_color is struct - no need to free */

		/* Wipe button array */
		button_array_wipe(&drawin->buttons);

		/* Destroy scene graph nodes */
		if (drawin->scene_tree) {
			wlr_scene_node_destroy(&drawin->scene_tree->node);
			drawin->scene_tree = NULL;
			drawin->scene_buffer = NULL;  /* Child node destroyed with parent */
		}
	}
	return 0;
}

/* ========================================================================
 * Drawin class setup
 * ======================================================================== */

/* Property wrappers that match lua_class_propfunc_t signature
 * These wrap the actual getter functions which have the old signature */
static int luaA_drawin_get_drawable_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj; /* Object already on stack at index 1 */
	return luaA_drawin_get_drawable(L);
}
static int luaA_drawin_get_visible_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_visible(L);
}

/** Setter wrapper for visible property (called when Lua sets drawin.visible = value)
 * Stack: [..., value]  (value is at top of stack)
 */
static int luaA_drawin_set_visible_wrapper(lua_State *L, lua_object_t *obj) {
	drawin_t *drawin = (drawin_t *)obj;
	bool value = lua_toboolean(L, -1);
	fprintf(stderr, "[DRAWIN_SET_VISIBLE_WRAPPER] Setting visible=%d on drawin %p\n",
	        value, (void*)drawin);
	luaA_drawin_set_visible(L, drawin, value);
	return 0;
}
static int luaA_drawin_get_ontop_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_ontop(L);
}
static int luaA_drawin_get_cursor_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_cursor(L);
}
static int luaA_drawin_get_x_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_x(L);
}
static int luaA_drawin_get_y_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_y(L);
}
static int luaA_drawin_get_width_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_width(L);
}
static int luaA_drawin_get_height_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_height(L);
}

/** New callback for width property (called during drawin construction)
 * Stack: [args_table, ..., drawin_object, property_value]
 */
static int luaA_drawin_new_width(lua_State *L, lua_object_t *obj) {
	drawin_t *drawin = (drawin_t *)obj;
	if (!lua_isnil(L, -1)) {
		int width = luaL_checkinteger(L, -1);
		if (width < 1) width = 1;
		fprintf(stderr, "[DRAWIN_NEW] Setting width during construction: %d -> geometry %dx%d\n",
		        width, width, drawin->height);
		luaA_drawin_set_geometry(L, drawin, drawin->x, drawin->y, width, drawin->height);
	}
	return 0;
}

/** New callback for height property (called during drawin construction)
 * Stack: [args_table, ..., drawin_object, property_value]
 */
static int luaA_drawin_new_height(lua_State *L, lua_object_t *obj) {
	drawin_t *drawin = (drawin_t *)obj;
	if (!lua_isnil(L, -1)) {
		int height = luaL_checkinteger(L, -1);
		if (height < 1) height = 1;
		fprintf(stderr, "[DRAWIN_NEW] Setting height during construction: %d -> geometry %dx%d\n",
		        height, drawin->width, height);
		luaA_drawin_set_geometry(L, drawin, drawin->x, drawin->y, drawin->width, height);
	}
	return 0;
}

/** New callback for x property (called when x is set)
 * Stack: [args_table, ..., drawin_object, property_value]
 */
static int luaA_drawin_new_x(lua_State *L, lua_object_t *obj) {
	drawin_t *drawin = (drawin_t *)obj;
	if (!lua_isnil(L, -1)) {
		int x = luaL_checkinteger(L, -1);
		fprintf(stderr, "[DRAWIN_NEW] Setting x: %d (was %d) -> geometry %dx%d+%d+%d\n",
		        x, drawin->x, drawin->width, drawin->height, x, drawin->y);
		luaA_drawin_set_geometry(L, drawin, x, drawin->y, drawin->width, drawin->height);
	}
	return 0;
}

/** New callback for y property (called when y is set)
 * Stack: [args_table, ..., drawin_object, property_value]
 */
static int luaA_drawin_new_y(lua_State *L, lua_object_t *obj) {
	drawin_t *drawin = (drawin_t *)obj;
	if (!lua_isnil(L, -1)) {
		int y = luaL_checkinteger(L, -1);
		fprintf(stderr, "[DRAWIN_NEW] Setting y: %d (was %d) -> geometry %dx%d+%d+%d\n",
		        y, drawin->y, drawin->width, drawin->height, drawin->x, y);
		luaA_drawin_set_geometry(L, drawin, drawin->x, y, drawin->width, drawin->height);
	}
	return 0;
}

static int luaA_drawin_get_type_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_type(L);
}
static int luaA_drawin_get_opacity_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_opacity(L);
}
static int luaA_drawin_set_opacity_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_set_opacity(L);
}
static int luaA_drawin_get_border_width_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_get_border_width(L);
}
static int luaA_drawin_set_border_width_wrapper(lua_State *L, lua_object_t *obj) {
	(void)obj;
	return luaA_drawin_set_border_width(L);
}

/** Drawin constructor for Lua (called when user does capi.drawin{...})
 * \param L The Lua VM state
 * \return Number of elements pushed on stack (always 1 - the drawin object)
 */
static int
luaA_drawin_call(lua_State *L)
{
	return luaA_class_new(L, &drawin_class);
}

/* Drawin class methods - added to the drawin CLASS table (not instances)
 * LUA_CLASS_METHODS adds: set_index_miss_handler, set_newindex_miss_handler,
 * connect_signal, disconnect_signal, emit_signal, instances, set_fallback */
static const luaL_Reg drawin_methods[] = {
	LUA_CLASS_METHODS(drawin)
	{ "__call", luaA_drawin_call },
	{ NULL, NULL }
};

/* Drawin metatable methods - added to instance metatables
 * LUA_OBJECT_META adds instance signal methods: connect_signal, disconnect_signal, emit_signal
 * LUA_CLASS_META adds: __index, __newindex for property handling
 */
static const luaL_Reg drawin_meta[] = {
	LUA_OBJECT_META(drawin)
	LUA_CLASS_META
	/* Keep __tostring and __gc, but let class system handle __index/__newindex */
	{ "__tostring", luaA_drawin_tostring },
	{ "__gc", luaA_drawin_gc },
	/* Instance methods (still valid with class system) */
	{ "geometry", luaA_drawin_geometry_method },
	{ "struts", luaA_drawin_struts },
	{ "_buttons", luaA_drawin_buttons_method },
	/* NOTE: LUA_OBJECT_META provides connect_signal/emit_signal/disconnect_signal
	 * using the class system's environment table storage. DO NOT override them
	 * with custom versions, or signals won't work! */
	{ NULL, NULL }
};

/** Setup drawin class using AwesomeWM class system
 * This replaces the old manual metatable setup with luaA_class_setup()
 */
void
luaA_drawin_class_setup(lua_State *L)
{
	fprintf(stderr, "\n[DRAWIN_CLASS_SETUP] ========================================\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] Setting up drawin class with luaA_class_setup()\n");

	/* Setup drawin class using AwesomeWM's class infrastructure
	 * This creates:
	 * - A CLASS TABLE with methods (set_index_miss_handler, etc.)
	 * - An __call metamethod to make the class callable (constructor)
	 * - Proper __index/__newindex that respect property getters/setters
	 * - Signal infrastructure for class and instance signals
	 */
	luaA_class_setup(L, &drawin_class, "drawin",
	                 NULL,  /* No parent class (window_class is X11-specific) */
	                 (lua_class_allocator_t) drawin_allocator,
	                 (lua_class_collector_t) drawin_wipe,
	                 NULL,  /* No checker function (uses default) */
	                 NULL,  /* Property getter fallback - no fallback for now */
	                 NULL,  /* Property setter fallback - no fallback for now */
	                 drawin_methods,  /* Class-level methods */
	                 drawin_meta);    /* Instance metatable methods */

	/* Register drawin properties (matching AwesomeWM) */
	luaA_class_add_property(&drawin_class, "drawable",
	                        NULL,
	                        luaA_drawin_get_drawable_wrapper,
	                        NULL);
	luaA_class_add_property(&drawin_class, "visible",
	                        luaA_drawin_set_visible_wrapper,  // cb_new: for construction
	                        luaA_drawin_get_visible_wrapper,   // cb_index: getter
	                        luaA_drawin_set_visible_wrapper);  // cb_newindex: setter (FIX!)
	luaA_class_add_property(&drawin_class, "ontop",
	                        NULL,
	                        luaA_drawin_get_ontop_wrapper,
	                        NULL);
	luaA_class_add_property(&drawin_class, "cursor",
	                        NULL,
	                        luaA_drawin_get_cursor_wrapper,
	                        NULL);
	luaA_class_add_property(&drawin_class, "x",
	                        NULL,
	                        luaA_drawin_get_x_wrapper,
	                        luaA_drawin_new_x);
	luaA_class_add_property(&drawin_class, "y",
	                        NULL,
	                        luaA_drawin_get_y_wrapper,
	                        luaA_drawin_new_y);
	luaA_class_add_property(&drawin_class, "width",
	                        NULL,
	                        luaA_drawin_get_width_wrapper,
	                        luaA_drawin_new_width);
	luaA_class_add_property(&drawin_class, "height",
	                        NULL,
	                        luaA_drawin_get_height_wrapper,
	                        luaA_drawin_new_height);
	luaA_class_add_property(&drawin_class, "type",
	                        NULL,
	                        luaA_drawin_get_type_wrapper,
	                        NULL);
	luaA_class_add_property(&drawin_class, "opacity",
	                        luaA_drawin_set_opacity_wrapper,
	                        luaA_drawin_get_opacity_wrapper,
	                        luaA_drawin_set_opacity_wrapper);
	/* NOTE: buttons is NOT registered as a property, only as a _buttons method.
	 * The wibox wrapper handles the buttons accessor via _legacy_accessors */
	luaA_class_add_property(&drawin_class, "border_width",
	                        NULL,
	                        luaA_drawin_get_border_width_wrapper,
	                        luaA_drawin_set_border_width_wrapper);

	fprintf(stderr, "[DRAWIN_CLASS_SETUP] Class setup complete!\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] - Class table created with 7 class methods\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] - Metatable created with signal methods\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] - Allocator: drawin_allocator()\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] - Collector: drawin_wipe()\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] - Registered 11 properties (border_width added; buttons is a method)\n");
	fprintf(stderr, "[DRAWIN_CLASS_SETUP] ========================================\n\n");
}

/** Constructor for drawin objects - capi.drawin(args)
 * args is optional table with initial properties
 *
 * NOTE: This is now UNUSED - the class system's __call metamethod handles construction
 * via drawin_allocator(). Keeping for reference during migration.
 */
#if 0
static int
luaA_drawin_constructor(lua_State *L)
{
	drawin_t *drawin;

	/* Create new drawin */
	drawin = luaA_drawin_new(L);
	if (!drawin)
		return 0;

	/* If args table provided, set properties
	 * Stack before luaA_drawin_new: [args_table]
	 * Stack after luaA_drawin_new: [args_table, drawin]
	 * So args is at index 1, drawin is at index 2
	 */
	if (lua_gettop(L) >= 2 && lua_istable(L, 1)) {
		/* Apply properties from args table at index 1 */
		lua_getfield(L, 1, "x");
		if (!lua_isnil(L, -1))
			drawin->x = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "y");
		if (!lua_isnil(L, -1))
			drawin->y = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "width");
		if (!lua_isnil(L, -1))
			drawin->width = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "height");
		if (!lua_isnil(L, -1))
			drawin->height = luaL_checkinteger(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "visible");
		if (!lua_isnil(L, -1))
			drawin->visible = lua_toboolean(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "ontop");
		if (!lua_isnil(L, -1))
			drawin->ontop = lua_toboolean(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "opacity");
		if (!lua_isnil(L, -1))
			drawin->opacity = luaL_checknumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "cursor");
		if (!lua_isnil(L, -1)) {
			const char *cursor = luaL_checkstring(L, -1);
			free(drawin->cursor);
			drawin->cursor = strdup(cursor);
		}
		lua_pop(L, 1);

		lua_getfield(L, 1, "type");
		if (!lua_isnil(L, -1)) {
			const char *type = luaL_checkstring(L, -1);
			free(drawin->type);
			drawin->type = strdup(type);
		}
		lua_pop(L, 1);

		/* CRITICAL FIX: Sync drawin geometry to drawable after args are set
		 * Without this, the drawable stays at 1x1 while drawin has the real size,
		 * causing all non-wibar widgets to fail to render properly.
		 */
		luaA_drawin_set_geometry(L, drawin, drawin->x, drawin->y,
		                         drawin->width, drawin->height);
	}

	/* Drawin object is already on stack from luaA_drawin_new() */
	return 1;
}
#endif /* Disabled luaA_drawin_constructor - using class system instead */

/** Setup drawin module - register class and add to capi
 * This is called during luaA_init() to expose drawin API to Lua
 */
void
luaA_drawin_setup(lua_State *L)
{
	fprintf(stderr, "\n[DRAWIN_SETUP] ==========================================\n");
	fprintf(stderr, "[DRAWIN_SETUP] Initializing drawin module with class system\n");

	/* Setup class using luaA_class_setup()
	 * This automatically:
	 * - Creates a CLASS TABLE as global 'drawin'
	 * - Adds class methods (set_index_miss_handler, etc.)
	 * - Makes it callable via __call metamethod (constructor)
	 * - Sets up signal infrastructure
	 */
	luaA_drawin_class_setup(L);

	fprintf(stderr, "[DRAWIN_SETUP] Class setup complete, adding to capi...\n");

	/* Get or create capi table */
	lua_getglobal(L, "capi");
	if (lua_isnil(L, -1)) {
		fprintf(stderr, "[DRAWIN_SETUP] capi table doesn't exist, creating it\n");
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setglobal(L, "capi");
	}

	/* Get the drawin class (already registered as global by luaA_class_setup) */
	lua_getglobal(L, "drawin");

	/* Set capi.drawin = drawin class table */
	lua_setfield(L, -2, "drawin");
	fprintf(stderr, "[DRAWIN_SETUP] Registered drawin class in capi.drawin\n");

	lua_pop(L, 1);  /* Pop capi table */

	/* Verify what we registered */
	lua_getglobal(L, "drawin");
	fprintf(stderr, "[DRAWIN_SETUP] ==========================================\n");
	fprintf(stderr, "[DRAWIN_SETUP] VERIFICATION: global 'drawin' type = %s\n",
	        lua_typename(L, lua_type(L, -1)));
	fprintf(stderr, "[DRAWIN_SETUP] VERIFICATION: Is it a table? %s\n",
	        lua_istable(L, -1) ? "YES ✓" : "NO ✗");

	/* Check if it has class methods that AwesomeWM expects */
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "set_index_miss_handler");
		fprintf(stderr, "[DRAWIN_SETUP] Has set_index_miss_handler? %s\n",
		        lua_isfunction(L, -1) ? "YES ✓" : "NO ✗");
		lua_pop(L, 1);

		lua_getfield(L, -1, "set_newindex_miss_handler");
		fprintf(stderr, "[DRAWIN_SETUP] Has set_newindex_miss_handler? %s\n",
		        lua_isfunction(L, -1) ? "YES ✓" : "NO ✗");
		lua_pop(L, 1);

		/* Check if it's callable (has __call metamethod) */
		if (lua_getmetatable(L, -1)) {
			lua_getfield(L, -1, "__call");
			fprintf(stderr, "[DRAWIN_SETUP] Is callable (__call)? %s\n",
			        lua_isfunction(L, -1) ? "YES ✓" : "NO ✗");
			lua_pop(L, 2);  /* Pop __call and metatable */
		}
	}
	lua_pop(L, 1);

	fprintf(stderr, "[DRAWIN_SETUP] ==========================================\n");
	fprintf(stderr, "[DRAWIN_SETUP] SUCCESS: drawin is now a proper CLASS TABLE!\n");
	fprintf(stderr, "[DRAWIN_SETUP] - It has class methods (set_index_miss_handler, etc.)\n");
	fprintf(stderr, "[DRAWIN_SETUP] - It's callable as a constructor (via __call)\n");
	fprintf(stderr, "[DRAWIN_SETUP] - Properties will use getter/setter functions\n");
	fprintf(stderr, "[DRAWIN_SETUP] - This matches AwesomeWM's class system!\n");
	fprintf(stderr, "[DRAWIN_SETUP] ==========================================\n\n");
}
