#include "screen.h"
#include "client.h"
#include "drawin.h"
#include "signal.h"
#include "luaa.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "../somewm_api.h"
#include "../globalconf.h"
#include "../util.h"
#include "../x11_compat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* AwesomeWM-compatible screen class */
static lua_class_t screen_class;
LUA_OBJECT_FUNCS(screen_class, screen_t, screen)

/* External reference to selected monitor */
extern Monitor *selmon;
extern struct wl_list mons;  /* Global monitor list from somewm.c */

/* Global array of screen objects - stores Lua registry references */
static int *screen_refs = NULL;
static size_t screen_count = 0;
static size_t screen_capacity = 0;

/* Primary screen tracking */
static screen_t *primary_screen = NULL;

/* Track whether initial screen scanning is complete (for hotplug detection) */
static bool screens_scanned = false;

/* Forward declarations for signal array helpers (from signal.c) */
extern void signal_array_init(signal_array_t *arr);
extern void signal_array_wipe(signal_array_t *arr);

/* ========================================================================
 * Screen object management
 * ======================================================================== */

/** Create a new screen object
 * \param L Lua state
 * \param m Monitor pointer
 * \param index Screen index (1-based)
 * \return Pointer to new screen object
 */
screen_t *
luaA_screen_new(lua_State *L, Monitor *m, int index)
{
	screen_t *screen;
	int ref;

	/* Create screen object using AwesomeWM pattern (from screen_add) */
	screen = screen_new(L);
	lua_pushvalue(L, -1);    /* Duplicate for luaA_object_ref (will be popped) */
	luaA_object_ref(L, -1);  /* Store in object registry (pops the duplicate) */

	/* Initialize screen fields (like AwesomeWM's screen_scan_randr_monitors) */
	screen->monitor = m;
	screen->index = index;
	screen->valid = true;
	screen->lifecycle = SCREEN_LIFECYCLE_C;
	screen->name = NULL;
	some_monitor_get_geometry(m, &screen->geometry);
	screen->workarea = screen->geometry;

	/* Store reference in regular registry to prevent GC and allow retrieval */
	lua_pushvalue(L, -1);
	ref = luaL_ref(L, LUA_REGISTRYINDEX);
	fprintf(stderr, "[SCREEN_NEW] Created screen=%p index=%d ref=%d\n", (void*)screen, index, ref);

	/* Add reference to global screen array */
	if (screen_count >= screen_capacity) {
		size_t new_cap = screen_capacity == 0 ? 4 : screen_capacity * 2;
		int *new_refs = realloc(screen_refs, new_cap * sizeof(int));
		if (!new_refs) {
			fprintf(stderr, "somewm: failed to allocate screen array\n");
			luaL_unref(L, LUA_REGISTRYINDEX, ref);
			return NULL;
		}
		screen_refs = new_refs;
		screen_capacity = new_cap;
	}
	screen_refs[screen_count++] = ref;

	/* Screen userdata is still on stack for caller */
	return screen;
}

/** Push a screen object onto the Lua stack
 * \param L Lua state
 * \param screen Screen object to push
 */
void
luaA_screen_push(lua_State *L, screen_t *screen)
{
	size_t i;

	if (!screen) {
		lua_pushnil(L);
		return;
	}

	/* Find screen in global array by comparing the screen pointer */
	for (i = 0; i < screen_count; i++) {
		screen_t *s;

		/* Get screen from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[i]);
		s = (screen_t *)lua_touserdata(L, -1);

		if (s == screen) {
			/* Found it - userdata is now on stack */
			return;
		}

		/* Not this one, pop it */
		lua_pop(L, 1);
	}

	/* Screen not found - this shouldn't happen */
	fprintf(stderr, "somewm: warning: screen not found in registry\n");
	lua_pushnil(L);
}

/** Check if argument is a screen object and return it
 * \param L Lua state
 * \param idx Stack index
 * \return Screen object pointer, or NULL on error
 */
screen_t *
luaA_checkscreen(lua_State *L, int idx)
{
	/* Use AwesomeWM class system for type checking */
	return (screen_t *)luaA_checkudata(L, idx, &screen_class);
}

/** Try to convert argument to screen object
 * \param L Lua state
 * \param idx Stack index
 * \return Screen object pointer, or NULL if not a screen
 */
screen_t *
luaA_toscreen(lua_State *L, int idx)
{
	/* Use AwesomeWM class system for type checking */
	return (screen_t *)luaA_toudata(L, idx, &screen_class);
}

/** Find a screen object by its Monitor pointer
 * \param L Lua state
 * \param m Monitor pointer to search for
 * \return Screen object pointer, or NULL if not found
 */
