#include "output.h"
#include "screen.h"
#include "signal.h"
#include "luaa.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "../somewm_api.h"
#include "common/util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_output.h>
#include <wlr/backend/headless.h>
#include <wlr/backend/wayland.h>
#include <wlr/util/log.h>

/* AwesomeWM-compatible output class */
lua_class_t output_class;
LUA_OBJECT_FUNCS(output_class, output_t, output)

/* External reference to monitor list */
extern struct wl_list mons;

/* Global array of output objects - stores Lua registry references */
static int *output_refs = NULL;
static size_t output_count = 0;
static size_t output_capacity = 0;

/* Forward declarations */
static int luaA_output_index(lua_State *L);
static int luaA_output_newindex(lua_State *L);
static int luaA_output_tostring(lua_State *L);
static int luaA_output_gc(lua_State *L);
static int luaA_output_connect_signal(lua_State *L);
static int luaA_output_disconnect_signal(lua_State *L);
static int luaA_output_emit_signal(lua_State *L);
static int luaA_output_count(lua_State *L);
static int luaA_output_module_index(lua_State *L);
static int luaA_output_call(lua_State *L);
static int luaA_output_get_by_name(lua_State *L);
static bool output_checker(output_t *o);

/* ========================================================================
 * Output object management
 * ======================================================================== */

output_t *
luaA_output_new(lua_State *L, Monitor *m)
{
	output_t *o;
	int ref;

	o = output_new(L);
	lua_pushvalue(L, -1);
	luaA_object_ref(L, -1);

	o->monitor = m;
	o->valid = true;

	/* Store reference in registry to prevent GC and allow retrieval */
	lua_pushvalue(L, -1);
	ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Add reference to global output array */
	if (output_count >= output_capacity) {
		size_t new_cap = output_capacity == 0 ? 4 : output_capacity * 2;
		int *new_refs = realloc(output_refs, new_cap * sizeof(int));
		if (!new_refs) {
			fprintf(stderr, "somewm: failed to allocate output array\n");
			luaL_unref(L, LUA_REGISTRYINDEX, ref);
			luaA_object_unref(L, o);
			lua_pop(L, 1);
			return NULL;
		}
		output_refs = new_refs;
		output_capacity = new_cap;
	}
	output_refs[output_count++] = ref;

	return o;
}

/* Counter for generating virtual output names */
static int virtual_output_counter = 0;

output_t *
luaA_output_new_virtual(lua_State *L, const char *name)
{
	output_t *o;
	int ref;
	char generated_name[64];

	o = output_new(L);
	lua_pushvalue(L, -1);
	luaA_object_ref(L, -1);

	o->monitor = NULL;
	o->valid = true;
	o->is_virtual = true;

	/* Generate name if not provided */
	if (name) {
		o->vname = strdup(name);
	} else {
		snprintf(generated_name, sizeof(generated_name), "virtual-%d",
			++virtual_output_counter);
		o->vname = strdup(generated_name);
	}

	/* Store reference in registry */
	lua_pushvalue(L, -1);
	ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Add reference to global output array */
	if (output_count >= output_capacity) {
		size_t new_cap = output_capacity == 0 ? 4 : output_capacity * 2;
		int *new_refs = realloc(output_refs, new_cap * sizeof(int));
		if (!new_refs) {
			fprintf(stderr, "somewm: failed to allocate output array\n");
			luaL_unref(L, LUA_REGISTRYINDEX, ref);
			free(o->vname);
			o->vname = NULL;
			luaA_object_unref(L, o);
			lua_pop(L, 1);
			return NULL;
		}
		output_refs = new_refs;
		output_capacity = new_cap;
	}
	output_refs[output_count++] = ref;

	return o;
}

void
luaA_output_push(lua_State *L, output_t *o)
{
	size_t i;

	if (!o) {
		lua_pushnil(L);
		return;
	}

	for (i = 0; i < output_count; i++) {
		output_t *candidate;
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[i]);
		candidate = (output_t *)lua_touserdata(L, -1);
		if (candidate == o)
			return;  /* Found - userdata is on stack */
		lua_pop(L, 1);
	}

	lua_pushnil(L);
}

