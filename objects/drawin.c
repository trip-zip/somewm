#include "drawin.h"
#include "drawable.h"
#include "screen.h"
#include "signal.h"
#include "button.h"
#include "luaa.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "../somewm_api.h"
#include "../stack.h"
#include "common/util.h"
#include "../globalconf.h"
#include "../shadow.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output.h>
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

/* DISABLED: Legacy drawin tracking - class system handles this now.
 * Only used by disabled drawin_new_legacy() below. */
#if 0
static int *drawin_refs = NULL;
static size_t drawin_count = 0;
static size_t drawin_capacity = 0;
#endif

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
extern void screen_update_workarea(screen_t *screen);

/* Forward declaration for drawable refresh callback */
static void drawin_refresh_drawable(drawin_t *drawin);

/** Ensure drawable has a surface with correct geometry.
 * Matches AwesomeWM's drawin_update_drawing (drawin.c:194-200).
 * Called when drawin becomes visible to ensure Lua has a surface to draw to.
 * \param L The Lua VM state.
 * \param widx The drawin stack index.
 */
static void
drawin_update_drawing(lua_State *L, int widx)
{
	drawin_t *w = luaA_checkudata(L, widx, &drawin_class);
	luaA_object_push_item(L, widx, w->drawable);
	drawable_set_geometry(L, -1, (area_t) {
		.x = w->x,
		.y = w->y,
		.width = w->width,
		.height = w->height
	});
	lua_pop(L, 1);
}

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
	if (!sig)
		return;  /* No callbacks connected, silently return */

	/* Normalize object index to absolute */
	if (obj_idx < 0)
		obj_idx = lua_gettop(L) + obj_idx + 1;

	/* Call each connected callback */
	for (size_t i = 0; i < sig->ref_count; i++) {
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
	}
}

/** Emit a signal from a drawin object (helper for internal use) */
static void
drawin_emit_signal(lua_State *L, int obj_idx, const char *name, int nargs)
{
	drawin_t *drawin = luaA_todrawin(L, obj_idx);
	if (!drawin)
		return;

	signal_array_emit(L, &drawin->signals, name, obj_idx, nargs);
}

#endif /* End deprecated signal_array_t system */

/** Refresh callback for drawable - called when drawable content should be displayed
 * This updates the scene graph buffer with new Cairo-rendered content
 */
/** Apply shape_bounding mask to a drawable surface.
 * Creates a copy of the surface with alpha zeroed where shape is 0.
 * Returns a new cairo_surface_t that the caller must destroy.
 * Returns NULL if no shape or allocation fails.
 */
static cairo_surface_t *
drawin_apply_shape_mask(drawable_t *d, cairo_surface_t *shape)
{
	cairo_surface_t *src, *dst;
	unsigned char *src_data, *dst_data, *shape_data;
	int src_stride, dst_stride, shape_stride;
	int width, height, shape_width, shape_height;
	int x, y;

	if (!d || !d->surface || !shape)
		return NULL;

	/* Check if surfaces are still valid (not finished by GC) */
	if (cairo_surface_status(d->surface) != CAIRO_STATUS_SUCCESS ||
	    cairo_surface_status(shape) != CAIRO_STATUS_SUCCESS)
		return NULL;

	src = d->surface;
	cairo_surface_flush(src);
	cairo_surface_flush(shape);

	width = cairo_image_surface_get_width(src);
	height = cairo_image_surface_get_height(src);
	shape_width = cairo_image_surface_get_width(shape);
	shape_height = cairo_image_surface_get_height(shape);

	/* Create a copy of the surface */
	dst = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(dst) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(dst);
		return NULL;
	}

	src_data = cairo_image_surface_get_data(src);
	dst_data = cairo_image_surface_get_data(dst);
	shape_data = cairo_image_surface_get_data(shape);

	/* Check for NULL data pointers (surface may have been finished by GC) */
	if (!src_data || !dst_data || !shape_data) {
		cairo_surface_destroy(dst);
		return NULL;
	}

	src_stride = cairo_image_surface_get_stride(src);
	dst_stride = cairo_image_surface_get_stride(dst);
	shape_stride = cairo_image_surface_get_stride(shape);

	/* Copy pixels, zeroing alpha where shape bit is 0.
	 * Note: The shape surface may be at logical scale while the source
	 * surface is at physical (HiDPI) scale. We need to scale coordinates
	 * when looking up shape bits. */
	for (y = 0; y < height; y++) {
		uint32_t *src_row = (uint32_t *)(src_data + y * src_stride);
		uint32_t *dst_row = (uint32_t *)(dst_data + y * dst_stride);

		/* Map physical y to logical shape y */
		int shape_y = (shape_height > 0) ? (y * shape_height / height) : 0;

		for (x = 0; x < width; x++) {
			bool visible = true;

			/* Map physical x to logical shape x */
			int shape_x = (shape_width > 0) ? (x * shape_width / width) : 0;

			/* Check if this pixel is within shape bounds */
			if (shape_x < shape_width && shape_y < shape_height) {
				int byte_offset = (shape_y * shape_stride) + (shape_x / 8);
				int bit_offset = shape_x % 8;
				visible = (shape_data[byte_offset] >> bit_offset) & 1;
			} else {
				/* Outside shape = transparent */
				visible = false;
			}

			if (visible) {
				dst_row[x] = src_row[x];
			} else {
				/* Premultiplied alpha: fully transparent = all channels zero */
				dst_row[x] = 0;
			}
		}
	}

	cairo_surface_mark_dirty(dst);
	return dst;
}

/** Apply shape mask to a cairo surface (exported for screenshot support).
 * Returns a new cairo_surface_t with alpha zeroed where shape bit is 0.
 * Caller must destroy the returned surface.
 * Returns NULL if no shape or allocation fails.
 */