screen_t *
luaA_screen_get_by_monitor(lua_State *L, Monitor *m)
{
	size_t i;

	if (!m)
		return NULL;

	/* Search through all screens */
	for (i = 0; i < screen_count; i++) {
		screen_t *screen;

		/* Get screen from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[i]);
		screen = (screen_t *)lua_touserdata(L, -1);
		lua_pop(L, 1);

		if (screen && screen->monitor == m)
			return screen;
	}

	return NULL;
}

/** Emit "_added" signal for a screen object
 * This is called after a screen is created and should trigger
 * awful.screen's signal bridge to emit request::desktop_decoration
 * \param L Lua state
 * \param screen Screen object that was added
 *
 * Note: This emits an instance-level "_added" signal on the screen object
 */
void
luaA_screen_added(lua_State *L, screen_t *screen)
{
	if (!screen || !screen->valid)
		return;

	/* Emit instance-level "_added" signal on the screen object (AwesomeWM pattern).
	 * awful.screen connects to this for setting up screen defaults. */
	luaA_screen_push(L, screen);
	luaA_object_emit_signal(L, -1, "_added", 0);
	lua_pop(L, 1);
}

/** Emit screen::scanning class signal */
void
luaA_screen_emit_scanning(lua_State *L)
{
	luaA_emit_signal_global("screen::scanning");
}

/** Emit screen::scanned class signal */
void
luaA_screen_emit_scanned(lua_State *L)
{
	screens_scanned = true;
	luaA_emit_signal_global("screen::scanned");
}

/** Check if initial screen scanning is complete
 * Used to distinguish startup from hotplug - screens created after scanning
 * need their _added signal emitted immediately.
 */
bool
luaA_screen_scanned_done(void)
{
	return screens_scanned;
}

/** Emit screen::list class signal
 * This notifies Lua code that the screen list has changed.
 * Should be called after screens are added or removed.
 */
void
luaA_screen_emit_list(lua_State *L)
{
	luaA_class_emit_signal(L, &screen_class, "list", 0);
}

/* Forward declaration for viewports function */
static int luaA_screen_viewports(lua_State *L);

/** Emit property::_viewports class signal
 * This notifies Lua code that viewport information has changed.
 * Used by awful.screen.dpi for DPI handling on multi-monitor setups.
 */
void
luaA_screen_emit_viewports(lua_State *L)
{
	/* Push the viewports table onto stack as signal argument */
	luaA_screen_viewports(L);
	luaA_class_emit_signal(L, &screen_class, "property::_viewports", 1);
}

/** Emit primary_changed signal on a screen object
 * This notifies Lua code that the screen's primary status changed.
 */
void
luaA_screen_emit_primary_changed(lua_State *L, screen_t *screen)
{
	if (!screen || !screen->valid)
		return;
	luaA_screen_push(L, screen);
	luaA_object_emit_signal(L, -1, "primary_changed", 0);
	lua_pop(L, 1);
}

/** Find screen by coordinates (for client relocation on screen removal)
 * Returns the screen that contains the given point, or the nearest screen
 * \param L Lua state
 * \param x X coordinate
 * \param y Y coordinate
 * \return Screen containing or nearest to the point, or NULL
 */
screen_t *
luaA_screen_getbycoord(lua_State *L, int x, int y)
{
	screen_t *nearest = NULL;
	unsigned int nearest_dist = UINT_MAX;
	size_t i;

	for (i = 0; i < screen_count; i++) {
		screen_t *s;
		unsigned int dist;
		int dx, dy;

		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[i]);
		s = (screen_t *)lua_touserdata(L, -1);
		lua_pop(L, 1);

		if (!s || !s->valid)
			continue;

		/* Check if point is inside this screen */
		if (x >= s->geometry.x && x < s->geometry.x + s->geometry.width &&
		    y >= s->geometry.y && y < s->geometry.y + s->geometry.height)
			return s;

		/* Calculate distance to screen center for fallback */
		dx = x - (s->geometry.x + s->geometry.width / 2);
		dy = y - (s->geometry.y + s->geometry.height / 2);
		dist = (unsigned int)(dx * dx + dy * dy);

		if (dist < nearest_dist) {
			nearest_dist = dist;
			nearest = s;
		}
	}

	return nearest;
}

/** Handle screen removal (AwesomeWM pattern)
 * Called when a monitor is disconnected. Emits "removed" signal on the screen
 * instance and relocates clients to the nearest screen.
 * \param L Lua state
 * \param screen Screen being removed
 */
void
luaA_screen_removed(lua_State *L, screen_t *screen)
{
	size_t i;

	if (!screen || !screen->valid)
		return;

	fprintf(stderr, "[SCREEN_REMOVED] Removing screen %p (index=%d)\n",
	        (void*)screen, screen->index);

	/* Step 1: Emit instance-level "removed" signal FIRST
	 * This allows Lua code to handle cleanup before screen is invalidated */
	luaA_screen_push(L, screen);
	luaA_object_emit_signal(L, -1, "removed", 0);
	lua_pop(L, 1);

	/* Step 2: Clear primary if this was it */
	if (primary_screen == screen)
		primary_screen = NULL;

	/* Step 3: Move clients to nearest screen
	 * Note: This uses the client's center point to find the nearest screen */
	foreach(c, globalconf.clients) {
		if ((*c)->screen == screen) {
			int cx = (*c)->geometry.x + (*c)->geometry.width / 2;
			int cy = (*c)->geometry.y + (*c)->geometry.height / 2;
			screen_t *new_screen = luaA_screen_getbycoord(L, cx, cy);

			if (new_screen && new_screen != screen) {
				fprintf(stderr, "[SCREEN_REMOVED] Moving client %p to screen %d\n",
				        (void*)*c, new_screen->index);
				screen_client_moveto(*c, new_screen, false);
			}
		}
	}

	/* Step 4: Mark screen as invalid */
	screen->valid = false;
	screen->monitor = NULL;

	/* Step 5: Remove from screen array and re-index remaining screens */
	for (i = 0; i < screen_count; i++) {
		screen_t *s;

		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[i]);
		s = (screen_t *)lua_touserdata(L, -1);
		lua_pop(L, 1);

		if (s == screen) {
			/* Found the screen - remove its reference */
			luaL_unref(L, LUA_REGISTRYINDEX, screen_refs[i]);

			/* Shift remaining references down */
			memmove(&screen_refs[i], &screen_refs[i + 1],
			        (screen_count - i - 1) * sizeof(int));
			screen_count--;

			/* Re-index remaining screens */
			for (size_t j = i; j < screen_count; j++) {
				screen_t *rs;
				lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[j]);
				rs = (screen_t *)lua_touserdata(L, -1);
				lua_pop(L, 1);
				if (rs)
					rs->index = (int)(j + 1);
			}
			break;
		}
	}

	/* Step 6: Emit class-level "list" signal to notify of screen array change */
	luaA_class_emit_signal(L, &screen_class, "list", 0);

	fprintf(stderr, "[SCREEN_REMOVED] Screen removal complete, %zu screens remaining\n",
	        screen_count);
}

/** Get primary screen
 * \param L Lua state
 * \return Primary screen or NULL if none set
 */
screen_t *
luaA_screen_get_primary_screen(lua_State *L)
{
	screen_t *s;

	/* If primary is set and still valid, return it */
	if (primary_screen && primary_screen->valid)
		return primary_screen;

	/* Otherwise return first screen if any exist */
	if (screen_count > 0) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[0]);
		s = (screen_t *)lua_touserdata(L, -1);
		lua_pop(L, 1);
		return s;
	}

	return NULL;
}

/** Emit _added signal for all existing screens
 * This is called after rc.lua loads to trigger screen initialization
 */