void
luaA_output_invalidate(lua_State *L, output_t *o)
{
	size_t i;

	if (!o)
		return;

	o->valid = false;
	o->monitor = NULL;

	/* Remove from global array */
	for (i = 0; i < output_count; i++) {
		output_t *candidate;
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[i]);
		candidate = (output_t *)lua_touserdata(L, -1);
		lua_pop(L, 1);

		if (candidate == o) {
			luaL_unref(L, LUA_REGISTRYINDEX, output_refs[i]);
			/* Shift remaining refs down */
			memmove(&output_refs[i], &output_refs[i + 1],
				(output_count - i - 1) * sizeof(int));
			output_count--;
			break;
		}
	}

	/* Unref from object registry so it can be GC'd */
	luaA_object_unref(L, o);
}

/* ========================================================================
 * Instance property getters (read-only)
 * ======================================================================== */

static int
luaA_output_get_name(lua_State *L, output_t *o)
{
	if (o && o->valid && o->vname)
		lua_pushstring(L, o->vname);
	else if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushstring(L, o->monitor->wlr_output->name);
	else
		lua_pushnil(L);
	return 1;
}

static int
luaA_output_get_description(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output
			&& o->monitor->wlr_output->description)
		lua_pushstring(L, o->monitor->wlr_output->description);
	else
		lua_pushnil(L);
	return 1;
}

static int
luaA_output_get_make(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output
			&& o->monitor->wlr_output->make)
		lua_pushstring(L, o->monitor->wlr_output->make);
	else
		lua_pushnil(L);
	return 1;
}

static int
luaA_output_get_model(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output
			&& o->monitor->wlr_output->model)
		lua_pushstring(L, o->monitor->wlr_output->model);
	else
		lua_pushnil(L);
	return 1;
}

static int
luaA_output_get_serial(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output
			&& o->monitor->wlr_output->serial)
		lua_pushstring(L, o->monitor->wlr_output->serial);
	else
		lua_pushnil(L);
	return 1;
}

static int
luaA_output_get_physical_width(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushinteger(L, o->monitor->wlr_output->phys_width);
	else
		lua_pushinteger(L, 0);
	return 1;
}

static int
luaA_output_get_physical_height(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushinteger(L, o->monitor->wlr_output->phys_height);
	else
		lua_pushinteger(L, 0);
	return 1;
}

static int
luaA_output_get_modes(lua_State *L, output_t *o)
{
	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output) {
		lua_newtable(L);
		return 1;
	}

	struct wlr_output *wlr_output = o->monitor->wlr_output;
	struct wlr_output_mode *mode;
	int i = 1;

	lua_newtable(L);

	wl_list_for_each(mode, &wlr_output->modes, link) {
		lua_newtable(L);

		lua_pushinteger(L, mode->width);
		lua_setfield(L, -2, "width");

		lua_pushinteger(L, mode->height);
		lua_setfield(L, -2, "height");

		lua_pushinteger(L, mode->refresh);
		lua_setfield(L, -2, "refresh");

		lua_pushboolean(L, mode->preferred);
		lua_setfield(L, -2, "preferred");

		lua_rawseti(L, -2, i++);
	}

	return 1;
}

static int
luaA_output_get_current_mode(lua_State *L, output_t *o)
{
	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output
			|| !o->monitor->wlr_output->enabled) {
		lua_pushnil(L);
		return 1;
	}

	struct wlr_output *wlr_output = o->monitor->wlr_output;
	struct wlr_output_mode *mode = wlr_output->current_mode;

	if (!mode) {
		lua_pushnil(L);
		return 1;
	}

	lua_newtable(L);

	lua_pushinteger(L, mode->width);
	lua_setfield(L, -2, "width");

	lua_pushinteger(L, mode->height);
	lua_setfield(L, -2, "height");

	lua_pushinteger(L, mode->refresh);
	lua_setfield(L, -2, "refresh");

	lua_pushboolean(L, mode->preferred);
	lua_setfield(L, -2, "preferred");

	return 1;
}