cairo_surface_t *
drawin_apply_shape_mask_for_screenshot(cairo_surface_t *src, cairo_surface_t *shape)
{
	cairo_surface_t *dst;
	unsigned char *src_data, *dst_data, *shape_data;
	int src_stride, dst_stride, shape_stride;
	int width, height, shape_width, shape_height;
	int x, y;

	if (!src || !shape)
		return NULL;

	if (cairo_surface_status(src) != CAIRO_STATUS_SUCCESS ||
	    cairo_surface_status(shape) != CAIRO_STATUS_SUCCESS)
		return NULL;

	cairo_surface_flush(src);
	cairo_surface_flush(shape);

	width = cairo_image_surface_get_width(src);
	height = cairo_image_surface_get_height(src);
	shape_width = cairo_image_surface_get_width(shape);
	shape_height = cairo_image_surface_get_height(shape);

	dst = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(dst) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(dst);
		return NULL;
	}

	src_data = cairo_image_surface_get_data(src);
	dst_data = cairo_image_surface_get_data(dst);
	shape_data = cairo_image_surface_get_data(shape);

	if (!src_data || !dst_data || !shape_data) {
		cairo_surface_destroy(dst);
		return NULL;
	}

	src_stride = cairo_image_surface_get_stride(src);
	dst_stride = cairo_image_surface_get_stride(dst);
	shape_stride = cairo_image_surface_get_stride(shape);

	/* Copy pixels, zeroing all channels where shape bit is 0.
	 * Note: Cairo uses premultiplied alpha, so when alpha=0, RGB must also be 0. */
	for (y = 0; y < height; y++) {
		uint32_t *src_row = (uint32_t *)(src_data + y * src_stride);
		uint32_t *dst_row = (uint32_t *)(dst_data + y * dst_stride);

		int shape_y = (shape_height > 0) ? (y * shape_height / height) : 0;

		for (x = 0; x < width; x++) {
			bool visible = true;

			int shape_x = (shape_width > 0) ? (x * shape_width / width) : 0;

			if (shape_x < shape_width && shape_y < shape_height) {
				int byte_offset = (shape_y * shape_stride) + (shape_x / 8);
				int bit_offset = shape_x % 8;
				visible = (shape_data[byte_offset] >> bit_offset) & 1;
			} else {
				visible = false;
			}

			if (visible) {
				dst_row[x] = src_row[x];
			} else {
				/* Premultiplied alpha: fully transparent = all zeros */
				dst_row[x] = 0;
			}
		}
	}

	cairo_surface_mark_dirty(dst);
	return dst;
}

static void
drawin_refresh_drawable(drawin_t *drawin)
{
	drawable_t *d;
	struct wlr_buffer *buffer;
	cairo_surface_t *clipped_surface = NULL;
	cairo_surface_t *masked_surface = NULL;
	cairo_surface_t *work_surface = NULL;

	if (!drawin || !drawin->scene_buffer || !drawin->drawable) {
		return;
	}

	d = drawin->drawable;

	/* Ensure we have a Cairo surface with content */
	if (!d->surface || !d->refreshed) {
		return;
	}

	work_surface = d->surface;

	/* Clear stale shape surfaces that were finished by Lua GC */
	if (drawin->shape_clip &&
	    cairo_surface_status(drawin->shape_clip) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(drawin->shape_clip);
		drawin->shape_clip = NULL;
	}
	if (drawin->shape_bounding &&
	    cairo_surface_status(drawin->shape_bounding) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(drawin->shape_bounding);
		drawin->shape_bounding = NULL;
	}

	/* Apply shape_clip first (clips the drawable content area)
	 * In AwesomeWM, shape_clip restricts what's visible within the content area */
	if (drawin->shape_clip) {
		clipped_surface = drawin_apply_shape_mask(d, drawin->shape_clip);
		if (clipped_surface)
			work_surface = clipped_surface;
	}

	/* Apply shape_bounding mask (clips the whole window including border)
	 * This is applied after shape_clip */
	if (drawin->shape_bounding) {
		/* If we already have a clipped surface, use that as the source */
		if (clipped_surface) {
			/* Create a temporary drawable struct to pass to apply_shape_mask */
			drawable_t temp_d = *d;
			temp_d.surface = clipped_surface;
			masked_surface = drawin_apply_shape_mask(&temp_d, drawin->shape_bounding);
		} else {
			masked_surface = drawin_apply_shape_mask(d, drawin->shape_bounding);
		}
		if (masked_surface)
			work_surface = masked_surface;
	}

	/* Create SHM buffer from the final surface
	 * This uses the shared buffer implementation in drawable.c */
	if (work_surface != d->surface) {
		cairo_surface_flush(work_surface);
		buffer = drawable_create_buffer_from_data(
			cairo_image_surface_get_width(work_surface),
			cairo_image_surface_get_height(work_surface),
			cairo_image_surface_get_data(work_surface),
			cairo_image_surface_get_stride(work_surface));
	} else {
		buffer = drawable_create_buffer(d);
	}

	/* Clean up temporary surfaces */
	if (clipped_surface)
		cairo_surface_destroy(clipped_surface);
	if (masked_surface)
		cairo_surface_destroy(masked_surface);

	if (!buffer) {
		return;
	}

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

	/* Drop our reference - scene buffer holds its own reference */
	wlr_buffer_drop(buffer);

	/* Enable scene node now that we have valid content.
	 * This is the Wayland equivalent of X11's map-then-draw pattern:
	 * we only show the drawin once content is ready, avoiding smearing. */
	if (drawin->visible && drawin->scene_tree) {
		wlr_scene_node_set_enabled(&drawin->scene_tree->node, true);
		/* Show shadow too */
		shadow_set_visible(&drawin->shadow, true);
	}

	/* Schedule a frame render on the output to ensure content is displayed
	 * immediately, not waiting for the next external event. This mirrors
	 * AwesomeWM's xcb_flush() which sends pending X requests immediately.
	 * In Wayland, we request the compositor to render a new frame. */
	if (drawin->screen && drawin->screen->monitor && drawin->screen->monitor->wlr_output)
		wlr_output_schedule_frame(drawin->screen->monitor->wlr_output);
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
	int i;  /* Used in border initialization loop */

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
	drawin->drawable = NULL;  /* Set after drawable creation */

	/* Initialize shape properties (NULL = no custom shape) */
	drawin->shape_bounding = NULL;
	drawin->shape_clip = NULL;
	drawin->shape_input = NULL;

	/* Initialize signal and button arrays */
	signal_array_init(&drawin->signals);
	button_array_init(&drawin->buttons);

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
		for (i = 0; i < 4; i++) {
			drawin->border[i] = wlr_scene_rect_create(drawin->scene_tree, 0, 0, default_border_color);
			drawin->border[i]->node.data = drawin;
		}
		drawin->border_need_update = true;
		drawin->border_color_parsed.initialized = false;
	}

	/* Create shadow (compositor-level, replaces picom shadows)
	 * Shadow is created initially but disabled - enabled when visible=true */
	{
		const shadow_config_t *shadow_config = shadow_get_effective_config(
			drawin->shadow_config, true);
		if (shadow_config && shadow_config->enabled) {
			shadow_create(drawin->scene_tree, &drawin->shadow, shadow_config,
				drawin->width, drawin->height);
			/* Shadow starts hidden like the rest of the drawin */
			shadow_set_visible(&drawin->shadow, false);
		}
	}

	/* Create drawable object for rendering (AwesomeWM pattern)
	 * Stack: [drawin] */
	drawable_allocator(L, (drawable_refresh_callback)drawin_refresh_drawable, drawin);
	/* Stack: [drawin, drawable] */

	/* Store drawable in drawin's uservalue table (AwesomeWM: drawin.c:430)
	 * luaA_object_ref_item stores item and returns pointer */
	drawin->drawable = luaA_object_ref_item(L, -2, -1);
	/* Stack: [drawin] */

	/* Store drawable pointer (not drawin!) and set owner (AwesomeWM pattern)
	 * MUST happen AFTER drawable is created */
	drawin->scene_buffer->node.data = drawin->drawable;
	drawin->drawable->owner_type = DRAWABLE_OWNER_DRAWIN;
	drawin->drawable->owner.drawin = drawin;

	/* Assign initial screen based on position */
	drawin_assign_screen(L, drawin, -1);

	return drawin;
}