void
luaA_screen_emit_all_added(lua_State *L)
{
	size_t i;

	for (i = 0; i < screen_count; i++) {
		screen_t *screen;

		/* Get screen from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[i]);
		screen = (screen_t *)lua_touserdata(L, -1);
		lua_pop(L, 1);

		if (screen && screen->valid) {
			luaA_screen_added(L, screen);
		}
	}
}

/* ========================================================================
 * Screen property updates and change detection
 * ======================================================================== */

/** Helper to push wlr_box as Lua table */
static void
push_wlr_box(lua_State *L, struct wlr_box *box)
{
	lua_newtable(L);
	lua_pushinteger(L, box->x);
	lua_setfield(L, -2, "x");
	lua_pushinteger(L, box->y);
	lua_setfield(L, -2, "y");
	lua_pushinteger(L, box->width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, box->height);
	lua_setfield(L, -2, "height");
}

/* Note: wlr_box_equal() is provided by wlroots in wlr/util/box.h */

/** Update screen geometry from monitor and emit property::geometry if changed
 * \param L Lua state
 * \param screen Screen to update
 *
 * This should be called when the monitor's geometry changes (resolution change, etc.)
 * It will compare the new geometry with the cached value and emit property::geometry
 * with the old geometry if it changed.
 */
void
luaA_screen_update_geometry(lua_State *L, screen_t *screen)
{
	struct wlr_box new_geom;

	if (!screen || !screen->valid || !screen->monitor)
		return;

	/* Get current geometry from monitor */
	some_monitor_get_geometry(screen->monitor, &new_geom);

	/* Check if geometry changed */
	if (!wlr_box_equal(&screen->geometry, &new_geom)) {
		struct wlr_box old_geom = screen->geometry;

		/* Update cached geometry */
		screen->geometry = new_geom;

		/* Emit property::geometry signal with old geometry as argument */
		luaA_screen_push(L, screen);
		push_wlr_box(L, &old_geom);
		luaA_object_emit_signal(L, -2, "property::geometry", 1);
		lua_pop(L, 1);  /* Pop screen object */

		/* Also update workarea to match new geometry (will emit its own signal) */
		luaA_screen_update_workarea(L, screen, &new_geom);
	}
}

/** Update screen workarea and emit property::workarea if changed
 * \param L Lua state
 * \param screen Screen to update
 * \param workarea New workarea (or NULL to use current geometry)
 *
 * This should be called when struts change or geometry changes.
 * It will compare the new workarea with the cached value and emit property::workarea
 * with the old workarea if it changed.
 */
void
luaA_screen_update_workarea(lua_State *L, screen_t *screen, struct wlr_box *workarea)
{
	struct wlr_box new_workarea;

	if (!screen || !screen->valid)
		return;

	/* If no workarea provided, use current geometry */
	if (workarea) {
		new_workarea = *workarea;
	} else {
		new_workarea = screen->geometry;
	}

	/* Check if workarea changed */
	if (!wlr_box_equal(&screen->workarea, &new_workarea)) {
		struct wlr_box old_workarea = screen->workarea;

		/* Update cached workarea */
		screen->workarea = new_workarea;

		/* Update the C Monitor struct's workarea */
		if (screen->monitor) {
			screen->monitor->w = new_workarea;
			fprintf(stderr, "[SCREEN_WORKAREA] Updated monitor->w: %dx%d+%d+%d\n",
			        new_workarea.width, new_workarea.height, new_workarea.x, new_workarea.y);
		}

		/* Emit property::workarea signal with old workarea as argument */
		luaA_screen_push(L, screen);
		push_wlr_box(L, &old_workarea);
		luaA_object_emit_signal(L, -2, "property::workarea", 1);
		lua_pop(L, 1);  /* Pop screen object */
	}
}

/** Update screen workarea based on drawin struts
 * \param L Lua state
 * \param drawin Drawin that changed (used to find which screen to update)
 *
 * This should be called when a drawin's visibility, geometry, or struts change.
 * This is a simplified implementation that just updates the drawin's screen.
 * TODO: Implement full multi-drawin strut aggregation.
 */
void
luaA_screen_update_workarea_for_drawin(lua_State *L, struct drawin_t *drawin)
{
	screen_t *screen;
	struct wlr_box new_workarea;

	fprintf(stderr, "[UPDATE_WORKAREA_FOR_DRAWIN] Called with drawin=%p\n", (void*)drawin);

	if (!drawin) {
		fprintf(stderr, "[UPDATE_WORKAREA_FOR_DRAWIN] NULL drawin, returning\n");
		return;
	}

	fprintf(stderr, "[UPDATE_WORKAREA_FOR_DRAWIN] Drawin visible=%d struts: left=%d right=%d top=%d bottom=%d\n",
		drawin->visible, drawin->strut.left, drawin->strut.right, drawin->strut.top, drawin->strut.bottom);

	/* Get the screen this drawin is on */
	screen = drawin->screen;

	/* If no screen assigned yet, try to find it by geometry */
	if (!screen) {
		/* For now, just use primary screen or first screen */
		if (screen_count > 0) {
			lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[0]);
			screen = (screen_t *)lua_touserdata(L, -1);
			lua_pop(L, 1);
		}
	}

	if (!screen || !screen->valid)
		return;

	/* Simple implementation - just subtract drawin's struts from geometry
	 * TODO: Aggregate struts from ALL visible drawins on this screen */

	new_workarea = screen->geometry;

	/* Apply this drawin's struts if visible */
	if (drawin->visible) {
		new_workarea.x += drawin->strut.left;
		new_workarea.y += drawin->strut.top;
		new_workarea.width -= (drawin->strut.left + drawin->strut.right);
		new_workarea.height -= (drawin->strut.top + drawin->strut.bottom);

		/* Ensure workarea doesn't go negative */
		if (new_workarea.width < 1)
			new_workarea.width = 1;
		if (new_workarea.height < 1)
			new_workarea.height = 1;
	}

	/* Update the screen's workarea */
	luaA_screen_update_workarea(L, screen, &new_workarea);

	/* Re-arrange windows to respect the new workarea */
	if (screen->monitor) {
		fprintf(stderr, "[SCREEN_WORKAREA] Workarea updated for screen %d: %dx%d+%d+%d, calling arrange()\n",
		        screen->index, new_workarea.width, new_workarea.height, new_workarea.x, new_workarea.y);
		some_monitor_arrange(screen->monitor);
	}
}

/** Apply all drawin struts for a monitor to a usable area
 * \param L Lua state
 * \param m Monitor to get drawins for
 * \param area Box to apply struts to (modified in place)
 *
 * This is called from arrangelayers() to ensure drawin struts (from Lua wibars)
 * are preserved when layer shell surfaces rearrange.
 */
void
luaA_monitor_apply_drawin_struts(lua_State *L, Monitor *m, struct wlr_box *area)
{
	screen_t *screen;

	if (!m || !area)
		return;

	/* Find the screen object for this monitor */
	screen = luaA_screen_get_by_monitor(L, m);
	if (!screen || !screen->valid)
		return;

	/* Apply the screen's cached workarea which already includes drawin struts
	 * The workarea is updated whenever drawin struts change via
	 * luaA_screen_update_workarea_for_drawin() */
	if (screen->workarea.width > 0 && screen->workarea.height > 0) {
		/* Only apply if the workarea is smaller than current area (has struts) */
		if (screen->workarea.y > area->y ||
		    screen->workarea.x > area->x ||
		    (screen->workarea.width < area->width) ||
		    (screen->workarea.height < area->height)) {

			fprintf(stderr, "[APPLY_DRAWIN_STRUTS] Applying struts: %dx%d+%d+%d (was %dx%d+%d+%d)\n",
			        screen->workarea.width, screen->workarea.height,
			        screen->workarea.x, screen->workarea.y,
			        area->width, area->height, area->x, area->y);

			*area = screen->workarea;
		}
	}
}

/* ========================================================================
 * Screen Lua API - property getters
 * ======================================================================== */

/** screen.geometry - Get screen geometry
 * \param screen Screen object
 * \return Table {x=, y=, width=, height=}
 */
static int
luaA_screen_get_geometry(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);

	if (!screen) {
		lua_newtable(L);
		return 1;
	}

	/* Return cached geometry */
	lua_newtable(L);
	lua_pushinteger(L, screen->geometry.x);
	lua_setfield(L, -2, "x");
	lua_pushinteger(L, screen->geometry.y);
	lua_setfield(L, -2, "y");
	lua_pushinteger(L, screen->geometry.width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, screen->geometry.height);
	lua_setfield(L, -2, "height");

	return 1;
}

/** screen.workarea - Get screen workarea
 * \param screen Screen object
 * \return Table {x=, y=, width=, height=}
 */
static int
luaA_screen_get_workarea(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);

	if (!screen) {
		lua_newtable(L);
		return 1;
	}

	fprintf(stderr, "[GET_WORKAREA] Returning workarea: %dx%d+%d+%d\n",
		screen->workarea.width, screen->workarea.height, screen->workarea.x, screen->workarea.y);

	/* Return cached workarea */
	lua_newtable(L);
	lua_pushinteger(L, screen->workarea.x);
	lua_setfield(L, -2, "x");
	lua_pushinteger(L, screen->workarea.y);
	lua_setfield(L, -2, "y");
	lua_pushinteger(L, screen->workarea.width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, screen->workarea.height);
	lua_setfield(L, -2, "height");

	return 1;
}

/** screen:get_bounding_geometry - Get screen bounding geometry
 * This method is used by awful.placement to detect screen objects.
 * Returns the full screen geometry (same as screen.geometry).
 * \param screen Screen object
 * \param args Optional args table (ignored for screens)
 * \return Table {x=, y=, width=, height=}
 */
static int
luaA_screen_get_bounding_geometry(lua_State *L)
{
	screen_t *screen;
	struct wlr_box geo;
	int honor_workarea, honor_padding;

	screen = luaA_checkscreen(L, 1);

	if (!screen) {
		lua_newtable(L);
		return 1;
	}

	/* Check for arguments table */
	honor_workarea = 0;
	honor_padding = 0;

	if (lua_istable(L, 2)) {
		lua_getfield(L, 2, "honor_workarea");
		honor_workarea = lua_toboolean(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 2, "honor_padding");
		honor_padding = lua_toboolean(L, -1);
		lua_pop(L, 1);

		fprintf(stderr, "[GET_BOUNDING_GEO_C] honor_workarea=%d honor_padding=%d\n",
			honor_workarea, honor_padding);
	}

	/* Use workarea if requested, otherwise full geometry */
	geo = honor_workarea ? screen->workarea : screen->geometry;

	fprintf(stderr, "[GET_BOUNDING_GEO_C] Returning: %dx%d+%d+%d\n",
		geo.width, geo.height, geo.x, geo.y);

	/* TODO: Apply honor_padding and margins if needed */

	lua_newtable(L);
	lua_pushinteger(L, geo.x);
	lua_setfield(L, -2, "x");
	lua_pushinteger(L, geo.y);
	lua_setfield(L, -2, "y");
	lua_pushinteger(L, geo.width);
	lua_setfield(L, -2, "width");
	lua_pushinteger(L, geo.height);
	lua_setfield(L, -2, "height");

	return 1;
}

