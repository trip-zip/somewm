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
#include "../declare.h"
#include "../widget.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <wlr/types/wlr_output.h>

/* AwesomeWM class system - drawin class */
lua_class_t drawin_class;

/* NOTE: LUA_OBJECT_FUNCS is now in drawin.h, not here */

/* Forward declarations for signal array helpers (shared with screen.c) */
extern void signal_array_init(signal_array_t *arr);
extern void signal_array_wipe(signal_array_t *arr);

/* Forward declarations for workarea updates */
extern void screen_update_workarea(screen_t *screen);


/** Get the effective scale for drawin masks and borders.
 * Returns scale_override if set (>0), otherwise the output scale.
 * Used by mask, border and explicit scale queries.
 */
static float
drawin_get_effective_scale(drawin_t *d)
{
	if (d->scale_override > 0.0f)
		return d->scale_override;
	if (d->screen && d->screen->monitor && d->screen->monitor->wlr_output)
		return d->screen->monitor->wlr_output->scale;
	return 1.0f;
}

/**
 * Render border as a Cairo surface.
 * If shape_border is set (pre-rendered anti-aliased border from Lua), use it.
 * Otherwise, render a simple rectangular border.
 * Returns an ARGB32 surface that caller must destroy.
 * Returns NULL if border_width is 0 or allocation fails.
 */
static cairo_surface_t *
drawin_render_border(drawin_t *d)
{
	int bw = d->border_width;
	if (bw <= 0)
		return NULL;

	/* If we have a pre-rendered anti-aliased border from Lua, use it.
	 * This provides smooth edges via Cairo's vector stroke rendering. */
	if (d->shape_border &&
		cairo_surface_status(d->shape_border) == CAIRO_STATUS_SUCCESS) {
		/* Return a copy since caller expects to destroy it */
		int w = cairo_image_surface_get_width(d->shape_border);
		int h = cairo_image_surface_get_height(d->shape_border);
		cairo_surface_t *copy = cairo_image_surface_create(
			CAIRO_FORMAT_ARGB32, w, h);
		if (cairo_surface_status(copy) != CAIRO_STATUS_SUCCESS) {
			cairo_surface_destroy(copy);
			return NULL;
		}
		cairo_t *cr = cairo_create(copy);
		cairo_set_source_surface(cr, d->shape_border, 0, 0);
		cairo_paint(cr);
		cairo_destroy(cr);
		return copy;
	}

	/* Fallback: render simple rectangular border (no shape) */
	int total_w = d->width + 2 * bw;
	int total_h = d->height + 2 * bw;

	cairo_surface_t *surface = cairo_image_surface_create(
		CAIRO_FORMAT_ARGB32, total_w, total_h);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surface);
		return NULL;
	}

	cairo_t *cr = cairo_create(surface);

	/* Draw rectangular border ring using even-odd fill rule */
	color_t *bc = &d->border_color_parsed;
	cairo_set_source_rgba(cr,
		bc->red / 255.0, bc->green / 255.0,
		bc->blue / 255.0, bc->alpha / 255.0);

	/* Outer rectangle */
	cairo_rectangle(cr, 0, 0, total_w, total_h);
	/* Inner cutout */
	cairo_rectangle(cr, bw, bw, d->width, d->height);
	cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
	cairo_fill(cr);

	cairo_destroy(cr);
	return surface;
}

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

/** Refresh callback for drawable - called when drawable content should be displayed
 * This updates the scene graph buffer with new Cairo-rendered content
 */

/* Read one pixel from a CAIRO_FORMAT_A1 surface row. Cairo packs A1
 * into native-endian 32-bit words; on little-endian the leftmost
 * pixel is bit (x & 31) of word (x >> 5). Caller ensures bounds. */
static inline int
shape_a1_get(const unsigned char *data, int stride, int x, int y)
{
	const uint32_t *row = (const uint32_t *)(data + y * stride);
	uint32_t word = row[x >> 5];
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
	return (word >> (31 - (x & 31))) & 1u;
#else
	return (word >> (x & 31)) & 1u;
#endif
}