/** Collector for drawin objects (AwesomeWM class system)
 * This is called by the garbage collector to clean up resources
 * \param w Drawin object to destroy
 */
static void
drawin_wipe(drawin_t *w)
{
	if (!w)
		return;

	/* If this drawin was hosting the systray, clean it up */
	if (globalconf.systray.parent == w) {
		if (globalconf.systray.scene_tree) {
			wlr_scene_node_destroy(&globalconf.systray.scene_tree->node);
			globalconf.systray.scene_tree = NULL;
		}
		globalconf.systray.parent = NULL;
	}

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

	/* Free shape surfaces */
	if (w->shape_bounding) {
		cairo_surface_destroy(w->shape_bounding);
		w->shape_bounding = NULL;
	}
	if (w->shape_clip) {
		cairo_surface_destroy(w->shape_clip);
		w->shape_clip = NULL;
	}
	if (w->shape_input) {
		cairo_surface_destroy(w->shape_input);
		w->shape_input = NULL;
	}

	/* Cleanup shadow cache reference.
	 * Shadow scene nodes are children of scene_tree and will be destroyed with it.
	 * We only need to release our cache reference. */
	if (w->shadow.cache) {
		shadow_cache_put(w->shadow.cache);
		w->shadow.cache = NULL;
	}
	if (w->shadow_config) {
		free(w->shadow_config);
		w->shadow_config = NULL;
	}

	/* Destroy scene graph nodes */
	if (w->scene_tree) {
		wlr_scene_node_destroy(&w->scene_tree->node);
		w->scene_tree = NULL;
		w->scene_buffer = NULL;  /* Child node destroyed with parent */
		/* Border rects are also children, destroyed with parent */
		for (int i = 0; i < 4; i++)
			w->border[i] = NULL;
	}
}

/* DISABLED: Legacy drawin allocation - replaced by drawin_allocator via class system.
 * Only used by disabled luaA_drawin_constructor below. */
#if 0
static drawin_t *
drawin_new_legacy(lua_State *L)
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
		drawin->border_need_update = true;
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

	/* Create drawable object for rendering (AwesomeWM pattern)
	 * Stack: [drawin] */
	drawable_allocator(L, (drawable_refresh_callback)drawin_refresh_drawable, drawin);
	/* Stack: [drawin, drawable] */

	/* Store drawable in drawin's uservalue table (AwesomeWM: drawin.c:430)
	 * luaA_object_ref_item stores item and returns pointer */
	drawin->drawable = luaA_object_ref_item(L, -2, -1);
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
#endif /* Disabled drawin_new_legacy */

/* NOTE: luaA_object_push, luaA_checkdrawin() and luaA_todrawin() are now
 * handled by the class system via luaA_object_push() and LUA_OBJECT_FUNCS
 * macro in drawin.h - no manual implementation needed. This matches AwesomeWM's
 * approach and ensures proper signal emission. */

/* ========================================================================
 * Drawin property getters
 * ======================================================================== */