/** screen.index - Get screen index
 * \param screen Screen object
 * \return Integer index (1-based)
 */
static int
luaA_screen_get_index(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);
	lua_pushinteger(L, screen ? screen->index : 0);
	return 1;
}

/** screen.outputs - Get output name
 * \param screen Screen object
 * \return Table with output name
 */
static int
luaA_screen_get_outputs(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);
	struct wlr_output *output;

	if (!screen || !screen->monitor || !screen->monitor->wlr_output) {
		lua_newtable(L);
		return 1;
	}

	output = screen->monitor->wlr_output;

	/* Create outputs table with numeric index (AwesomeWM format)
	 * Format: { [1] = { name=..., mm_width=..., mm_height=..., viewport_id=... } }
	 * The Lua layer (awful/screen.lua) converts this to name-keyed for user access */
	lua_newtable(L);

	/* Create output entry */
	lua_newtable(L);

	/* name */
	lua_pushstring(L, output->name);
	lua_setfield(L, -2, "name");

	/* mm_width - Physical width in millimeters (for DPI calculation) */
	lua_pushinteger(L, output->phys_width);
	lua_setfield(L, -2, "mm_width");

	/* mm_height - Physical height in millimeters (for DPI calculation) */
	lua_pushinteger(L, output->phys_height);
	lua_setfield(L, -2, "mm_height");

	/* viewport_id - Use screen index for AwesomeWM compatibility */
	lua_pushinteger(L, screen->index);
	lua_setfield(L, -2, "viewport_id");

	/* Set with numeric index 1 (AwesomeWM uses numeric indices) */
	lua_rawseti(L, -2, 1);

	return 1;
}

/** screen.name - Get screen name
 * \param screen Screen object
 * \return String name or monitor name if not set
 */
static int
luaA_screen_get_name(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);

	if (!screen) {
		lua_pushnil(L);
		return 1;
	}

	/* If user set a name, return that */
	if (screen->name) {
		lua_pushstring(L, screen->name);
	} else if (screen->monitor) {
		/* Otherwise return monitor name */
		const char *mon_name = some_get_monitor_name(screen->monitor);
		lua_pushstring(L, mon_name ? mon_name : "");
	} else {
		lua_pushstring(L, "");
	}

	return 1;
}

/** screen.name (setter) - Set screen name
 * \param screen Screen object
 * \param name New name string
 */
static int
luaA_screen_set_name(lua_State *L, screen_t *screen)
{
	const char *new_name = luaL_checkstring(L, -1);
	const char *old_name = screen->name;

	/* Free old name if set */
	if (screen->name) {
		free(screen->name);
		screen->name = NULL;
	}

	/* Set new name */
	screen->name = strdup(new_name);

	/* Emit property::name signal if name actually changed */
	if ((old_name == NULL) ||
	    (old_name != NULL && strcmp(old_name, new_name) != 0)) {
		luaA_screen_push(L, screen);
		if (old_name) {
			lua_pushstring(L, old_name);
		} else {
			lua_pushnil(L);
		}
		luaA_object_emit_signal(L, -2, "property::name", 1);
		lua_pop(L, 1);  /* Pop screen object */
	}

	if (old_name)
		free((void*)old_name);

	return 0;
}

/** screen._managed - Get screen lifecycle management status
 * \param screen Screen object
 * \return String "C", "Lua", or "User"
 */
static int
luaA_screen_get_managed(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);

	if (!screen) {
		lua_pushnil(L);
		return 1;
	}

	/* Return lifecycle status */
	switch (screen->lifecycle) {
	case SCREEN_LIFECYCLE_C:
		lua_pushstring(L, "C");
		break;
	case SCREEN_LIFECYCLE_LUA:
		lua_pushstring(L, "Lua");
		break;
	case SCREEN_LIFECYCLE_USER:
		lua_pushstring(L, "User");
		break;
	default:
		lua_pushstring(L, "C");
		break;
	}

	return 1;
}

/* Property wrappers for luaA_class_add_property - these adapt the existing
 * getter functions to the property system's (lua_State*, screen_t*) signature */

static int luaA_screen_get_geometry_prop(lua_State *L, screen_t *s) {
	(void)s;  /* screen is on stack at position 1 */
	return luaA_screen_get_geometry(L);
}

static int luaA_screen_get_index_prop(lua_State *L, screen_t *s) {
	(void)s;
	return luaA_screen_get_index(L);
}

static int luaA_screen_get_outputs_prop(lua_State *L, screen_t *s) {
	(void)s;
	return luaA_screen_get_outputs(L);
}

static int luaA_screen_get_workarea_prop(lua_State *L, screen_t *s) {
	(void)s;
	return luaA_screen_get_workarea(L);
}

static int luaA_screen_get_name_prop(lua_State *L, screen_t *s) {
	(void)s;
	return luaA_screen_get_name(L);
}

static int luaA_screen_get_managed_prop(lua_State *L, screen_t *s) {
	(void)s;
	return luaA_screen_get_managed(L);
}

/* ========================================================================
 * Screen Lua API - global functions
 * ======================================================================== */

/** screen.count() - Get number of screens
 * \return Integer count
 */
static int
luaA_screen_count(lua_State *L)
{
	lua_pushinteger(L, screen_count);
	return 1;
}

/** screen._viewports() - Get viewport information for all monitors
 * Returns viewport data used for DPI calculation by awful.screen.dpi
 *
 * \return Table of viewport tables with format:
 * {
 *   [1] = {
 *     geometry = {x=0, y=0, width=1920, height=1080},
 *     outputs = {
 *       [1] = {mm_width=530, mm_height=300, name="HDMI-A-1", viewport_id=1}
 *     },
 *     id = 1
 *   }
 * }
 */
static int
luaA_screen_viewports(lua_State *L)
{
	Monitor *m;
	int viewport_id = 1;

	lua_newtable(L);  /* Create main viewport array */

	wl_list_for_each(m, &mons, link) {
		if (!m->wlr_output)
			continue;

		lua_newtable(L);  /* Create viewport table */

		/* Add geometry table */
		lua_pushstring(L, "geometry");
		lua_newtable(L);
		lua_pushinteger(L, m->m.x);
		lua_setfield(L, -2, "x");
		lua_pushinteger(L, m->m.y);
		lua_setfield(L, -2, "y");
		lua_pushinteger(L, m->m.width);
		lua_setfield(L, -2, "width");
		lua_pushinteger(L, m->m.height);
		lua_setfield(L, -2, "height");
		lua_settable(L, -3);  /* Set geometry in viewport table */

		/* Add outputs array */
		lua_pushstring(L, "outputs");
		lua_newtable(L);  /* Create outputs array */

		/* Create first output entry */
		lua_newtable(L);
		lua_pushinteger(L, m->wlr_output->phys_width);
		lua_setfield(L, -2, "mm_width");
		lua_pushinteger(L, m->wlr_output->phys_height);
		lua_setfield(L, -2, "mm_height");
		lua_pushstring(L, m->wlr_output->name);
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, viewport_id);
		lua_setfield(L, -2, "viewport_id");
		lua_rawseti(L, -2, 1);  /* outputs[1] = output_table */

		lua_settable(L, -3);  /* Set outputs in viewport table */

		/* Add viewport ID */
		lua_pushstring(L, "id");
		lua_pushinteger(L, viewport_id);
		lua_settable(L, -3);  /* Set id in viewport table */

		/* Add viewport to main array */
		lua_rawseti(L, -2, viewport_id);
		viewport_id++;
	}

	return 1;
}