static int
luaA_output_get_screen(lua_State *L, output_t *o)
{
	screen_t *s = NULL;

	if (!o || !o->valid) {
		lua_pushnil(L);
		return 1;
	}

	/* Real output: find screen by monitor */
	if (o->monitor)
		s = luaA_screen_get_by_monitor(L, o->monitor);

	/* Virtual output: find screen by virtual_output pointer */
	if (!s && o->is_virtual)
		s = luaA_screen_get_by_virtual_output(L, o);

	if (s)
		luaA_object_push(L, s);
	else
		lua_pushnil(L);
	return 1;
}

static int
luaA_output_get_valid(lua_State *L, output_t *o)
{
	lua_pushboolean(L, o && o->valid);
	return 1;
}

static int
luaA_output_get_virtual(lua_State *L, output_t *o)
{
	if (!o || !o->valid) {
		lua_pushboolean(L, false);
		return 1;
	}

	/* Fake screen outputs (no monitor/wlr_output) are always virtual */
	if (o->is_virtual) {
		lua_pushboolean(L, true);
		return 1;
	}

	/* Check wlr_output backend type for headless/nested */
	if (o->monitor && o->monitor->wlr_output) {
		struct wlr_output *wlr_output = o->monitor->wlr_output;
		bool is_virtual = wlr_output_is_headless(wlr_output)
				|| wlr_output_is_wl(wlr_output);
		lua_pushboolean(L, is_virtual);
	} else {
		lua_pushboolean(L, false);
	}
	return 1;
}

/* ========================================================================
 * Instance property getters (read-write properties)
 * ======================================================================== */

static int
luaA_output_get_enabled(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushboolean(L, o->monitor->wlr_output->enabled);
	else
		lua_pushboolean(L, false);
	return 1;
}

static int
luaA_output_get_scale(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushnumber(L, o->monitor->wlr_output->scale);
	else
		lua_pushnumber(L, 1.0);
	return 1;
}

static int
luaA_output_get_transform(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushinteger(L, o->monitor->wlr_output->transform);
	else
		lua_pushinteger(L, WL_OUTPUT_TRANSFORM_NORMAL);
	return 1;
}

static int
luaA_output_get_position(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor) {
		lua_newtable(L);
		lua_pushinteger(L, o->monitor->m.x);
		lua_setfield(L, -2, "x");
		lua_pushinteger(L, o->monitor->m.y);
		lua_setfield(L, -2, "y");
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int
luaA_output_get_adaptive_sync(lua_State *L, output_t *o)
{
	if (o && o->valid && o->monitor && o->monitor->wlr_output)
		lua_pushboolean(L, o->monitor->wlr_output->adaptive_sync_status
				!= WLR_OUTPUT_ADAPTIVE_SYNC_DISABLED);
	else
		lua_pushboolean(L, false);
	return 1;
}

/* ========================================================================
 * Instance property setters
 * ======================================================================== */

/* Forward declaration - defined in somewm.c */
extern void updatemons(struct wl_listener *listener, void *data);

static int
luaA_output_set_enabled(lua_State *L, output_t *o)
{
	bool enabled;
	struct wlr_output_state state;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output)
		return 0;

	enabled = lua_toboolean(L, -1);

	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, enabled);

	/* If enabling, also set preferred mode (required for output to work) */
	if (enabled && !o->monitor->wlr_output->enabled) {
		struct wlr_output_mode *preferred = wlr_output_preferred_mode(o->monitor->wlr_output);
		if (preferred)
			wlr_output_state_set_mode(&state, preferred);
	}

	if (wlr_output_commit_state(o->monitor->wlr_output, &state))
		luaA_object_emit_signal(L, 1, "property::enabled", 0);
	else
		wlr_log(WLR_INFO, "output: failed to commit enabled state for %s",
			o->monitor->wlr_output->name);

	wlr_output_state_finish(&state);
	updatemons(NULL, NULL);
	return 0;
}