void
drawin_mark_dirty(drawin_t *drawin)
{
	if (drawin->screen && drawin->screen->monitor
			&& drawin->screen->monitor->declare)
		declare_output_mark_dirty(drawin->screen->monitor->declare);
}

bool
drawin_widget_host(drawin_t *d, struct widget_host *out)
{
	if (!d->screen || !d->screen->monitor)
		return false;
	Monitor *m = d->screen->monitor;

	*out = (struct widget_host) {
		.tree = &d->widgets,
		.m = m,
		.drawable = d->drawable,
		.id = (uint32_t)declare_handle_for(d, DECLARE_KIND_DRAWIN),
		.x = d->x - m->m.x, .y = d->y - m->m.y,
		.w = d->width, .h = d->height,
		.radius = d->shape_radius,
	};
	return true;
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
	drawin->shape_radius = -1;
	drawin->shape_border = NULL;

	/* Initialize signal and button arrays */
	signal_array_init(&drawin->signals);
	button_array_init(&drawin->buttons);

	/* No scene nodes: the renderer draws a drawin from its image entries
	 * (shadow, border, content), which the declare pass hands out. */
	drawin->border_need_update = true;
	drawin->border_color_parsed.initialized = false;

	/* Create drawable object for rendering (AwesomeWM pattern)
	 * Stack: [drawin] */
	drawable_allocator(L);
	/* Stack: [drawin, drawable] */

	/* Store drawable in drawin's uservalue table (AwesomeWM: drawin.c:430)
	 * luaA_object_ref_item stores item and returns pointer */
	drawin->drawable = luaA_object_ref_item(L, -2, -1);
	/* Stack: [drawin] */

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

	/* Clear any lock surface/cover pointers referencing this drawin (EDGE-2) */
	some_notify_drawin_destroyed(w);

	/* Retire the renderer's view: the handle so a later resolve answers
	 * NULL, and the entry surfaces the declare pass hands out. */
	declare_handle_drop(w);
	widget_nodes_clear(&w->widgets);

	image_entry_set(&w->border_entry, NULL);
	shadow_leaves_clear(&w->shadow);

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
	if (w->shape_border) {
		cairo_surface_destroy(w->shape_border);
		w->shape_border = NULL;
	}

	if (w->shadow_config) {
		free(w->shadow_config);
		w->shadow_config = NULL;
	}
}

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