/** Helper to push geometry as table (used by geometry method) */
static int
luaA_drawin_push_geometry(lua_State *L, drawin_t *drawin)
{
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

/** drawin.x - Get x coordinate (AwesomeWM signature: receives drawin pointer) */
static int
luaA_drawin_get_x(lua_State *L, drawin_t *drawin)
{
	lua_pushinteger(L, drawin->x);
	return 1;
}

/** drawin.y - Get y coordinate (AwesomeWM signature) */
static int
luaA_drawin_get_y(lua_State *L, drawin_t *drawin)
{
	lua_pushinteger(L, drawin->y);
	return 1;
}

/** drawin.width - Get width (AwesomeWM signature) */
static int
luaA_drawin_get_width(lua_State *L, drawin_t *drawin)
{
	lua_pushinteger(L, drawin->width);
	return 1;
}

/** drawin.height - Get height (AwesomeWM signature) */
static int
luaA_drawin_get_height(lua_State *L, drawin_t *drawin)
{
	lua_pushinteger(L, drawin->height);
	return 1;
}

/** drawin.visible - Get visibility (AwesomeWM signature) */
static int
luaA_drawin_get_visible(lua_State *L, drawin_t *drawin)
{
	lua_pushboolean(L, drawin->visible);
	return 1;
}

/** drawin.ontop - Get ontop flag (AwesomeWM signature) */
static int
luaA_drawin_get_ontop(lua_State *L, drawin_t *drawin)
{
	lua_pushboolean(L, drawin->ontop);
	return 1;
}

/** drawin.opacity - Get opacity (AwesomeWM signature) */
static int
luaA_drawin_get_opacity(lua_State *L, drawin_t *drawin)
{
	if (drawin->opacity < 0)
		lua_pushnil(L);
	else
		lua_pushnumber(L, drawin->opacity);
	return 1;
}

/** drawin.cursor - Get cursor name (AwesomeWM signature) */
static int
luaA_drawin_get_cursor(lua_State *L, drawin_t *drawin)
{
	lua_pushstring(L, drawin->cursor);
	return 1;
}

/** drawin.type - Get window type (AwesomeWM signature) */
static int
luaA_drawin_get_type(lua_State *L, drawin_t *drawin)
{
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

/** drawin.type - Set window type (AwesomeWM signature)
 * Note: In Wayland, type doesn't map to any protocol concept (no _NET_WM_WINDOW_TYPE).
 * We store the value for Lua API compatibility but don't change layer behavior based on it.
 */
static int
luaA_drawin_set_type(lua_State *L, drawin_t *drawin)
{
	window_type_t type;
	const char *type_str;

	if (lua_isnil(L, -1))
		return 0;

	type_str = luaL_checkstring(L, -1);

	if (strcmp(type_str, "desktop") == 0)
		type = WINDOW_TYPE_DESKTOP;
	else if (strcmp(type_str, "dock") == 0)
		type = WINDOW_TYPE_DOCK;
	else if (strcmp(type_str, "splash") == 0)
		type = WINDOW_TYPE_SPLASH;
	else if (strcmp(type_str, "dialog") == 0)
		type = WINDOW_TYPE_DIALOG;
	else if (strcmp(type_str, "menu") == 0)
		type = WINDOW_TYPE_MENU;
	else if (strcmp(type_str, "toolbar") == 0)
		type = WINDOW_TYPE_TOOLBAR;
	else if (strcmp(type_str, "utility") == 0)
		type = WINDOW_TYPE_UTILITY;
	else if (strcmp(type_str, "dropdown_menu") == 0)
		type = WINDOW_TYPE_DROPDOWN_MENU;
	else if (strcmp(type_str, "popup_menu") == 0)
		type = WINDOW_TYPE_POPUP_MENU;
	else if (strcmp(type_str, "tooltip") == 0)
		type = WINDOW_TYPE_TOOLTIP;
	else if (strcmp(type_str, "notification") == 0)
		type = WINDOW_TYPE_NOTIFICATION;
	else if (strcmp(type_str, "combo") == 0)
		type = WINDOW_TYPE_COMBO;
	else if (strcmp(type_str, "dnd") == 0)
		type = WINDOW_TYPE_DND;
	else if (strcmp(type_str, "normal") == 0)
		type = WINDOW_TYPE_NORMAL;
	else {
		warn("Unknown window type '%s'", type_str);
		return 0;
	}

	if (drawin->type != type) {
		drawin->type = type;
		luaA_object_emit_signal(L, -3, "property::type", 0);
	}

	return 0;
}

/** drawin.drawable - Get associated drawable object (AwesomeWM signature)
 * AwesomeWM: drawin.c:641-644 - uses luaA_object_push_item */
static int
luaA_drawin_get_drawable(lua_State *L, drawin_t *drawin)
{
	luaA_object_push_item(L, -2, drawin->drawable);
	return 1;
}

/** drawin.border_width - Get border width (AwesomeWM signature) */
static int
luaA_drawin_get_border_width(lua_State *L, drawin_t *drawin)
{
	lua_pushinteger(L, drawin->border_width);
	return 1;
}

/** drawin.border_width - Set border width (AwesomeWM signature) */
static int
luaA_drawin_set_border_width(lua_State *L, drawin_t *drawin)
{
	int old_width = drawin->border_width;
	int new_width = (int)lua_tonumber(L, -1);

	if (new_width < 0)
		new_width = 0;

	drawin->border_width = new_width;

	/* Mark for deferred border update (AwesomeWM pattern) */
	if (old_width != new_width) {
		drawin->border_need_update = true;
		luaA_object_emit_signal(L, -3, "property::border_width", 0);
	}

	return 0;
}

/** drawin.border_color - Get border color (AwesomeWM signature) */
static int
luaA_drawin_get_border_color(lua_State *L, drawin_t *drawin)
{
	if (drawin->border_color.initialized) {
		return luaA_pushcolor(L, &drawin->border_color);
	} else {
		lua_pushnil(L);
		return 1;
	}
}

/** drawin.border_color - Set border color (AwesomeWM signature) */
static int
luaA_drawin_set_border_color(lua_State *L, drawin_t *drawin)
{
	/* Parse color from Lua (can be string or table) */
	if (!luaA_tocolor(L, -1, &drawin->border_color)) {
		return luaL_error(L, "Invalid color format");
	}

	/* Copy to parsed cache */
	drawin->border_color_parsed = drawin->border_color;

	/* Mark for deferred border update */
	if (drawin->border_color.initialized) {
		drawin->border_need_update = true;
	}

	/* Emit signal */
	luaA_object_emit_signal(L, -3, "property::border_color", 0);

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
			new_strut.left = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "right");
		if (!lua_isnil(L, -1))
			new_strut.right = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "top");
		if (!lua_isnil(L, -1))
			new_strut.top = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "bottom");
		if (!lua_isnil(L, -1))
			new_strut.bottom = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

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
				screen_update_workarea(drawin->screen);
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

/** Move and resize drawin (AwesomeWM pattern - takes stack index)
 * \param L The Lua VM state.
 * \param udx The drawin stack index.
 * \param x The new x coordinate.
 * \param y The new y coordinate.
 * \param width The new width.
 * \param height The new height.
 */
static void
drawin_moveresize(lua_State *L, int udx, int x, int y, int width, int height)
{
	drawin_t *drawin = luaA_checkudata(L, udx, &drawin_class);
	int old_x = drawin->x;
	int old_y = drawin->y;
	int old_width = drawin->width;
	int old_height = drawin->height;

	/* Update geometry */
	drawin->x = x;
	drawin->y = y;
	if (width > 0)
		drawin->width = width;
	if (height > 0)
		drawin->height = height;
	drawin->geometry_dirty = true;

	/* Propagate geometry to drawable (this creates the Cairo surface) */
	if (drawin->drawable) {
		drawable_t *d = drawin->drawable;
		int old_dwidth = d->geometry.width;
		int old_dheight = d->geometry.height;

		d->geometry.x = drawin->x;
		d->geometry.y = drawin->y;
		d->geometry.width = drawin->width;
		d->geometry.height = drawin->height;

		/* If size changed, recreate surface */
		if (old_dwidth != drawin->width || old_dheight != drawin->height) {
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
			if (drawin->width > 0 && drawin->height > 0) {
				/* Get scale for HiDPI support - use actual output scale.
				 * Use floorf to match what Cairo will actually draw with device_scale. */
				float scale = 1.0f;
				if (drawin->screen && drawin->screen->monitor &&
				    drawin->screen->monitor->wlr_output) {
					scale = drawin->screen->monitor->wlr_output->scale;
				}
				int scaled_width = (int)floorf(drawin->width * scale);
				int scaled_height = (int)floorf(drawin->height * scale);
				if (scaled_width < 1) scaled_width = 1;
				if (scaled_height < 1) scaled_height = 1;

				d->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, scaled_width, scaled_height);
				if (cairo_surface_status(d->surface) != CAIRO_STATUS_SUCCESS) {
					cairo_surface_destroy(d->surface);
					d->surface = NULL;
				} else {
					/* Set device scale so Cairo draws in logical coordinates */
					cairo_surface_set_device_scale(d->surface, scale, scale);
					d->surface_scale = scale;

					/* Emit property::surface signal on drawable
					 * AwesomeWM pattern: push from drawin's uservalue table */
					luaA_object_push_item(L, udx, drawin->drawable);
					luaA_object_emit_signal(L, -1, "property::surface", 0);
					lua_pop(L, 1);
				}
				/* Note: Don't call refresh_callback here!
				 * AwesomeWM pattern: Lua draws on surface, then calls drawable:refresh()
				 * which triggers refresh_callback. Calling it here would copy an empty surface. */
			}
		}
	}

	/* Emit property signals using passed stack index (like AwesomeWM) */
	if (old_x != drawin->x || old_y != drawin->y || old_width != drawin->width || old_height != drawin->height)
		luaA_object_emit_signal(L, udx, "property::geometry", 0);
	if (old_x != drawin->x)
		luaA_object_emit_signal(L, udx, "property::x", 0);
	if (old_y != drawin->y)
		luaA_object_emit_signal(L, udx, "property::y", 0);
	if (old_width != drawin->width)
		luaA_object_emit_signal(L, udx, "property::width", 0);
	if (old_height != drawin->height)
		luaA_object_emit_signal(L, udx, "property::height", 0);

	/* Update screen assignment if position changed */
	if (old_x != drawin->x || old_y != drawin->y)
		drawin_assign_screen(L, drawin, udx);

	/* Update workarea if struts are set and drawin is visible */
	if (drawin->visible && drawin->screen &&
	    (drawin->strut.left || drawin->strut.right || drawin->strut.top || drawin->strut.bottom)) {
		screen_update_workarea(drawin->screen);
	}

	/* Update scene graph node position if position changed */
	if (drawin->scene_tree && (old_x != drawin->x || old_y != drawin->y))
		wlr_scene_node_set_position(&drawin->scene_tree->node, drawin->x, drawin->y);

	/* Update scene buffer destination size if size changed */
	if (drawin->scene_buffer && (old_width != drawin->width || old_height != drawin->height))
		wlr_scene_buffer_set_dest_size(drawin->scene_buffer, drawin->width, drawin->height);
}