/* Apply scale change to an output's wlr_output and emit signals on both
 * the output object and its associated screen object (if any).
 * `ud_idx` is the stack index of the output userdata (for signal emission). */
void
luaA_output_apply_scale(lua_State *L, output_t *o, int ud_idx, float scale)
{
	struct wlr_output_state state;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output)
		return;

	wlr_output_state_init(&state);
	wlr_output_state_set_scale(&state, scale);

	if (wlr_output_commit_state(o->monitor->wlr_output, &state)) {
		luaA_object_emit_signal(L, ud_idx, "property::scale", 0);

		/* Also emit property::scale on the associated screen */
		screen_t *screen = luaA_screen_get_by_monitor(L, o->monitor);
		if (screen) {
			luaA_object_push(L, screen);
			luaA_object_emit_signal(L, -1, "property::scale", 0);
			lua_pop(L, 1);
		}
	} else {
		wlr_log(WLR_INFO, "output: failed to commit scale for %s",
			o->monitor->wlr_output->name);
	}

	wlr_output_state_finish(&state);
	updatemons(NULL, NULL);
}

static int
luaA_output_set_scale(lua_State *L, output_t *o)
{
	float scale;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output)
		return 0;

	scale = luaL_checknumber(L, -1);
	if (scale < 0.1 || scale > 10.0) {
		luaL_error(L, "scale must be between 0.1 and 10.0, got %f", scale);
		return 0;
	}

	luaA_output_apply_scale(L, o, 1, scale);
	return 0;
}

/* Parse transform string to wl_output_transform enum value.
 * Returns -1 on failure. */
static int
parse_transform_string(const char *str)
{
	if (strcmp(str, "normal") == 0)    return WL_OUTPUT_TRANSFORM_NORMAL;
	if (strcmp(str, "90") == 0)        return WL_OUTPUT_TRANSFORM_90;
	if (strcmp(str, "180") == 0)       return WL_OUTPUT_TRANSFORM_180;
	if (strcmp(str, "270") == 0)       return WL_OUTPUT_TRANSFORM_270;
	if (strcmp(str, "flipped") == 0)   return WL_OUTPUT_TRANSFORM_FLIPPED;
	if (strcmp(str, "flipped-90") == 0 || strcmp(str, "flipped_90") == 0)
		return WL_OUTPUT_TRANSFORM_FLIPPED_90;
	if (strcmp(str, "flipped-180") == 0 || strcmp(str, "flipped_180") == 0)
		return WL_OUTPUT_TRANSFORM_FLIPPED_180;
	if (strcmp(str, "flipped-270") == 0 || strcmp(str, "flipped_270") == 0)
		return WL_OUTPUT_TRANSFORM_FLIPPED_270;
	return -1;
}

static int
luaA_output_set_transform(lua_State *L, output_t *o)
{
	int transform;
	struct wlr_output_state state;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output)
		return 0;

	if (lua_type(L, -1) == LUA_TSTRING) {
		const char *str = lua_tostring(L, -1);
		transform = parse_transform_string(str);
		if (transform < 0) {
			luaL_error(L, "invalid transform string '%s' (expected: normal, 90, 180, 270, flipped, flipped-90, flipped-180, flipped-270)", str);
			return 0;
		}
	} else {
		transform = luaL_checkinteger(L, -1);
		if (transform < 0 || transform > 7) {
			luaL_error(L, "transform must be 0-7 (wl_output_transform), got %d", transform);
			return 0;
		}
	}

	wlr_output_state_init(&state);
	wlr_output_state_set_transform(&state, transform);

	if (wlr_output_commit_state(o->monitor->wlr_output, &state))
		luaA_object_emit_signal(L, 1, "property::transform", 0);
	else
		wlr_log(WLR_INFO, "output: failed to commit transform for %s",
			o->monitor->wlr_output->name);

	wlr_output_state_finish(&state);
	updatemons(NULL, NULL);
	return 0;
}