/** drawin.surface_scale - Get surface scale override (somewm extension).
 * Returns the override value, or 0 (auto) if not set.
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_get_surface_scale(lua_State *L, drawin_t *drawin)
{
	lua_pushnumber(L, drawin->scale_override);
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

			/* We don't know the correct screen, update them all.
			 * globalconf.screens is unpopulated here; the live list is
			 * behind luaA_screen_get_all(). */
			screen_t *all[16];
			int n = countof(all);
			luaA_screen_get_all(L, all, &n);
			for (int i = 0; i < n; i++)
				screen_update_workarea(all[i]);
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

	/* Propagate geometry and emit the drawable resize trigger. */
	if (drawin->drawable) {
		drawable_t *d = drawin->drawable;
		int old_dwidth = d->geometry.width;
		int old_dheight = d->geometry.height;

		d->geometry.x = drawin->x;
		d->geometry.y = drawin->y;
		d->geometry.width = drawin->width;
		d->geometry.height = drawin->height;

		if (old_dwidth != drawin->width || old_dheight != drawin->height) {
			luaA_object_push_item(L, udx, drawin->drawable);
			luaA_object_emit_signal(L, -1, "property::surface", 0);
			lua_pop(L, 1);
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

	/* Size change requires border entry refresh */
	if (old_width != drawin->width || old_height != drawin->height)
		drawin->border_need_update = true;

	/* Any geometry change re-declares the drawin; all outputs, because a
	 * move can also change which screen it sits on. */
	if (old_x != drawin->x || old_y != drawin->y
			|| old_width != drawin->width || old_height != drawin->height)
		declare_mark_all_dirty();
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
	if (declare_in_frame())
		luaL_error(L, "drawin visibility changed from inside a frame");
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
		if (!already_in_array) {
			drawin_array_append(&globalconf.drawins, drawin);
		}

		/* Register drawin in object registry so luaA_object_push() can find it
		 * (AwesomeWM drawin.c:389-391) */
		lua_pushvalue(L, udx);
		luaA_object_ref_class(L, -1, &drawin_class);

		/* Trigger restacking - AwesomeWM calls stack_windows() when mapping drawin */
		stack_windows();

		if (drawin->drawable)
			drawin_update_drawing(L, udx);

		/* Wayland-specific: if drawin was invisible during a screen geometry
		 * change (e.g., scale change), its geometry may be stale. Auto-shrink
		 * if it starts at screen origin and extends beyond screen bounds.
		 * This handles lockscreen overlays created at init (scale=1.0) that
		 * become visible after scale changes. */
		if (drawin->screen) {
			screen_t *s = drawin->screen;
			if (drawin->x == s->geometry.x && drawin->y == s->geometry.y &&
			    (drawin->width > s->geometry.width ||
			     drawin->height > s->geometry.height)) {
				drawin_moveresize(L, udx,
					s->geometry.x, s->geometry.y,
					s->geometry.width, s->geometry.height);
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

	/* Visibility changes update the declared tree. */
	declare_mark_all_dirty();

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
		screen_update_workarea(drawin->screen);
	}
}

/** Apply pending geometry changes */
void
luaA_drawin_apply_geometry(drawin_t *drawin)
{
	drawin->geometry_dirty = false;
}

/** Refresh a single drawin's border entry.
 * Rebuilds the border image the declare pass hands the renderer. */
static void
drawin_border_refresh_single(drawin_t *d)
{
	cairo_surface_t *border_surface;

	/* Skip if no update needed */
	if (!d->border_need_update) {
		return;
	}

	d->border_need_update = false;

	/* border_surface's ownership moves to the renderer's border entry;
	 * without a border there is no entry and no leaf. */
	border_surface = d->border_width > 0 ? drawin_render_border(d) : NULL;
	image_entry_set(&d->border_entry, border_surface);

	drawin_mark_dirty(d);
}

/** Refresh all visible drawins (AwesomeWM compatibility)
 * Called from some_refresh() main loop. Geometry was already recorded by
 * drawin_moveresize() (the declare pass reads it per frame); what applies
 * here is the pending border entry rebuild.
 */
void
drawin_refresh(void)
{
	foreach(item, globalconf.drawins)
	{
		drawin_t *d = *item;

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
			x = (int)round(lua_tonumber(L, -1));
		lua_pop(L, 1);

		lua_getfield(L, 2, "y");
		if (!lua_isnil(L, -1))
			y = (int)round(lua_tonumber(L, -1));
		lua_pop(L, 1);

		lua_getfield(L, 2, "width");
		if (!lua_isnil(L, -1))
			width = (int)ceil(lua_tonumber(L, -1));
		lua_pop(L, 1);

		lua_getfield(L, 2, "height");
		if (!lua_isnil(L, -1))
			height = (int)ceil(lua_tonumber(L, -1));
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

		/* Retire the renderer's view and drop the retained leaves at the
		 * next frame */
		declare_handle_drop(drawin);
		widget_nodes_clear(&drawin->widgets);

		image_entry_set(&drawin->border_entry, NULL);
		shadow_leaves_clear(&drawin->shadow);
		declare_mark_all_dirty();
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

/** Set the drawin surface_scale override (somewm extension).
 * 0 = auto (use output scale), >0 = force this scale for drawable surface.
 * Recreates the drawable surface at the new scale.
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_surface_scale(lua_State *L, drawin_t *drawin)
{
	float scale = (float)lua_tonumber(L, -1);
	if (scale < 0.0f)
		scale = 0.0f;
	if (scale != drawin->scale_override)
	{
		drawin->scale_override = scale;
		/* Recreate the drawable surface at the new scale */
		if (drawin->visible)
			drawin_update_drawing(L, -3);
		luaA_object_emit_signal(L, -3, "property::surface_scale", 0);
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
	int x = (int)round(lua_tonumber(L, -1));
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
	int y = (int)round(lua_tonumber(L, -1));
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
		if (declare_in_frame())
			return luaL_error(L, "widget tree changed from inside a frame");
		drawin->opacity = opacity;
		/* Opacity rides the content leaf's userData word (declare.c) */
		declare_mark_all_dirty();
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
		const shadow_config_t *eff = shadow_get_effective_config(NULL, true);
		if (eff->enabled) {
			shadow_config_to_lua(L, eff);
		} else {
			lua_pushboolean(L, false);
		}
	}
	return 1;
}

/** drawin.shadow - Set shadow configuration */
static int
luaA_drawin_set_shadow(lua_State *L, drawin_t *drawin)
{
	shadow_config_t new_config;

	if (!shadow_config_from_lua(L, -1, &new_config, true)) {
		return luaL_error(L, "%s", lua_tostring(L, -1));
	}

	/* Allocate or update config */
	if (!drawin->shadow_config) {
		drawin->shadow_config = malloc(sizeof(shadow_config_t));
		if (!drawin->shadow_config)
			return luaL_error(L, "out of memory");
	}
	*drawin->shadow_config = new_config;

	declare_mark_all_dirty();

	luaA_object_emit_signal(L, -3, "property::shadow", 0);
	return 0;
}

/* The corner radius, in logical pixels, of the rounded rectangle an ARGB32
 * mask is, or -1 for a mask that is anything else. The candidate radius is
 * read off the top row (the first fully covered pixel is where the arc
 * meets the flat edge) and the mask is compared against
 * gears.shape.rounded_rect drawn the way wibox:_apply_shape draws it, the
 * same path at the same scale with the same antialiasing, so a match is
 * near exact and a candidate a fraction off is not. */
static bool
mask_matches_rounded_rect(cairo_surface_t *mask, int w, int h, float scale,
	double radius)
{
	int width = cairo_image_surface_get_width(mask);
	int height = cairo_image_surface_get_height(mask);
	cairo_surface_t *ref = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
		width, height);
	cairo_t *cr = cairo_create(ref);
	const double pi = 3.14159265358979323846;
	double r = radius;
	bool match = true;

	if (w / 2.0 < r)
		r = w / 2.0;
	if (h / 2.0 < r)
		r = h / 2.0;
	cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST);
	cairo_scale(cr, scale, scale);
	cairo_move_to(cr, 0, r);
	cairo_arc(cr, r, r, r, pi, 3 * (pi / 2));
	cairo_arc(cr, w - r, r, r, 3 * (pi / 2), pi * 2);
	cairo_arc(cr, w - r, h - r, r, pi * 2, pi / 2);
	cairo_arc(cr, r, h - r, r, pi / 2, pi);
	cairo_close_path(cr);
	cairo_set_source_rgba(cr, 1, 1, 1, 1);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_fill(cr);
	cairo_destroy(cr);
	cairo_surface_flush(ref);

	cairo_surface_flush(mask);
	const unsigned char *a = cairo_image_surface_get_data(mask);
	const unsigned char *b = cairo_image_surface_get_data(ref);
	int sa = cairo_image_surface_get_stride(mask);
	int sb = cairo_image_surface_get_stride(ref);

	for (int y = 0; match && y < height; y++) {
		const uint32_t *ra = (const uint32_t *)(a + y * sa);
		const uint32_t *rb = (const uint32_t *)(b + y * sb);

		for (int x = 0; x < width; x++) {
			int da = (int)(ra[x] >> 24) - (int)(rb[x] >> 24);

			if (da > 12 || da < -12) {
				match = false;
				break;
			}
		}
	}
	cairo_surface_destroy(ref);
	return match;
}