/** Set drawin geometry (wrapper for external callers)
 * This is called when the object IS in the registry (not during construction).
 */
void
luaA_drawin_set_geometry(lua_State *L, drawin_t *drawin, int x, int y, int width, int height)
{
	/* Push drawin to stack, then call drawin_moveresize with stack index */
	luaA_object_push(L, drawin);
	drawin_moveresize(L, -1, x, y, width, height);
	lua_pop(L, 1);
}

/** Set drawin visibility (AwesomeWM pattern - takes stack index)
 * \param L The Lua VM state.
 * \param udx The drawin stack index.
 * \param v The visible value.
 */
static void
drawin_set_visible(lua_State *L, int udx, bool v)
{
	drawin_t *drawin = luaA_checkudata(L, udx, &drawin_class);
	if (drawin->visible == v)
		return;  /* No change */

	drawin->visible = v;

	/* Update globalconf.drawins array to track visible drawins
	 * This matches AwesomeWM's drawin_map/unmap pattern (drawin.c:385-402) */
	if (v) {
		/* Add to visible drawins array if not already present */
		bool already_in_array = false;
		foreach(item, globalconf.drawins) {
			if (*item == drawin) {
				already_in_array = true;
				break;
			}
		}
		if (!already_in_array)
			drawin_array_append(&globalconf.drawins, drawin);

		/* Register drawin in object registry so luaA_object_push() can find it
		 * (AwesomeWM drawin.c:389-391) */
		lua_pushvalue(L, udx);
		luaA_object_ref_class(L, -1, &drawin_class);

		/* Trigger restacking - AwesomeWM calls stack_windows() when mapping drawin */
		stack_windows();

		/* Ensure drawable has surface before signal (AwesomeWM drawin.c:343-344)
		 * This is critical: Lua's do_redraw() needs a surface to draw to.
		 * Without this, the refresh callback never fires and popups don't show.
		 *
		 * Also check if scale has changed since surface was created. This handles
		 * on-demand popups (launcher, menubar, hotkeys_popup) that weren't visible
		 * when scale changed - they need surface recreation when shown. */
		if (drawin->drawable) {
			drawable_t *d = drawin->drawable;
			float current_scale = 1.0f;
			if (drawin->screen && drawin->screen->monitor &&
			    drawin->screen->monitor->wlr_output) {
				current_scale = drawin->screen->monitor->wlr_output->scale;
			}

			/* Recreate surface if: no surface, scale unknown (0), or scale changed */
			bool need_recreate = !d->surface ||
			                     d->surface_scale == 0 ||
			                     d->surface_scale != current_scale;
			if (need_recreate) {
				drawin_update_drawing(L, udx);
			}
		}
	} else {
		/* Unregister from object registry (AwesomeWM drawin.c:402) */
		luaA_object_unref(L, drawin);

		/* Remove from visible drawins array */
		foreach(item, globalconf.drawins) {
			if (*item == drawin) {
				drawin_array_remove(&globalconf.drawins, item);
				break;
			}
		}
	}

	/* Emit signal using the passed stack index (matches AwesomeWM exactly) */
	luaA_object_emit_signal(L, udx, "property::visible", 0);

	/* Update workarea if struts are set */
	if (drawin->screen &&
	    (drawin->strut.left || drawin->strut.right || drawin->strut.top || drawin->strut.bottom)) {
		screen_update_workarea(drawin->screen);
	}

	/* Scene node visibility - differs from AwesomeWM's X11 approach:
	 * In X11, xcb_map_window() maps immediately and content shows when ready.
	 * In Wayland, we MUST have content before showing, otherwise we get smearing.
	 *
	 * When becoming visible: don't enable scene node yet. Let drawin_refresh_drawable()
	 * enable it when content is actually ready.
	 * When becoming invisible: disable scene node immediately. */
	if (drawin->scene_tree) {
		if (!v) {
			/* Hiding: disable immediately */
			wlr_scene_node_set_enabled(&drawin->scene_tree->node, false);
		} else {
			/* Showing: if content is already ready, refresh and enable.
			 * Otherwise, wait for Lua's drawable:refresh() callback to enable. */
			if (drawin->drawable) {
				drawable_t *d = drawin->drawable;
				if (d->surface && d->refreshed) {
					drawin_refresh_drawable(drawin);
					/* drawin_refresh_drawable will enable the node */
				}
			}
		}
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
		screen_update_workarea(drawin->screen);
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
	}

	/* Update shadow geometry */
	if (d->shadow.tree) {
		const shadow_config_t *shadow_config = shadow_get_effective_config(
			d->shadow_config, true);
		shadow_update_geometry(&d->shadow, shadow_config,
			d->width, d->height);
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
	foreach(item, globalconf.drawins)
	{
		drawin_t *d = *item;

		/* Apply pending geometry changes
		 * In AwesomeWM this does xcb_configure_window
		 * In Wayland, geometry already applied via wlr_scene_node_set_position
		 * in luaA_drawin_set_geometry(), so just clear the flag */
		if (d->geometry_dirty) {
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
luaA_drawin_geometry(lua_State *L)
{
	drawin_t *drawin = luaA_checkdrawin(L, 1);

	/* If table argument provided, set geometry */
	if (lua_gettop(L) >= 2 && lua_istable(L, 2)) {
		int x = drawin->x, y = drawin->y;
		int width = drawin->width, height = drawin->height;

		lua_getfield(L, 2, "x");
		if (!lua_isnil(L, -1))
			x = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "y");
		if (!lua_isnil(L, -1))
			y = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "width");
		if (!lua_isnil(L, -1))
			width = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "height");
		if (!lua_isnil(L, -1))
			height = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		drawin_moveresize(L, 1, x, y, width, height);

		return 0;
	}

	/* Return current geometry */
	return luaA_drawin_push_geometry(L, drawin);
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

		/* Note: drawable is stored in drawin's uservalue table via luaA_object_ref_item,
		 * so it will be garbage collected when the drawin is collected. No explicit unref needed. */
		drawin->drawable = NULL;

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

/* ========================================================================
 * Property setters (AwesomeWM signature: lua_State *L, drawin_t *drawin)
 * Value is at -1, object is at -3 for signal emission
 * ======================================================================== */

/** Set the drawin visibility (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_visible(lua_State *L, drawin_t *drawin)
{
	drawin_set_visible(L, -3, luaA_checkboolean(L, -1));
	return 0;
}

/** Set the drawin on top status (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_ontop(lua_State *L, drawin_t *drawin)
{
	bool b = luaA_checkboolean(L, -1);
	if(b != drawin->ontop)
	{
		drawin->ontop = b;
		stack_windows();
		luaA_object_emit_signal(L, -3, "property::ontop", 0);
	}
	return 0;
}

/** Set the drawin cursor (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_cursor(lua_State *L, drawin_t *drawin)
{
	const char *buf = luaL_checkstring(L, -1);
	if(buf)
	{
		/* In Wayland, cursor is applied when pointer enters drawin (motionnotify).
		 * We can't validate cursor names like X11's xcursor_new() does. */
		p_delete(&drawin->cursor);
		drawin->cursor = a_strdup(buf);
		luaA_object_emit_signal(L, -3, "property::cursor", 0);
	}
	return 0;
}