static int
luaA_output_set_mode(lua_State *L, output_t *o)
{
	int width, height, refresh = 0;
	struct wlr_output_mode *mode, *best = NULL;
	struct wlr_output_state state;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output)
		return 0;

	luaL_checktype(L, -1, LUA_TTABLE);

	lua_getfield(L, -1, "width");
	width = luaL_checkinteger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, -1, "height");
	height = luaL_checkinteger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, -1, "refresh");
	if (!lua_isnil(L, -1))
		refresh = lua_tointeger(L, -1);
	lua_pop(L, 1);

	/* Find best matching mode */
	wl_list_for_each(mode, &o->monitor->wlr_output->modes, link) {
		if (mode->width == width && mode->height == height) {
			if (refresh == 0 || mode->refresh == refresh) {
				best = mode;
				break;
			}
			/* Pick closest refresh rate */
			if (!best || abs(mode->refresh - refresh) < abs(best->refresh - refresh))
				best = mode;
		}
	}

	if (!best) {
		luaL_error(L, "no matching mode found for %dx%d@%d", width, height, refresh);
		return 0;
	}

	wlr_output_state_init(&state);
	wlr_output_state_set_mode(&state, best);

	if (wlr_output_commit_state(o->monitor->wlr_output, &state))
		luaA_object_emit_signal(L, 1, "property::mode", 0);
	else
		wlr_log(WLR_INFO, "output: failed to commit mode for %s",
			o->monitor->wlr_output->name);

	wlr_output_state_finish(&state);
	updatemons(NULL, NULL);
	return 0;
}

static int
luaA_output_set_position(lua_State *L, output_t *o)
{
	int x, y;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output
			|| !o->monitor->wlr_output->enabled)
		return 0;

	luaL_checktype(L, -1, LUA_TTABLE);

	lua_getfield(L, -1, "x");
	x = luaL_checkinteger(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, -1, "y");
	y = luaL_checkinteger(L, -1);
	lua_pop(L, 1);

	/* Use wlr_output_layout to set position */
	extern struct wlr_output_layout *output_layout;
	wlr_output_layout_add(output_layout, o->monitor->wlr_output, x, y);

	luaA_object_emit_signal(L, 1, "property::position", 0);
	updatemons(NULL, NULL);
	return 0;
}

static int
luaA_output_set_adaptive_sync(lua_State *L, output_t *o)
{
	bool enabled;
	struct wlr_output_state state;

	if (!o || !o->valid || !o->monitor || !o->monitor->wlr_output)
		return 0;

	enabled = lua_toboolean(L, -1);

	wlr_output_state_init(&state);
	wlr_output_state_set_adaptive_sync_enabled(&state, enabled);

	if (wlr_output_commit_state(o->monitor->wlr_output, &state))
		luaA_object_emit_signal(L, 1, "property::adaptive_sync", 0);
	else
		wlr_log(WLR_INFO, "output: failed to commit adaptive_sync for %s",
			o->monitor->wlr_output->name);

	wlr_output_state_finish(&state);
	return 0;
}

/* ========================================================================
 * Instance metamethods
 * ======================================================================== */