static float
mask_rounded_radius(cairo_surface_t *mask, int w, int h, float scale)
{
	int width, first = -1;
	const uint32_t *row;

	if (!mask || cairo_surface_status(mask) != CAIRO_STATUS_SUCCESS
			|| cairo_image_surface_get_format(mask) != CAIRO_FORMAT_ARGB32
			|| cairo_image_surface_get_height(mask) < 1)
		return -1;
	width = cairo_image_surface_get_width(mask);
	cairo_surface_flush(mask);
	row = (const uint32_t *)cairo_image_surface_get_data(mask);
	for (int x = 0; x < width; x++) {
		if ((row[x] >> 24) == 0xff) {
			first = x;
			break;
		}
	}
	if (first < 0)
		return -1;
	/* The arc meets the top edge at the radius, so the first covered
	 * pixel is at or just past it; the fractions between are tried. */
	for (double dev = first; dev >= first - 1.0 && dev >= 0; dev -= 0.25) {
		double radius = dev / scale;

		if (mask_matches_rounded_rect(mask, w, h, scale, radius))
			return (float)radius;
	}
	return -1;
}

/* Whether a mask is at the size the drawin's own dimensions give it.
 * wibox:_apply_shape sets the masks one at a time, so the first setter after
 * a resize sees the other mask at the old size. */