/** Set the drawin x (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_x(lua_State *L, drawin_t *drawin)
{
	int x = (int)lua_tonumber(L, -1);
	drawin_moveresize(L, -3, x, drawin->y, drawin->width, drawin->height);
	return 0;
}

/** Set the drawin y (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_y(lua_State *L, drawin_t *drawin)
{
	int y = (int)lua_tonumber(L, -1);
	drawin_moveresize(L, -3, drawin->x, y, drawin->width, drawin->height);
	return 0;
}

/** Set the drawin width (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_width(lua_State *L, drawin_t *drawin)
{
	int width = (int)ceil(lua_tonumber(L, -1));
	if (width < 1) width = 1;
	drawin_moveresize(L, -3, drawin->x, drawin->y, width, drawin->height);
	return 0;
}

/** Set the drawin height (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_height(lua_State *L, drawin_t *drawin)
{
	int height = (int)ceil(lua_tonumber(L, -1));
	if (height < 1) height = 1;
	drawin_moveresize(L, -3, drawin->x, drawin->y, drawin->width, height);
	return 0;
}

/** Set the drawin opacity (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_opacity(lua_State *L, drawin_t *drawin)
{
	double opacity;

	if(lua_isnil(L, -1))
		opacity = -1;
	else
	{
		opacity = lua_tonumber(L, -1);
		if(opacity < 0 || opacity > 1)
			return 0;  /* Invalid value, ignore (matches AwesomeWM) */
	}

	if(drawin->opacity != opacity)
	{
		drawin->opacity = opacity;
		/* Wayland: apply opacity via scene buffer */
		if (drawin->scene_buffer)
			wlr_scene_buffer_set_opacity(drawin->scene_buffer,
				opacity >= 0 ? (float)opacity : 1.0f);
		luaA_object_emit_signal(L, -3, "property::opacity", 0);
	}
	return 0;
}

/** drawin.shadow - Get shadow configuration */
static int
luaA_drawin_get_shadow(lua_State *L, drawin_t *drawin)
{
	if (drawin->shadow_config) {
		shadow_config_to_lua(L, drawin->shadow_config);
	} else {
		/* Return true to indicate using defaults */
		lua_pushboolean(L, drawin->shadow.tree != NULL);
	}
	return 1;
}

/** drawin.shadow - Set shadow configuration */
static int
luaA_drawin_set_shadow(lua_State *L, drawin_t *drawin)
{
	shadow_config_t new_config;

	if (!shadow_config_from_lua(L, -1, &new_config)) {
		return luaL_error(L, "%s", lua_tostring(L, -1));
	}

	/* Allocate or update config */
	if (!drawin->shadow_config) {
		drawin->shadow_config = malloc(sizeof(shadow_config_t));
		if (!drawin->shadow_config)
			return luaL_error(L, "out of memory");
	}
	*drawin->shadow_config = new_config;

	/* Update shadow if scene tree exists */
	if (drawin->scene_tree) {
		if (new_config.enabled && !drawin->shadow.tree) {
			/* Create shadow */
			shadow_create(drawin->scene_tree, &drawin->shadow, &new_config,
				drawin->width, drawin->height);
			/* Match drawin visibility */
			shadow_set_visible(&drawin->shadow, drawin->visible);
		} else if (!new_config.enabled && drawin->shadow.tree) {
			/* Destroy shadow */
			shadow_destroy(&drawin->shadow);
		} else if (drawin->shadow.tree) {
			/* Update existing shadow */
			shadow_update_config(&drawin->shadow, &new_config,
				drawin->width, drawin->height);
		}
	}

	luaA_object_emit_signal(L, -3, "property::shadow", 0);
	return 0;
}

/* Forward declaration for refresh */
static void drawin_refresh_drawable(drawin_t *drawin);