static int
luaA_output_index(lua_State *L)
{
	const char *key;
	output_t *o;

	o = (output_t *)luaA_checkudata(L, 1, &output_class);
	if (!o)
		return 0;
	key = luaL_checkstring(L, 2);

	/* Properties */
	if (strcmp(key, "name") == 0) return luaA_output_get_name(L, o);
	if (strcmp(key, "description") == 0) return luaA_output_get_description(L, o);
	if (strcmp(key, "make") == 0) return luaA_output_get_make(L, o);
	if (strcmp(key, "model") == 0) return luaA_output_get_model(L, o);
	if (strcmp(key, "serial") == 0) return luaA_output_get_serial(L, o);
	if (strcmp(key, "physical_width") == 0) return luaA_output_get_physical_width(L, o);
	if (strcmp(key, "physical_height") == 0) return luaA_output_get_physical_height(L, o);
	if (strcmp(key, "modes") == 0) return luaA_output_get_modes(L, o);
	if (strcmp(key, "current_mode") == 0) return luaA_output_get_current_mode(L, o);
	if (strcmp(key, "screen") == 0) return luaA_output_get_screen(L, o);
	if (strcmp(key, "valid") == 0) return luaA_output_get_valid(L, o);
	if (strcmp(key, "virtual") == 0) return luaA_output_get_virtual(L, o);
	if (strcmp(key, "enabled") == 0) return luaA_output_get_enabled(L, o);
	if (strcmp(key, "scale") == 0) return luaA_output_get_scale(L, o);
	if (strcmp(key, "transform") == 0) return luaA_output_get_transform(L, o);
	if (strcmp(key, "position") == 0) return luaA_output_get_position(L, o);
	if (strcmp(key, "adaptive_sync") == 0) return luaA_output_get_adaptive_sync(L, o);

	/* Check for _private table */
	if (strcmp(key, "_private") == 0) {
		luaA_getuservalue(L, 1);
		return 1;
	}

	/* Check methods in metatable */
	lua_getmetatable(L, 1);
	if (!lua_isnil(L, -1)) {
		lua_getfield(L, -1, key);
		if (!lua_isnil(L, -1))
			return 1;
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	/* Index miss handler */
	if (output_class.index_miss_handler != LUA_REFNIL) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_class.index_miss_handler);
		lua_pushvalue(L, 1);
		lua_pushvalue(L, 2);
		lua_call(L, 2, 1);
		return 1;
	}

	/* Fallback: environment table */
	luaA_getuservalue(L, 1);
	lua_getfield(L, -1, key);
	return 1;
}

static int
luaA_output_newindex(lua_State *L)
{
	output_t *o = (output_t *)luaA_checkudata(L, 1, &output_class);
	const char *key = luaL_checkstring(L, 2);

	if (strcmp(key, "enabled") == 0) {
		lua_pushvalue(L, 3);
		luaA_output_set_enabled(L, o);
		lua_pop(L, 1);
		return 0;
	}
	if (strcmp(key, "scale") == 0) {
		lua_pushvalue(L, 3);
		luaA_output_set_scale(L, o);
		lua_pop(L, 1);
		return 0;
	}
	if (strcmp(key, "transform") == 0) {
		lua_pushvalue(L, 3);
		luaA_output_set_transform(L, o);
		lua_pop(L, 1);
		return 0;
	}
	if (strcmp(key, "mode") == 0) {
		lua_pushvalue(L, 3);
		luaA_output_set_mode(L, o);
		lua_pop(L, 1);
		return 0;
	}
	if (strcmp(key, "position") == 0) {
		lua_pushvalue(L, 3);
		luaA_output_set_position(L, o);
		lua_pop(L, 1);
		return 0;
	}
	if (strcmp(key, "adaptive_sync") == 0) {
		lua_pushvalue(L, 3);
		luaA_output_set_adaptive_sync(L, o);
		lua_pop(L, 1);
		return 0;
	}

	/* Newindex miss handler */
	if (output_class.newindex_miss_handler != LUA_REFNIL) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_class.newindex_miss_handler);
		lua_pushvalue(L, 1);
		lua_pushvalue(L, 2);
		lua_pushvalue(L, 3);
		lua_call(L, 3, 0);
		return 0;
	}

	/* Fallback: store in environment table */
	luaA_getuservalue(L, 1);
	lua_pushvalue(L, 2);
	lua_pushvalue(L, 3);
	lua_rawset(L, -3);
	lua_pop(L, 1);
	return 0;
}

static int
luaA_output_tostring(lua_State *L)
{
	output_t *o = (output_t *)luaA_checkudata(L, 1, &output_class);
	const char *name = "disconnected";
	if (o && o->valid && o->vname)
		name = o->vname;
	else if (o && o->valid && o->monitor && o->monitor->wlr_output)
		name = o->monitor->wlr_output->name;
	lua_pushfstring(L, "output{name=%s, valid=%s}", name,
			o && o->valid ? "true" : "false");
	return 1;
}