static bool
mask_fits(cairo_surface_t *mask, int w, int h, float scale)
{
	return cairo_image_surface_get_width(mask) == (int)ceilf(w * scale)
		&& cairo_image_surface_get_height(mask) == (int)ceilf(h * scale);
}

/* Recompute shape_radius (drawin.h) from the masks: the bounding mask a
 * rounded rectangle at the drawin's size plus its border, the clip mask the
 * same shape at the drawin's size with the border's inner edge as its
 * corner (a stroke of twice the border on a rounded rectangle of radius r
 * has an inner edge of radius r - bw, square when r <= bw), which is what
 * wibox:_apply_shape draws. The content's corner is the radius the root
 * element takes. A missing mask agrees with the one present. Masks that say
 * anything else leave -1, and one that is no rounded rectangle is named
 * once the pair is at the drawin's size; a stale mask mid-update says
 * nothing. */
static void
drawin_shape_update(drawin_t *d)
{
	float scale = drawin_get_effective_scale(d);
	int bw = d->border_width;
	float rb, rc;

	d->shape_radius = -1;
	if (!d->shape_bounding && !d->shape_clip)
		return;
	rb = d->shape_bounding
		? mask_rounded_radius(d->shape_bounding,
			d->width + 2 * bw, d->height + 2 * bw, scale) : -2;
	rc = d->shape_clip
		? mask_rounded_radius(d->shape_clip, d->width, d->height, scale)
		: rb >= 0 ? fmaxf(rb - bw, 0) : -1;
	if (rb == -2)
		rb = rc + bw;
	if (rb >= 0 && rc >= 0 && fabsf(fmaxf(rb - bw, 0) - rc) < 0.01f) {
		d->shape_radius = rc;
		return;
	}
	/* Two rounded rectangles whose radii disagree are a border change in
	 * progress; a mask that is no rounded rectangle at all is the shape. */
	if ((rb < 0 || rc < 0)
			&& (!d->shape_bounding || mask_fits(d->shape_bounding,
				d->width + 2 * bw, d->height + 2 * bw, scale))
			&& (!d->shape_clip
				|| mask_fits(d->shape_clip, d->width, d->height, scale)))
		warn("drawin: shape is not a rounded rectangle, drawing it unshaped");
}

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

	/* Create a surface with the same dimensions, including the 0x0 input flag. */
	dst = cairo_image_surface_create(
		cairo_image_surface_get_format(src), width, height);

	if (cairo_surface_status(dst) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(dst);
		return NULL;
	}

	/* Copy one source pixel to one destination pixel, compensating for
	 * any source device scale. */
	cr = cairo_create(dst);
	double sx = 1.0, sy = 1.0;
	cairo_surface_get_device_scale(src, &sx, &sy);
	if (sx > 0.0 && sy > 0.0)
		cairo_scale(cr, sx, sy);
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
	drawin_shape_update(drawin);

	/* Trigger redraw to apply shape (Wayland equivalent of xwindow_set_shape) */
	if (drawin->visible)
		drawin_mark_dirty(drawin);

	/* Trigger border refresh to apply shape to border */
	drawin->border_need_update = true;

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
	drawin_shape_update(drawin);

	/* Trigger redraw to apply shape (Wayland equivalent of xwindow_set_shape) */
	if (drawin->visible)
		drawin_mark_dirty(drawin);

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

	if (drawin->shape_input)
		cairo_surface_destroy(drawin->shape_input);

	drawin->shape_input = copy;
	if (copy && (cairo_image_surface_get_width(copy) != 0
			|| cairo_image_surface_get_height(copy) != 0))
		warn("drawin: shape_input masks are ignored, input follows the box");

	/* A 0x0 surface passes all input through; every other mask is ignored. */

	luaA_object_emit_signal(L, -3, "property::shape_input", 0);
	return 0;
}