/** screen.fake_add(x, y, width, height) - Create virtual screen (AwesomeWM API)
 * Used by awful.screen.split() to divide physical monitors into virtual screens.
 * \param x X position
 * \param y Y position
 * \param width Width
 * \param height Height
 * \return New screen object
 */
static int
luaA_screen_fake_add(lua_State *L)
{
	int x = luaL_checkinteger(L, 1);
	int y = luaL_checkinteger(L, 2);
	int width = luaL_checkinteger(L, 3);
	int height = luaL_checkinteger(L, 4);
	screen_t *screen;
	int ref;

	fprintf(stderr, "[SCREEN_FAKE_ADD] Creating virtual screen at (%d,%d) %dx%d\n",
	        x, y, width, height);

	/* Allocate screen userdata */
	screen = (screen_t *)lua_newuserdata(L, sizeof(screen_t));
	if (!screen) {
		return luaL_error(L, "Failed to allocate virtual screen");
	}

	/* Initialize virtual screen (no monitor) */
	screen->monitor = NULL;  /* Virtual screen has no physical monitor */
	screen->index = (int)(screen_count + 1);
	screen->valid = true;
	screen->lifecycle = SCREEN_LIFECYCLE_USER;
	screen->geometry.x = x;
	screen->geometry.y = y;
	screen->geometry.width = width;
	screen->geometry.height = height;
	screen->workarea = screen->geometry;
	screen->name = NULL;
	signal_array_init(&screen->signals);

	/* Set metatable */
	luaL_getmetatable(L, SCREEN_MT);
	lua_setmetatable(L, -2);

	/* Initialize environment table */
	lua_newtable(L);
	luaA_setuservalue(L, -2);

	/* Store reference in registry */
	lua_pushvalue(L, -1);
	ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Add to screen array */
	if (screen_count >= screen_capacity) {
		size_t new_cap = screen_capacity == 0 ? 4 : screen_capacity * 2;
		int *new_refs = realloc(screen_refs, new_cap * sizeof(int));
		if (!new_refs) {
			luaL_unref(L, LUA_REGISTRYINDEX, ref);
			return luaL_error(L, "Failed to allocate screen array");
		}
		screen_refs = new_refs;
		screen_capacity = new_cap;
	}
	screen_refs[screen_count++] = ref;

	/* Emit "added" signal */
	luaA_screen_added(L, screen);

	/* Emit class-level "list" signal */
	luaA_class_emit_signal(L, &screen_class, "list", 0);

	/* Relocate clients that should now be on this new screen (AwesomeWM behavior) */
	foreach(c, globalconf.clients) {
		int cx = (*c)->geometry.x + (*c)->geometry.width / 2;
		int cy = (*c)->geometry.y + (*c)->geometry.height / 2;
		screen_t *best = luaA_screen_getbycoord(L, cx, cy);
		if (best && best != (*c)->screen) {
			screen_client_moveto(*c, best, false);
		}
	}

	fprintf(stderr, "[SCREEN_FAKE_ADD] Virtual screen created at index %d\n", screen->index);

	/* Return screen object (still on stack) */
	return 1;
}

/** screen:fake_remove() - Remove virtual screen (AwesomeWM API)
 * Removes a screen created by fake_add()
 */
static int
luaA_screen_fake_remove(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);

	if (!screen || !screen->valid) {
		return 0;
	}

	fprintf(stderr, "[SCREEN_FAKE_REMOVE] Removing virtual screen %p (index=%d)\n",
	        (void*)screen, screen->index);

	if (screen_count == 1) {
		fprintf(stderr, "somewm: WARNING: Removing last screen through fake_remove()!\n");
	}

	/* Use shared removal logic (emits signals, moves clients, etc.) */
	luaA_screen_removed(L, screen);

	return 0;
}

/** screen:fake_resize(x, y, width, height) - Resize virtual screen (AwesomeWM API)
 * Changes the geometry of a virtual screen
 */
static int
luaA_screen_fake_resize(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);
	int x = luaL_checkinteger(L, 2);
	int y = luaL_checkinteger(L, 3);
	int width = luaL_checkinteger(L, 4);
	int height = luaL_checkinteger(L, 5);
	struct wlr_box old_geometry;

	if (!screen || !screen->valid) {
		return 0;
	}

	fprintf(stderr, "[SCREEN_FAKE_RESIZE] Resizing screen %d from (%d,%d %dx%d) to (%d,%d %dx%d)\n",
	        screen->index, screen->geometry.x, screen->geometry.y,
	        screen->geometry.width, screen->geometry.height, x, y, width, height);

	/* Save old geometry for signal */
	old_geometry = screen->geometry;

	/* Update geometry */
	screen->geometry.x = x;
	screen->geometry.y = y;
	screen->geometry.width = width;
	screen->geometry.height = height;

	/* Update workarea properly (accounts for struts from wibars)
	 * This will use geometry as baseline and emit property::workarea if needed */
	luaA_screen_update_workarea(L, screen, NULL);

	/* Emit property::geometry signal with old value */
	luaA_screen_push(L, screen);
	push_wlr_box(L, &old_geometry);
	luaA_object_emit_signal(L, -2, "property::geometry", 1);
	lua_pop(L, 1);

	return 0;
}

/** Swap two screens in the screen list.
 *
 * @method swap
 * @tparam screen other_screen The screen to swap with.
 * @noreturn
 */
static int
luaA_screen_swap(lua_State *L)
{
	screen_t *s = luaA_checkscreen(L, 1);
	screen_t *swap = luaA_checkscreen(L, 2);

	if (!s || !swap || !s->valid || !swap->valid)
		return 0;

	if (s != swap) {
		int ref_s_idx = -1, ref_swap_idx = -1;
		int tmp_ref;
		size_t i;

		/* Find indices of both screens */
		for (i = 0; i < screen_count; i++) {
			screen_t *screen = NULL;
			lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[i]);
			screen = luaA_checkscreen(L, -1);
			lua_pop(L, 1);

			if (screen == s)
				ref_s_idx = i;
			else if (screen == swap)
				ref_swap_idx = i;

			if (ref_s_idx >= 0 && ref_swap_idx >= 0)
				break;
		}

		if (ref_s_idx < 0 || ref_swap_idx < 0)
			return luaL_error(L, "Invalid call to screen:swap()");

		/* Swap the refs */
		tmp_ref = screen_refs[ref_s_idx];
		screen_refs[ref_s_idx] = screen_refs[ref_swap_idx];
		screen_refs[ref_swap_idx] = tmp_ref;

		/* Update indices */
		s->index = ref_swap_idx + 1;
		swap->index = ref_s_idx + 1;

		/* Emit screen.list class signal */
		luaA_class_emit_signal(L, &screen_class, "list", 0);

		/* Emit swapped signal on first screen */
		luaA_screen_push(L, swap);
		lua_pushboolean(L, true);
		luaA_screen_push(L, s);
		luaA_object_emit_signal(L, -3, "swapped", 2);
		lua_pop(L, 1);

		/* Emit swapped signal on second screen */
		luaA_screen_push(L, s);
		lua_pushboolean(L, false);
		luaA_screen_push(L, swap);
		luaA_object_emit_signal(L, -3, "swapped", 2);
		lua_pop(L, 1);
	}

	return 0;
}

/** screen[index] or screen(index) - Get screen by index
 * \param index Screen index (1-based)
 * \return Screen object or nil
 */
static int
luaA_screen_get_by_index(lua_State *L)
{
	int index = luaL_checkinteger(L, 1);

	if (index < 1 || index > (int)screen_count) {
		lua_pushnil(L);
		return 1;
	}

	/* Push screen from registry */
	lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[index - 1]);
	return 1;
}