static int
luaA_output_gc(lua_State *L)
{
	output_t *o = (output_t *)lua_touserdata(L, 1);
	if (o) {
		signal_array_wipe(&o->signals);
		free(o->vname);
		o->vname = NULL;
	}
	return 0;
}

static int
luaA_output_connect_signal(lua_State *L)
{
	output_t *o = (output_t *)luaA_checkudata(L, 1, &output_class);
	(void)o;
	const char *name = luaL_checkstring(L, 2);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	luaA_object_connect_signal_from_stack(L, 1, name, 3);
	return 0;
}

static int
luaA_output_disconnect_signal(lua_State *L)
{
	(void)luaA_checkudata(L, 1, &output_class);
	luaL_checkstring(L, 2);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	luaA_object_disconnect_signal_from_stack(L, 1, luaL_checkstring(L, 2), 3);
	return 0;
}

static int
luaA_output_emit_signal(lua_State *L)
{
	(void)luaA_checkudata(L, 1, &output_class);
	luaA_object_emit_signal(L, 1, luaL_checkstring(L, 2), lua_gettop(L) - 2);
	return 0;
}

/* ========================================================================
 * Class methods (for the global "output" table)
 * ======================================================================== */

static int
luaA_output_count(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)output_count);
	return 1;
}

static int
luaA_output_get_by_name(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	size_t i;

	for (i = 0; i < output_count; i++) {
		output_t *o;
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[i]);
		o = (output_t *)lua_touserdata(L, -1);
		if (o && o->valid) {
			if (o->vname && strcmp(o->vname, name) == 0)
				return 1;
			if (o->monitor && o->monitor->wlr_output
					&& strcmp(o->monitor->wlr_output->name, name) == 0)
				return 1;
		}
		lua_pop(L, 1);
	}

	lua_pushnil(L);
	return 1;
}

static int
luaA_output_module_index(lua_State *L)
{
	/* Numeric index: output[1] */
	if (lua_isnumber(L, 2)) {
		int index = lua_tointeger(L, 2);
		if (index < 1 || index > (int)output_count) {
			lua_pushnil(L);
			return 1;
		}
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[index - 1]);
		return 1;
	}

	/* Output object as key: output[output_obj] -> output_obj */
	if (lua_isuserdata(L, 2)) {
		output_t *o = (output_t *)luaA_toudata(L, 2, &output_class);
		if (o && o->valid) {
			lua_pushvalue(L, 2);
			return 1;
		}
		lua_pushnil(L);
		return 1;
	}

	/* Method/property lookup */
	lua_pushvalue(L, 2);
	lua_rawget(L, 1);
	return 1;
}

static int
luaA_output_call(lua_State *L)
{
	int index;
	output_t *prev;

	/* Direct indexing: output(number) */
	if (lua_gettop(L) >= 2 && lua_isnumber(L, 2) && !lua_isnil(L, 2)) {
		index = luaL_checkinteger(L, 2);
		if (index < 1 || index > (int)output_count) {
			lua_pushnil(L);
			return 1;
		}
		lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[index - 1]);
		return 1;
	}

	/* Iterator mode: L[3] is the control variable (previous output or nil) */
	if (lua_isnoneornil(L, 3)) {
		index = 0;
	} else {
		prev = (output_t *)luaA_toudata(L, 3, &output_class);
		if (!prev) {
			lua_pushnil(L);
			return 1;
		}
		/* Find index of previous output */
		index = -1;
		for (size_t i = 0; i < output_count; i++) {
			output_t *o;
			lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[i]);
			o = (output_t *)lua_touserdata(L, -1);
			lua_pop(L, 1);
			if (o == prev) {
				index = (int)i;
				break;
			}
		}
		if (index == -1) {
			lua_pushnil(L);
			return 1;
		}
		index++;  /* Move to next */
	}

	if (index >= (int)output_count) {
		lua_pushnil(L);
		return 1;
	}

	lua_rawgeti(L, LUA_REGISTRYINDEX, output_refs[index]);
	return 1;
}