/** drawin.shape_border - Get pre-rendered border surface */
static int
luaA_drawin_get_shape_border(lua_State *L, drawin_t *drawin)
{
	if (!drawin->shape_border)
		return 0;
	lua_pushlightuserdata(L, drawin->shape_border);
	return 1;
}

/** Set the drawin's pre-rendered border surface.
 * This is an ARGB32 surface rendered in Lua with anti-aliased edges.
 * \param L The Lua VM state.
 * \param drawin The drawin object.
 * \return The number of elements pushed on stack.
 */
static int
luaA_drawin_set_shape_border(lua_State *L, drawin_t *drawin)
{
	cairo_surface_t *surf = NULL;
	cairo_surface_t *copy = NULL;

	if(!lua_isnil(L, -1))
		surf = (cairo_surface_t *)lua_touserdata(L, -1);

	/* Make a deep copy of the surface to avoid Lua GC freeing it. */
	if (surf)
		copy = drawin_copy_surface(surf);

	if (drawin->shape_border)
		cairo_surface_destroy(drawin->shape_border);

	drawin->shape_border = copy;

	/* Trigger border refresh to use the new pre-rendered surface */
	drawin->border_need_update = true;

	luaA_object_emit_signal(L, -3, "property::shape_border", 0);
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
const luaL_Reg drawin_methods[] = {
	LUA_CLASS_METHODS(drawin)
	{ "get", luaA_drawin_get },
	{ "__call", luaA_drawin_new },
	{ NULL, NULL }
};

/* Drawin metatable methods - added to instance metatables
 * LUA_OBJECT_META adds instance signal methods: connect_signal, disconnect_signal, emit_signal
 * LUA_CLASS_META adds: __index, __newindex for property handling
 */
const luaL_Reg drawin_meta[] = {
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

	const lua_class_property_t properties[] = {
		{ "drawable", NULL, (lua_class_propfunc_t) luaA_drawin_get_drawable, NULL },
		{ "visible", (lua_class_propfunc_t) luaA_drawin_set_visible, (lua_class_propfunc_t) luaA_drawin_get_visible, (lua_class_propfunc_t) luaA_drawin_set_visible },
		{ "ontop", (lua_class_propfunc_t) luaA_drawin_set_ontop, (lua_class_propfunc_t) luaA_drawin_get_ontop, (lua_class_propfunc_t) luaA_drawin_set_ontop },
		{ "cursor", (lua_class_propfunc_t) luaA_drawin_set_cursor, (lua_class_propfunc_t) luaA_drawin_get_cursor, (lua_class_propfunc_t) luaA_drawin_set_cursor },
		{ "x", (lua_class_propfunc_t) luaA_drawin_set_x, (lua_class_propfunc_t) luaA_drawin_get_x, (lua_class_propfunc_t) luaA_drawin_set_x },
		{ "y", (lua_class_propfunc_t) luaA_drawin_set_y, (lua_class_propfunc_t) luaA_drawin_get_y, (lua_class_propfunc_t) luaA_drawin_set_y },
		{ "width", (lua_class_propfunc_t) luaA_drawin_set_width, (lua_class_propfunc_t) luaA_drawin_get_width, (lua_class_propfunc_t) luaA_drawin_set_width },
		{ "height", (lua_class_propfunc_t) luaA_drawin_set_height, (lua_class_propfunc_t) luaA_drawin_get_height, (lua_class_propfunc_t) luaA_drawin_set_height },
		{ "type", (lua_class_propfunc_t) luaA_drawin_set_type, (lua_class_propfunc_t) luaA_drawin_get_type, (lua_class_propfunc_t) luaA_drawin_set_type },
		{ "_opacity", (lua_class_propfunc_t) luaA_drawin_set_opacity, (lua_class_propfunc_t) luaA_drawin_get_opacity, (lua_class_propfunc_t) luaA_drawin_set_opacity },
		{ "shadow", (lua_class_propfunc_t) luaA_drawin_set_shadow, (lua_class_propfunc_t) luaA_drawin_get_shadow, (lua_class_propfunc_t) luaA_drawin_set_shadow },
		{ "surface_scale", (lua_class_propfunc_t) luaA_drawin_set_surface_scale, (lua_class_propfunc_t) luaA_drawin_get_surface_scale, (lua_class_propfunc_t) luaA_drawin_set_surface_scale },
		{ "border_width", (lua_class_propfunc_t) luaA_drawin_set_border_width, (lua_class_propfunc_t) luaA_drawin_get_border_width, (lua_class_propfunc_t) luaA_drawin_set_border_width },
		{ "_border_width", (lua_class_propfunc_t) luaA_drawin_set_border_width, (lua_class_propfunc_t) luaA_drawin_get_border_width, (lua_class_propfunc_t) luaA_drawin_set_border_width },
		{ "border_color", (lua_class_propfunc_t) luaA_drawin_set_border_color, (lua_class_propfunc_t) luaA_drawin_get_border_color, (lua_class_propfunc_t) luaA_drawin_set_border_color },
		{ "_border_color", (lua_class_propfunc_t) luaA_drawin_set_border_color, (lua_class_propfunc_t) luaA_drawin_get_border_color, (lua_class_propfunc_t) luaA_drawin_set_border_color },
		{ "shape_bounding", (lua_class_propfunc_t) luaA_drawin_set_shape_bounding, (lua_class_propfunc_t) luaA_drawin_get_shape_bounding, (lua_class_propfunc_t) luaA_drawin_set_shape_bounding },
		{ "shape_clip", (lua_class_propfunc_t) luaA_drawin_set_shape_clip, (lua_class_propfunc_t) luaA_drawin_get_shape_clip, (lua_class_propfunc_t) luaA_drawin_set_shape_clip },
		{ "shape_input", (lua_class_propfunc_t) luaA_drawin_set_shape_input, (lua_class_propfunc_t) luaA_drawin_get_shape_input, (lua_class_propfunc_t) luaA_drawin_set_shape_input },
		{ "shape_border", (lua_class_propfunc_t) luaA_drawin_set_shape_border, (lua_class_propfunc_t) luaA_drawin_get_shape_border, (lua_class_propfunc_t) luaA_drawin_set_shape_border },
	};
	luaA_class_add_properties(&drawin_class, properties, countof(properties));
}

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