/** drawin.shape_bounding - Get visual bounding shape (AwesomeWM signature) */
static int
luaA_drawin_get_shape_bounding(lua_State *L, drawin_t *drawin)
{
	if (!drawin->shape_bounding)
		return 0;
	/* lua has to make sure to free the ref or we have a leak */
	lua_pushlightuserdata(L, drawin->shape_bounding);
	return 1;
}

/** Deep copy a cairo surface to avoid lifetime issues with Lua GC.
 * When Lua GC calls cairo_surface_finish(), it frees the backing data
 * even if we hold a reference. Making a copy ensures we own the data.
 */
static cairo_surface_t *
drawin_copy_surface(cairo_surface_t *src)
{
	cairo_surface_t *dst;
	cairo_t *cr;
	int width, height;

	if (!src)
		return NULL;

	/* Check if source is still valid */
	if (cairo_surface_status(src) != CAIRO_STATUS_SUCCESS)
		return NULL;

	width = cairo_image_surface_get_width(src);
	height = cairo_image_surface_get_height(src);

	if (width <= 0 || height <= 0)
		return NULL;

	/* Create new surface with same format and dimensions */
	dst = cairo_image_surface_create(
		cairo_image_surface_get_format(src), width, height);

	if (cairo_surface_status(dst) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(dst);
		return NULL;
	}

	/* Copy the content */
	cr = cairo_create(dst);
	cairo_set_source_surface(cr, src, 0, 0);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);

	return dst;
}

/** Set the drawin's bounding shape (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_shape_bounding(lua_State *L, drawin_t *drawin)
{
	cairo_surface_t *surf = NULL;
	cairo_surface_t *copy = NULL;

	if(!lua_isnil(L, -1))
		surf = (cairo_surface_t *)lua_touserdata(L, -1);

	/* The drawin might have been resized. Apply pending geometry first.
	 * (Matches AwesomeWM's drawin_apply_moveresize() call) */
	luaA_drawin_apply_geometry(drawin);

	/* Make a deep copy of the surface to avoid Lua GC freeing it.
	 * cairo_surface_finish() frees backing data even with refs held. */
	if (surf)
		copy = drawin_copy_surface(surf);

	if (drawin->shape_bounding)
		cairo_surface_destroy(drawin->shape_bounding);

	drawin->shape_bounding = copy;

	/* Trigger redraw to apply shape (Wayland equivalent of xwindow_set_shape) */
	if (drawin->visible)
		drawin_refresh_drawable(drawin);

	luaA_object_emit_signal(L, -3, "property::shape_bounding", 0);
	return 0;
}

/** drawin.shape_clip - Get drawing clip shape (AwesomeWM signature) */
static int
luaA_drawin_get_shape_clip(lua_State *L, drawin_t *drawin)
{
	if (!drawin->shape_clip)
		return 0;
	/* lua has to make sure to free the ref or we have a leak */
	lua_pushlightuserdata(L, drawin->shape_clip);
	return 1;
}

/** Set the drawin's clip shape (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_shape_clip(lua_State *L, drawin_t *drawin)
{
	cairo_surface_t *surf = NULL;
	cairo_surface_t *copy = NULL;

	if(!lua_isnil(L, -1))
		surf = (cairo_surface_t *)lua_touserdata(L, -1);

	/* The drawin might have been resized. Apply pending geometry first.
	 * (Matches AwesomeWM's drawin_apply_moveresize() call) */
	luaA_drawin_apply_geometry(drawin);

	/* Make a deep copy of the surface to avoid Lua GC freeing it.
	 * cairo_surface_finish() frees backing data even with refs held. */
	if (surf)
		copy = drawin_copy_surface(surf);

	if (drawin->shape_clip)
		cairo_surface_destroy(drawin->shape_clip);

	drawin->shape_clip = copy;

	/* Trigger redraw to apply shape (Wayland equivalent of xwindow_set_shape) */
	if (drawin->visible)
		drawin_refresh_drawable(drawin);

	luaA_object_emit_signal(L, -3, "property::shape_clip", 0);
	return 0;
}

/** drawin.shape_input - Get input hit-test shape (AwesomeWM signature) */
static int
luaA_drawin_get_shape_input(lua_State *L, drawin_t *drawin)
{
	if (!drawin->shape_input)
		return 0;
	/* lua has to make sure to free the ref or we have a leak */
	lua_pushlightuserdata(L, drawin->shape_input);
	return 1;
}

/** Set the drawin's input shape (AwesomeWM signature).
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_shape_input(lua_State *L, drawin_t *drawin)
{
	cairo_surface_t *surf = NULL;
	if(!lua_isnil(L, -1))
		surf = (cairo_surface_t *)lua_touserdata(L, -1);

	/* The drawin might have been resized. Apply pending geometry first.
	 * (Matches AwesomeWM's drawin_apply_moveresize() call) */
	luaA_drawin_apply_geometry(drawin);

	/* Reference new surface before releasing old */
	if (surf)
		cairo_surface_reference(surf);
	if (drawin->shape_input)
		cairo_surface_destroy(drawin->shape_input);

	drawin->shape_input = surf;

	/* Note: No redraw needed for input shape - it's checked at input time.
	 * A 0x0 surface means pass through ALL input (AwesomeWM convention). */

	luaA_object_emit_signal(L, -3, "property::shape_input", 0);
	return 0;
}

/** Get all drawins into a table.
 * @treturn table A table with drawins.
 * @staticfct get
 */
static int
luaA_drawin_get(lua_State *L)
{
	int i = 1;

	lua_newtable(L);

	foreach(d, globalconf.drawins) {
		luaA_object_push(L, *d);
		lua_rawseti(L, -2, i++);
	}

	return 1;
}

/** Create a new drawin.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_new(lua_State *L)
{
	luaA_class_new(L, &drawin_class);

	return 1;
}

/* Drawin class methods - added to the drawin CLASS table (not instances)
 * LUA_CLASS_METHODS adds: set_index_miss_handler, set_newindex_miss_handler,
 * connect_signal, disconnect_signal, emit_signal, instances, set_fallback */