/** __index metamethod for screen class table
 * Handles:
 * - screen[1] -> screen object (numeric index)
 * - screen[screen_obj] -> screen_obj (identity for screen objects)
 * - screen.method_name -> method (method lookup)
 */
static int
luaA_screen_module_index(lua_State *L)
{
	/* L[1] is the screen table, L[2] is the key */
	fprintf(stderr, "[SCREEN_MODULE_INDEX] Called with key type: %s\n",
	        lua_typename(L, lua_type(L, 2)));

	/* Numeric index: screen[1] */
	if (lua_isnumber(L, 2)) {
		int index = lua_tointeger(L, 2);

		if (index < 1 || index > (int)screen_count) {
			lua_pushnil(L);
			return 1;
		}

		/* Push screen from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[index - 1]);
		return 1;
	}

	/* Screen object as key: screen[screen_obj] -> screen_obj
	 * This allows get_screen() functions to work: get_screen(s) where s might
	 * already be a screen object. Calling screen[s] returns s unchanged.
	 */
	if (lua_isuserdata(L, 2)) {
		screen_t *s = luaA_checkscreen(L, 2);
		fprintf(stderr, "[SCREEN_MODULE_INDEX] screen[userdata]: s=%p valid=%d\n",
		        (void*)s, s ? s->valid : -1);
		if (s && s->valid) {
			/* Return the same screen object */
			lua_pushvalue(L, 2);
			return 1;
		}
		/* Invalid screen, return nil */
		fprintf(stderr, "[SCREEN_MODULE_INDEX] Returning nil for invalid/null screen\n");
		lua_pushnil(L);
		return 1;
	}

	/* Special handling for .primary and .automatic_factory properties (AwesomeWM compatibility) */
	if (lua_isstring(L, 2)) {
		const char *key = lua_tostring(L, 2);
		if (strcmp(key, "automatic_factory") == 0) {
			/* Always return true - we automatically manage screens */
			lua_pushboolean(L, 1);
			return 1;
		} else if (strcmp(key, "primary") == 0) {
			screen_t *primary;

			fprintf(stderr, "[SCREEN_MODULE_INDEX] Accessing .primary property\n");
			primary = luaA_screen_get_primary_screen(L);
			fprintf(stderr, "[SCREEN_MODULE_INDEX] primary screen=%p\n", (void*)primary);
			if (primary) {
				luaA_object_push(L, primary);
				fprintf(stderr, "[SCREEN_MODULE_INDEX] Pushed primary screen to stack\n");
			} else {
				lua_pushnil(L);
				fprintf(stderr, "[SCREEN_MODULE_INDEX] No primary screen, pushed nil\n");
			}
			return 1;
		}
	}

	/* Method/property lookup: screen.method_name */
	lua_pushvalue(L, 2);  /* Push key */
	lua_rawget(L, 1);     /* Get screen_table[key] */

	return 1;
}

/** __call metamethod for screen class
 * This function serves as both:
 * 1. The iterator function for "for s in screen do" loops
 * 2. Direct indexing via screen(index)
 *
 * For iteration, the generic for loop calls this as: screen(nil, previous_screen)
 * where previous_screen is nil on first iteration, then each subsequent screen.
 * We return the next screen in the sequence, or nil when done.
 *
 * This matches AwesomeWM's implementation pattern.
 */
static int
luaA_screen_call(lua_State *L)
{
	int index;
	screen_t *prev;

	fprintf(stderr, "[SCREEN_CALL] Called with %d arguments\n", lua_gettop(L));

	/* For iteration: screen(state, control_var) where L[1]=self, L[2]=state, L[3]=control_var
	 * For direct call: screen(index) where L[1]=self, L[2]=index */

	/* Check if this is direct indexing: screen(number) */
	if (lua_gettop(L) >= 2 && lua_isnumber(L, 2) && !lua_isnil(L, 2)) {
		index = luaL_checkinteger(L, 2);
		fprintf(stderr, "[SCREEN_CALL] Direct indexing: screen(%d)\n", index);

		if (index < 1 || index > (int)screen_count) {
			lua_pushnil(L);
			return 1;
		}

		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[index - 1]);
		return 1;
	}

	/* Iterator mode: L[3] is the control variable (previous screen or nil) */
	if (lua_isnoneornil(L, 3)) {
		/* First iteration - return first screen */
		index = 0;
		fprintf(stderr, "[SCREEN_ITERATE] First iteration, returning screen 1\n");
	} else {
		/* Get previous screen and return next one */
		prev = luaA_toscreen(L, 3);
		if (!prev) {
			fprintf(stderr, "[SCREEN_ITERATE] Invalid previous screen\n");
			lua_pushnil(L);
			return 1;
		}
		index = prev->index;
		fprintf(stderr, "[SCREEN_ITERATE] Previous screen index: %d\n", index);
	}

	/* Return next screen */
	if (index >= 0 && index < (int)screen_count) {
		screen_t *s;

		/* Get screen pointer from registry to use with luaA_object_push */
		fprintf(stderr, "[SCREEN_ITERATE] Getting screen at index %d from registry (ref=%d)\n",
		        index, screen_refs[index]);
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_refs[index]);
		fprintf(stderr, "[SCREEN_ITERATE] Stack top type after rawgeti: %s\n", lua_typename(L, lua_type(L, -1)));
		s = luaA_toscreen(L, -1);
		fprintf(stderr, "[SCREEN_ITERATE] luaA_toscreen returned: %p\n", (void*)s);
		lua_pop(L, 1);  /* Pop the userdata we just retrieved */

		if (s) {
			/* Use AwesomeWM's object push for proper metatable */
			fprintf(stderr, "[SCREEN_ITERATE] Calling luaA_object_push for screen %p\n", (void*)s);
			luaA_object_push(L, s);
			fprintf(stderr, "[SCREEN_ITERATE] After push, stack top type: %s\n", lua_typename(L, lua_type(L, -1)));
			fprintf(stderr, "[SCREEN_ITERATE] Returning screen %d via luaA_object_push\n", index + 1);
		} else {
			lua_pushnil(L);
			fprintf(stderr, "[SCREEN_ITERATE] Screen %d pointer is NULL!\n", index + 1);
		}
		return 1;
	}

	/* No more screens */
	fprintf(stderr, "[SCREEN_ITERATE] End of iteration\n");
	lua_pushnil(L);
	return 1;
}

/* ========================================================================
 * Screen Lua API - object methods (metamethods)
 * ======================================================================== */

/** screen:connect_signal(name, callback) - Connect to a screen signal
 */
static int
luaA_screen_connect_signal(lua_State *L)
{
	/* Use common infrastructure instead of custom signal code */
	return luaA_object_connect_signal_simple(L);
}

/** screen:emit_signal(name, ...) - Emit a screen signal
 * Emits signal on instance, then forwards to class (AwesomeWM pattern).
 */
static int
luaA_screen_emit_signal(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);
	const char *name = luaL_checkstring(L, 2);
	int nargs = lua_gettop(L) - 2;

	if (screen) {
		/* Emit on instance signals first */
		signal_object_emit(L, &screen->signals, name, nargs);

		/* Then forward to class signals (AwesomeWM pattern).
		 * This allows class-level handlers connected via screen.connect_signal()
		 * to receive signals emitted via s:emit_signal(). */
		lua_pushvalue(L, 1);  /* Push screen object */
		lua_insert(L, - nargs - 1);  /* Move it before args */
		luaA_class_emit_signal(L, &screen_class, name, nargs + 1);
	}

	return 0;
}

/** screen:disconnect_signal(name, callback) - Disconnect from a screen signal
 * TODO: Implement proper signal disconnection. For now, this is a no-op.
 */
static int
luaA_screen_disconnect_signal(lua_State *L)
{
	luaA_checkscreen(L, 1);
	luaL_checkstring(L, 2);
	luaL_checktype(L, 3, LUA_TFUNCTION);

	/* TODO: Implement signal_array_disconnect or equivalent
	 * For now, just accept the parameters without error to prevent crashes
	 */

	return 0;
}