/* ========================================================================
 * Class checker
 * ======================================================================== */

static bool
output_checker(output_t *o)
{
	(void)o;
	return true;
}

/* ========================================================================
 * Class registration
 * ======================================================================== */

/* Instance metamethods */
static const luaL_Reg output_meta[] = {
	{ "__index", luaA_output_index },
	{ "__newindex", luaA_output_newindex },
	{ "__tostring", luaA_output_tostring },
	{ "__gc", luaA_output_gc },
	{ "connect_signal", luaA_output_connect_signal },
	{ "disconnect_signal", luaA_output_disconnect_signal },
	{ "emit_signal", luaA_output_emit_signal },
	{ NULL, NULL }
};

/* Class methods (for the global output table) */
static const luaL_Reg output_methods[] = {
	LUA_CLASS_METHODS(output)
	{ "count", luaA_output_count },
	{ "get_by_name", luaA_output_get_by_name },
	{ "__index", luaA_output_module_index },
	{ "__call", luaA_output_call },
	{ NULL, NULL }
};

void
output_class_setup(lua_State *L)
{
	luaA_class_setup(L, &output_class, "output", NULL,
			 NULL,  /* allocator - outputs are created from C */
			 NULL,  /* collector - outputs are managed by compositor */
			 (lua_class_checker_t) output_checker,
			 luaA_class_index_miss_property,
			 luaA_class_newindex_miss_property,
			 output_methods, output_meta);

	/* Register properties */
	luaA_class_add_property(&output_class, "name",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_name,
			NULL);
	luaA_class_add_property(&output_class, "description",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_description,
			NULL);
	luaA_class_add_property(&output_class, "make",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_make,
			NULL);
	luaA_class_add_property(&output_class, "model",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_model,
			NULL);
	luaA_class_add_property(&output_class, "serial",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_serial,
			NULL);
	luaA_class_add_property(&output_class, "physical_width",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_physical_width,
			NULL);
	luaA_class_add_property(&output_class, "physical_height",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_physical_height,
			NULL);
	luaA_class_add_property(&output_class, "modes",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_modes,
			NULL);
	luaA_class_add_property(&output_class, "current_mode",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_current_mode,
			NULL);
	luaA_class_add_property(&output_class, "screen",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_screen,
			NULL);
	luaA_class_add_property(&output_class, "virtual",
			NULL,
			(lua_class_propfunc_t) luaA_output_get_virtual,
			NULL);
	luaA_class_add_property(&output_class, "enabled",
			(lua_class_propfunc_t) luaA_output_set_enabled,
			(lua_class_propfunc_t) luaA_output_get_enabled,
			(lua_class_propfunc_t) luaA_output_set_enabled);
	luaA_class_add_property(&output_class, "scale",
			(lua_class_propfunc_t) luaA_output_set_scale,
			(lua_class_propfunc_t) luaA_output_get_scale,
			(lua_class_propfunc_t) luaA_output_set_scale);
	luaA_class_add_property(&output_class, "transform",
			(lua_class_propfunc_t) luaA_output_set_transform,
			(lua_class_propfunc_t) luaA_output_get_transform,
			(lua_class_propfunc_t) luaA_output_set_transform);
	luaA_class_add_property(&output_class, "mode",
			(lua_class_propfunc_t) luaA_output_set_mode,
			(lua_class_propfunc_t) luaA_output_get_current_mode,
			(lua_class_propfunc_t) luaA_output_set_mode);
	luaA_class_add_property(&output_class, "position",
			(lua_class_propfunc_t) luaA_output_set_position,
			(lua_class_propfunc_t) luaA_output_get_position,
			(lua_class_propfunc_t) luaA_output_set_position);
	luaA_class_add_property(&output_class, "adaptive_sync",
			(lua_class_propfunc_t) luaA_output_set_adaptive_sync,
			(lua_class_propfunc_t) luaA_output_get_adaptive_sync,
			(lua_class_propfunc_t) luaA_output_set_adaptive_sync);
}