static const luaL_Reg drawin_methods[] = {
	LUA_CLASS_METHODS(drawin)
	{ "get", luaA_drawin_get },
	{ "__call", luaA_drawin_new },
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
	{ "geometry", luaA_drawin_geometry },
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
drawin_class_setup(lua_State *L)
{
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

	/* Register drawin properties (AwesomeWM pattern with casts) */
	luaA_class_add_property(&drawin_class, "drawable",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_drawin_get_drawable,
	                        NULL);
	luaA_class_add_property(&drawin_class, "visible",
	                        (lua_class_propfunc_t) luaA_drawin_set_visible,
	                        (lua_class_propfunc_t) luaA_drawin_get_visible,
	                        (lua_class_propfunc_t) luaA_drawin_set_visible);
	luaA_class_add_property(&drawin_class, "ontop",
	                        (lua_class_propfunc_t) luaA_drawin_set_ontop,
	                        (lua_class_propfunc_t) luaA_drawin_get_ontop,
	                        (lua_class_propfunc_t) luaA_drawin_set_ontop);
	luaA_class_add_property(&drawin_class, "cursor",
	                        (lua_class_propfunc_t) luaA_drawin_set_cursor,
	                        (lua_class_propfunc_t) luaA_drawin_get_cursor,
	                        (lua_class_propfunc_t) luaA_drawin_set_cursor);
	luaA_class_add_property(&drawin_class, "x",
	                        (lua_class_propfunc_t) luaA_drawin_set_x,
	                        (lua_class_propfunc_t) luaA_drawin_get_x,
	                        (lua_class_propfunc_t) luaA_drawin_set_x);
	luaA_class_add_property(&drawin_class, "y",
	                        (lua_class_propfunc_t) luaA_drawin_set_y,
	                        (lua_class_propfunc_t) luaA_drawin_get_y,
	                        (lua_class_propfunc_t) luaA_drawin_set_y);
	luaA_class_add_property(&drawin_class, "width",
	                        (lua_class_propfunc_t) luaA_drawin_set_width,
	                        (lua_class_propfunc_t) luaA_drawin_get_width,
	                        (lua_class_propfunc_t) luaA_drawin_set_width);
	luaA_class_add_property(&drawin_class, "height",
	                        (lua_class_propfunc_t) luaA_drawin_set_height,
	                        (lua_class_propfunc_t) luaA_drawin_get_height,
	                        (lua_class_propfunc_t) luaA_drawin_set_height);
	luaA_class_add_property(&drawin_class, "type",
	                        (lua_class_propfunc_t) luaA_drawin_set_type,
	                        (lua_class_propfunc_t) luaA_drawin_get_type,
	                        (lua_class_propfunc_t) luaA_drawin_set_type);
	luaA_class_add_property(&drawin_class, "_opacity",
	                        (lua_class_propfunc_t) luaA_drawin_set_opacity,
	                        (lua_class_propfunc_t) luaA_drawin_get_opacity,
	                        (lua_class_propfunc_t) luaA_drawin_set_opacity);
	luaA_class_add_property(&drawin_class, "shadow",
	                        (lua_class_propfunc_t) luaA_drawin_set_shadow,
	                        (lua_class_propfunc_t) luaA_drawin_get_shadow,
	                        (lua_class_propfunc_t) luaA_drawin_set_shadow);
	/* NOTE: buttons is NOT registered as a property, only as a _buttons method.
	 * The wibox wrapper handles the buttons accessor via _legacy_accessors */
	luaA_class_add_property(&drawin_class, "border_width",
	                        (lua_class_propfunc_t) luaA_drawin_set_border_width,
	                        (lua_class_propfunc_t) luaA_drawin_get_border_width,
	                        (lua_class_propfunc_t) luaA_drawin_set_border_width);
	/* AwesomeWM pattern: _border_width alias used by placement.lua */
	luaA_class_add_property(&drawin_class, "_border_width",
	                        (lua_class_propfunc_t) luaA_drawin_set_border_width,
	                        (lua_class_propfunc_t) luaA_drawin_get_border_width,
	                        (lua_class_propfunc_t) luaA_drawin_set_border_width);
	luaA_class_add_property(&drawin_class, "border_color",
	                        (lua_class_propfunc_t) luaA_drawin_set_border_color,
	                        (lua_class_propfunc_t) luaA_drawin_get_border_color,
	                        (lua_class_propfunc_t) luaA_drawin_set_border_color);
	luaA_class_add_property(&drawin_class, "shape_bounding",
	                        (lua_class_propfunc_t) luaA_drawin_set_shape_bounding,
	                        (lua_class_propfunc_t) luaA_drawin_get_shape_bounding,
	                        (lua_class_propfunc_t) luaA_drawin_set_shape_bounding);
	luaA_class_add_property(&drawin_class, "shape_clip",
	                        (lua_class_propfunc_t) luaA_drawin_set_shape_clip,
	                        (lua_class_propfunc_t) luaA_drawin_get_shape_clip,
	                        (lua_class_propfunc_t) luaA_drawin_set_shape_clip);
	luaA_class_add_property(&drawin_class, "shape_input",
	                        (lua_class_propfunc_t) luaA_drawin_set_shape_input,
	                        (lua_class_propfunc_t) luaA_drawin_get_shape_input,
	                        (lua_class_propfunc_t) luaA_drawin_set_shape_input);
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
	drawin = drawin_new_legacy(L);
	if (!drawin)
		return 0;

	/* If args table provided, set properties
	 * Stack before drawin_new_legacy: [args_table]
	 * Stack after drawin_new_legacy: [args_table, drawin]
	 * So args is at index 1, drawin is at index 2
	 */
	if (lua_gettop(L) >= 2 && lua_istable(L, 1)) {
		/* Apply properties from args table at index 1 */
		lua_getfield(L, 1, "x");
		if (!lua_isnil(L, -1))
			drawin->x = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "y");
		if (!lua_isnil(L, -1))
			drawin->y = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "width");
		if (!lua_isnil(L, -1))
			drawin->width = (int)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 1, "height");
		if (!lua_isnil(L, -1))
			drawin->height = (int)lua_tonumber(L, -1);
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
			drawin->opacity = lua_tonumber(L, -1);
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

	/* Drawin object is already on stack from drawin_new_legacy() */
	return 1;
}
#endif /* Disabled luaA_drawin_constructor - using class system instead */

/** Setup drawin module - register class and add to capi
 * This is called during luaA_init() to expose drawin API to Lua
 */
void
luaA_drawin_setup(lua_State *L)
{
	/* Setup class using luaA_class_setup()
	 * This automatically:
	 * - Creates a CLASS TABLE as global 'drawin'
	 * - Adds class methods (set_index_miss_handler, etc.)
	 * - Makes it callable via __call metamethod (constructor)
	 * - Sets up signal infrastructure
	 */
	drawin_class_setup(L);

	/* Get or create capi table */
	lua_getglobal(L, "capi");
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setglobal(L, "capi");
	}

	/* Get the drawin class (already registered as global by luaA_class_setup) */
	lua_getglobal(L, "drawin");

	/* Set capi.drawin = drawin class table */
	lua_setfield(L, -2, "drawin");

	lua_pop(L, 1);  /* Pop capi table */
}