/** screen:__index - Property getter
 */
static int
luaA_screen_index(lua_State *L)
{
	const char *key;

	/* Validate screen object (luaA_checkscreen will error if invalid) */
	screen_t *s = luaA_checkscreen(L, 1);
	fprintf(stderr, "[SCREEN_INDEX] screen=%p type_at_1=%s\n", (void*)s, lua_typename(L, lua_type(L, 1)));
	key = luaL_checkstring(L, 2);
	fprintf(stderr, "[SCREEN_INDEX] key='%s' handler=%d STARTING LOOKUP\n", key, screen_class.index_miss_handler);

	/* Check for properties */
	if (strcmp(key, "geometry") == 0)
		return luaA_screen_get_geometry(L);
	if (strcmp(key, "workarea") == 0)
		return luaA_screen_get_workarea(L);
	if (strcmp(key, "index") == 0)
		return luaA_screen_get_index(L);
	if (strcmp(key, "outputs") == 0)
		return luaA_screen_get_outputs(L);
	if (strcmp(key, "name") == 0)
		return luaA_screen_get_name(L);
	if (strcmp(key, "_managed") == 0)
		return luaA_screen_get_managed(L);
	if (strcmp(key, "valid") == 0) {
		screen_t *screen = luaA_checkscreen(L, 1);
		lua_pushboolean(L, screen->valid);
		return 1;
	}

	/* Check for _private table (AwesomeWM compatibility) */
	if (strcmp(key, "_private") == 0) {
		luaA_getuservalue(L, 1);  /* Return the environment table itself */
		fprintf(stderr, "[SCREEN_INDEX] Returning _private, type=%s\n", lua_typename(L, lua_type(L, -1)));
		return 1;
	}

	/* Check for methods in metatable */
	fprintf(stderr, "[SCREEN_INDEX] Checking metatable for '%s'\n", key);
	lua_getmetatable(L, 1);  /* Get the actual metatable of the screen object */
	if (!lua_isnil(L, -1)) {
		lua_getfield(L, -1, key);
		if (!lua_isnil(L, -1)) {
			fprintf(stderr, "[SCREEN_INDEX] Found '%s' in metatable, type=%s\n", key, lua_typename(L, lua_type(L, -1)));
			return 1;  /* Found in metatable */
		}
		lua_pop(L, 1);  /* Pop nil result */
	}
	fprintf(stderr, "[SCREEN_INDEX] '%s' NOT in metatable, checking handler\n", key);
	lua_pop(L, 1);  /* Pop metatable (or nil if no metatable) */

	/* Call index miss handler if registered (for dynamic properties) */
	if (screen_class.index_miss_handler != LUA_REFNIL) {
		fprintf(stderr, "[SCREEN_INDEX] Calling index_miss_handler for key '%s'\n", key);
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_class.index_miss_handler);
		fprintf(stderr, "[SCREEN_INDEX] Handler type: %s\n", lua_typename(L, lua_type(L, -1)));
		lua_pushvalue(L, 1);  /* Push screen object */
		lua_pushvalue(L, 2);  /* Push key */
		fprintf(stderr, "[SCREEN_INDEX] About to call handler...\n");
		lua_call(L, 2, 1);    /* Call handler(screen, key) */
		fprintf(stderr, "[SCREEN_INDEX] Handler returned type: %s\n", lua_typename(L, lua_type(L, -1)));
		return 1;
	}

	/* Fallback: check for custom properties in environment table */
	luaA_getuservalue(L, 1);
	lua_getfield(L, -1, key);
	return 1;
}

/** screen:__newindex - Property setter
 */
static int
luaA_screen_newindex(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);
	const char *key = luaL_checkstring(L, 2);

	/* Only 'name' property is writable */
	if (strcmp(key, "name") == 0) {
		const char *new_name = NULL;
		const char *old_name = screen->name;

		/* Get new name (can be nil to unset) */
		if (!lua_isnil(L, 3)) {
			new_name = luaL_checkstring(L, 3);
		}

		/* Free old name if set */
		if (screen->name) {
			free(screen->name);
			screen->name = NULL;
		}

		/* Set new name if provided */
		if (new_name) {
			screen->name = strdup(new_name);
		}

		/* Emit property::name signal if name actually changed */
		if ((old_name == NULL && new_name != NULL) ||
		    (old_name != NULL && new_name == NULL) ||
		    (old_name != NULL && new_name != NULL && strcmp(old_name, new_name) != 0)) {
			luaA_screen_push(L, screen);
			if (old_name) {
				lua_pushstring(L, old_name);
			} else {
				lua_pushnil(L);
			}
			luaA_object_emit_signal(L, -2, "property::name", 1);
			lua_pop(L, 1);  /* Pop screen object */
		}

		return 0;
	}

	/* Call newindex miss handler if registered (for dynamic properties) */
	if (screen_class.newindex_miss_handler != LUA_REFNIL) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, screen_class.newindex_miss_handler);
		lua_pushvalue(L, 1);  /* Push screen object */
		lua_pushvalue(L, 2);  /* Push key */
		lua_pushvalue(L, 3);  /* Push value */
		lua_call(L, 3, 0);    /* Call handler(screen, key, value) */
		return 0;
	}

	/* Fallback: Allow arbitrary properties to be stored in the userdata
	 * environment table. This allows Lua code to attach custom properties
	 * like mywibox, mytaglist, etc. to screen objects.
	 */
	luaA_getuservalue(L, 1);
	lua_pushvalue(L, 2);  /* Push key */
	lua_pushvalue(L, 3);  /* Push value */
	lua_rawset(L, -3);    /* env[key] = value */
	lua_pop(L, 1);        /* Pop environment table */

	return 0;
}

/** screen:__tostring - Convert to string
 */
static int
luaA_screen_tostring(lua_State *L)
{
	screen_t *screen = luaA_checkscreen(L, 1);
	const char *name = screen && screen->monitor ? some_get_monitor_name(screen->monitor) : "unknown";
	lua_pushfstring(L, "screen{index=%d, name=%s}", screen ? screen->index : 0, name ? name : "nil");
	return 1;
}

/** screen:__gc - Garbage collector
 */
static int
luaA_screen_gc(lua_State *L)
{
	screen_t *screen = luaA_toscreen(L, 1);
	if (screen) {
		screen->valid = false;
		signal_array_wipe(&screen->signals);
		/* Free name if allocated */
		if (screen->name) {
			free(screen->name);
			screen->name = NULL;
		}
	}
	return 0;
}

/* ========================================================================
 * Screen class-level signal methods
 * ======================================================================== */

/* Note: LUA_CLASS_FUNCS macro (line 14) automatically generates these functions:
 * - luaA_screen_class_add_signal (deprecated, no-op)
 * - luaA_screen_class_connect_signal
 * - luaA_screen_class_disconnect_signal
 * - luaA_screen_class_emit_signal
 * - luaA_screen_set_index_miss_handler
 * - luaA_screen_set_newindex_miss_handler
 * - luaA_screen_get_index_miss_handler
 * - luaA_screen_get_newindex_miss_handler
 */

/* ========================================================================
 * Screen-client operations (AwesomeWM compatibility)
 * ======================================================================== */

/** Get screen at coordinates - X11 compatibility wrapper
 * \param x The x coordinate
 * \param y The y coordinate
 * \return The screen at the given coordinates, or nearest screen if outside all screens
 */
screen_t *
screen_getbycoord(int x, int y)
{
	lua_State *L = globalconf_get_lua_State();
	return luaA_screen_getbycoord(L, x, y);
}

/** Check if a geometry overlaps with a screen
 * \param s The screen
 * \param geom The geometry
 * \return True if there is any overlap between the geometry and the screen
 */
bool
screen_area_in_screen(screen_t *s, area_t geom)
{
	return (geom.x < s->geometry.x + s->geometry.width)
	       && (geom.x + geom.width > s->geometry.x)
	       && (geom.y < s->geometry.y + s->geometry.height)
	       && (geom.y + geom.height > s->geometry.y);
}

/** Get the Monitor (wlroots output wrapper) for a given screen object
 * \param L The Lua state
 * \param screen The screen object to find the monitor for
 * \return The Monitor associated with the screen, or NULL if not found
 */
Monitor *
luaA_monitor_get_by_screen(lua_State *L, screen_t *screen)
{
	extern struct wl_list mons;
	Monitor *m;

	if (!screen)
		return NULL;

	wl_list_for_each(m, &mons, link) {
		if (luaA_screen_get_by_monitor(L, m) == screen)
			return m;
	}
	return NULL;
}

/** Move a client to a screen (AwesomeWM pattern)
 * \param c The client to move
 * \param new_screen The destination screen
 * \param doresize True to resize/reposition the client for the new screen
 */
void
screen_client_moveto(client_t *c, screen_t *new_screen, bool doresize)
{
	lua_State *L = globalconf_get_lua_State();
	screen_t *old_screen = c->screen;
	area_t from, to;
	area_t new_geometry;
	bool had_focus = false;

	/* Forward declare apply_geometry_to_wlroots from somewm.c */
	extern void apply_geometry_to_wlroots(client_t *c);

	if (new_screen == c->screen)
		return;

	if (globalconf.focus.client == c)
		had_focus = true;

	c->screen = new_screen;

	/* Update c->mon to match the new screen (fixes multi-monitor visibility bug) */
	if (new_screen) {
		Monitor *new_mon = luaA_monitor_get_by_screen(L, new_screen);
		if (new_mon && new_mon != c->mon) {
			extern void banning_need_update(void);
			c->mon = new_mon;
			banning_need_update();
		}
	}

	if (!doresize) {
		luaA_object_push(L, c);
		if (old_screen != NULL)
			luaA_object_push(L, old_screen);
		else
			lua_pushnil(L);
		luaA_object_emit_signal(L, -2, "property::screen", 1);
		lua_pop(L, 1);
		if (had_focus)
			client_focus(c);
		return;
	}

	from = old_screen->geometry;
	to = c->screen->geometry;

	new_geometry = c->geometry;

	new_geometry.x = to.x + new_geometry.x - from.x;
	new_geometry.y = to.y + new_geometry.y - from.y;

	/* resize the client if it doesn't fit the new screen */
	if (new_geometry.width > to.width)
		new_geometry.width = to.width;
	if (new_geometry.height > to.height)
		new_geometry.height = to.height;

	/* make sure the client is still on the screen */
	if (new_geometry.x + new_geometry.width > to.x + to.width)
		new_geometry.x = to.x + to.width - new_geometry.width;
	if (new_geometry.y + new_geometry.height > to.y + to.height)
		new_geometry.y = to.y + to.height - new_geometry.height;
	if (!screen_area_in_screen(new_screen, new_geometry)) {
		/* If all else fails, force the client to end up on screen. */
		new_geometry.x = to.x;
		new_geometry.y = to.y;
	}

	/* move / resize the client */
	client_resize(c, new_geometry, false);

	/* Force immediate scene node position update (bypass deferred refresh)
	 * This ensures the window appears on the new screen immediately */
	apply_geometry_to_wlroots(c);

	/* emit signal */
	luaA_object_push(L, c);
	if (old_screen != NULL)
		luaA_object_push(L, old_screen);
	else
		lua_pushnil(L);
	luaA_object_emit_signal(L, -2, "property::screen", 1);
	lua_pop(L, 1);

	if (had_focus)
		client_focus(c);
}

/* ========================================================================
 * Screen class setup
 * ======================================================================== */

/* Screen instance metamethods (AwesomeWM pattern) */
static const luaL_Reg screen_meta[] = {
	/* Basic metamethods */
	{ "__index", luaA_screen_index },
	{ "__newindex", luaA_screen_newindex },
	{ "__tostring", luaA_screen_tostring },
	{ "__gc", luaA_screen_gc },
	/* Signal support */
	{ "connect_signal", luaA_screen_connect_signal },
	{ "disconnect_signal", luaA_screen_disconnect_signal },
	{ "emit_signal", luaA_screen_emit_signal },
	/* Screen-specific methods */
	{ "get_bounding_geometry", luaA_screen_get_bounding_geometry },
	{ "fake_remove", luaA_screen_fake_remove },
	{ "fake_resize", luaA_screen_fake_resize },
	{ "swap", luaA_screen_swap },
	{ NULL, NULL }
};

/** Check if a screen is valid (AwesomeWM pattern) */
static bool
screen_checker(screen_t *s)
{
	(void)s;
	/* In somewm, screens are always valid once created
	 * TODO: Implement proper validation if needed */
	return true;
}

/* Screen class methods (for global screen table) */
static const luaL_Reg screen_methods[] = {
	/* Class-level signal methods (generated by LUA_CLASS_FUNCS) */
	{ "add_signal", luaA_screen_class_add_signal },
	{ "connect_signal", luaA_screen_class_connect_signal },
	{ "disconnect_signal", luaA_screen_class_disconnect_signal },
	{ "emit_signal", luaA_screen_class_emit_signal },
	{ "set_index_miss_handler", luaA_screen_set_index_miss_handler },
	{ "set_newindex_miss_handler", luaA_screen_set_newindex_miss_handler },
	/* Class methods */
	{ "count", luaA_screen_count },
	{ "get", luaA_screen_get_by_index },
	/* NOTE: "primary" is NOT a method - it's a property handled by __index.
	 * AwesomeWM's screen.primary returns the primary screen object directly,
	 * not a function. The __index metamethod (luaA_screen_module_index)
	 * handles this at lines 1345-1358. */
	{ "_viewports", luaA_screen_viewports },
	{ "fake_add", luaA_screen_fake_add },
	/* Module-level metamethods */
	{ "__index", luaA_screen_module_index },
	{ "__call", luaA_screen_call },
	{ NULL, NULL }
};

/** Setup screen class (AwesomeWM pattern)
 * This registers the screen class as a global "screen" table
 * that can be accessed from Lua code.
 */
void
screen_class_setup(lua_State *L)
{
	/* Setup screen class using AwesomeWM's class system */
	luaA_class_setup(L, &screen_class, "screen", NULL,
	                 NULL, /* allocator - screens are created from C, not Lua */
	                 NULL, /* collector - screens are managed by compositor */
	                 (lua_class_checker_t) screen_checker,
	                 luaA_class_index_miss_property, luaA_class_newindex_miss_property,
	                 screen_methods, screen_meta);

	/* Register screen properties (AwesomeWM pattern) */
	luaA_class_add_property(&screen_class, "geometry",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_screen_get_geometry_prop,
	                        NULL);
	luaA_class_add_property(&screen_class, "index",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_screen_get_index_prop,
	                        NULL);
	luaA_class_add_property(&screen_class, "_outputs",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_screen_get_outputs_prop,
	                        NULL);
	luaA_class_add_property(&screen_class, "_managed",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_screen_get_managed_prop,
	                        NULL);
	luaA_class_add_property(&screen_class, "workarea",
	                        NULL,
	                        (lua_class_propfunc_t) luaA_screen_get_workarea_prop,
	                        NULL);
	luaA_class_add_property(&screen_class, "name",
	                        (lua_class_propfunc_t) luaA_screen_set_name,
	                        (lua_class_propfunc_t) luaA_screen_get_name_prop,
	                        (lua_class_propfunc_t) luaA_screen_set_name);
}
