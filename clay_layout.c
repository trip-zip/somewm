/* clay_layout.c - Clay layout engine bindings for Lua
 *
 * Exposes Clay's flexbox layout computation to Lua via the _somewm_clay
 * global table. Each screen gets its own Clay_Context for independent
 * layout computation.
 *
 * Results are stored C-side and applied directly by clay_apply_all()
 * during the frame refresh cycle (Step 1.75). Supports both client
 * elements (tiled windows) and drawin elements (wibars/panels).
 *
 * Lua API:
 *   _somewm_clay.begin_layout(screen, width, height, opts?)
 *   _somewm_clay.open_container(config)
 *   _somewm_clay.close_container()
 *   _somewm_clay.client_element(client, config)
 *   _somewm_clay.drawin_element(drawin, config)
 *   _somewm_clay.end_layout()
 */

#define CLAY_IMPLEMENTATION
#include "third_party/clay.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdlib.h>
#include <string.h>

#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/screen.h"

/* Element types in layout results */
enum clay_element_type {
	CLAY_ELEM_CLIENT,
	CLAY_ELEM_DRAWIN,
	CLAY_ELEM_WORKAREA, /* Marker: computed bounds = workarea */
};

/* Layout result for a single element */
typedef struct {
	enum clay_element_type type;
	int lua_ref;        /* Lua registry ref (prevents GC) */
	union {
		client_t *client;
		drawin_t *drawin;
	};
	float x, y, w, h;
} clay_result_t;

/* Per-screen Clay state */
typedef struct {
	Clay_Context *ctx;
	void *arena_memory;
	int screen_ref;             /* Lua registry ref to screen object */
	uint32_t element_id_counter;
	/* Layout metadata from begin_layout opts */
	float offset_x, offset_y;
	/* Result storage for C-side apply */
	clay_result_t *results;
	int results_count;
	int results_cap;
	bool has_pending;
} clay_screen_t;

#define MAX_SCREENS 16
static clay_screen_t screens[MAX_SCREENS];
static int screen_count = 0;
static clay_screen_t *active_screen = NULL;

/* No-op text measurement - we don't use text elements for layout */
static Clay_Dimensions
clay_measure_text(Clay_StringSlice text, Clay_TextElementConfig *config,
                  void *userData)
{
	(void)text;
	(void)config;
	(void)userData;
	return (Clay_Dimensions){ 0, 0 };
}

static void
clay_error_handler(Clay_ErrorData error)
{
	fprintf(stderr, "[clay] error: %.*s\n", error.errorText.length,
	        error.errorText.chars);
}

/* Ensure the results array has room for at least one more entry */
static void
clay_results_ensure_cap(clay_screen_t *cs)
{
	if (cs->results_count < cs->results_cap)
		return;
	int new_cap = cs->results_cap ? cs->results_cap * 2 : 16;
	cs->results = realloc(cs->results, new_cap * sizeof(clay_result_t));
	cs->results_cap = new_cap;
}

/* Find or create a per-screen Clay context. */
static clay_screen_t *
clay_get_screen(lua_State *L, int idx)
{
	lua_pushvalue(L, idx);

	for (int i = 0; i < screen_count; i++) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, screens[i].screen_ref);
		if (lua_rawequal(L, -1, -2)) {
			lua_pop(L, 2);
			return &screens[i];
		}
		lua_pop(L, 1);
	}

	if (screen_count >= MAX_SCREENS) {
		lua_pop(L, 1);
		luaL_error(L, "clay: too many screens (max %d)", MAX_SCREENS);
		return NULL;
	}

	clay_screen_t *cs = &screens[screen_count++];
	memset(cs, 0, sizeof(*cs));

	cs->screen_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	uint32_t mem_size = Clay_MinMemorySize();
	cs->arena_memory = malloc(mem_size);
	Clay_Arena arena =
		Clay_CreateArenaWithCapacityAndMemory(mem_size, cs->arena_memory);
	cs->ctx = Clay_Initialize(
		arena,
		(Clay_Dimensions){ 1920, 1080 },
		(Clay_ErrorHandler){ clay_error_handler, NULL });

	Clay_SetCurrentContext(cs->ctx);
	Clay_SetMeasureTextFunction(clay_measure_text, NULL);

	return cs;
}

/* Read sizing config from a Lua table at stack index `idx` */
static Clay_LayoutConfig
clay_read_layout_config(lua_State *L, int idx)
{
	Clay_LayoutConfig config = { 0 };

	if (!lua_istable(L, idx))
		return config;

	lua_getfield(L, idx, "direction");
	if (lua_isstring(L, -1)) {
		const char *dir = lua_tostring(L, -1);
		if (dir[0] == 'c')
			config.layoutDirection = CLAY_TOP_TO_BOTTOM;
		else
			config.layoutDirection = CLAY_LEFT_TO_RIGHT;
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "gap");
	if (lua_isnumber(L, -1))
		config.childGap = (uint16_t)lua_tonumber(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, idx, "padding");
	if (lua_istable(L, -1)) {
		lua_rawgeti(L, -1, 1);
		uint16_t top = lua_isnumber(L, -1) ? (uint16_t)lua_tonumber(L, -1) : 0;
		lua_pop(L, 1);
		lua_rawgeti(L, -1, 2);
		uint16_t right = lua_isnumber(L, -1) ? (uint16_t)lua_tonumber(L, -1) : 0;
		lua_pop(L, 1);
		lua_rawgeti(L, -1, 3);
		uint16_t bottom = lua_isnumber(L, -1) ? (uint16_t)lua_tonumber(L, -1) : 0;
		lua_pop(L, 1);
		lua_rawgeti(L, -1, 4);
		uint16_t left = lua_isnumber(L, -1) ? (uint16_t)lua_tonumber(L, -1) : 0;
		lua_pop(L, 1);
		config.padding = (Clay_Padding){ top, right, bottom, left };
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "width_percent");
	if (lua_isnumber(L, -1)) {
		config.sizing.width = (Clay_SizingAxis){
			.size = { .percent = (float)lua_tonumber(L, -1) / 100.0f },
			.type = CLAY__SIZING_TYPE_PERCENT
		};
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "width_fixed");
	if (lua_isnumber(L, -1)) {
		float val = (float)lua_tonumber(L, -1);
		config.sizing.width = (Clay_SizingAxis){
			.size = { .minMax = { val, val } },
			.type = CLAY__SIZING_TYPE_FIXED
		};
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "height_percent");
	if (lua_isnumber(L, -1)) {
		config.sizing.height = (Clay_SizingAxis){
			.size = { .percent = (float)lua_tonumber(L, -1) / 100.0f },
			.type = CLAY__SIZING_TYPE_PERCENT
		};
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "height_fixed");
	if (lua_isnumber(L, -1)) {
		float val = (float)lua_tonumber(L, -1);
		config.sizing.height = (Clay_SizingAxis){
			.size = { .minMax = { val, val } },
			.type = CLAY__SIZING_TYPE_FIXED
		};
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "grow");
	{
		int has_grow = lua_isnil(L, -1) || lua_toboolean(L, -1);
		if (has_grow) {
			if (config.sizing.width.type == CLAY__SIZING_TYPE_FIT) {
				config.sizing.width = (Clay_SizingAxis){
					.type = CLAY__SIZING_TYPE_GROW
				};
			}
			if (config.sizing.height.type == CLAY__SIZING_TYPE_FIT) {
				config.sizing.height = (Clay_SizingAxis){
					.type = CLAY__SIZING_TYPE_GROW
				};
			}
		}
	}
	lua_pop(L, 1);

	return config;
}

/* _somewm_clay.begin_layout(screen, width, height, opts?) */
static int
luaA_clay_begin_layout(lua_State *L)
{
	luaL_checkany(L, 1);
	float width = (float)luaL_checknumber(L, 2);
	float height = (float)luaL_checknumber(L, 3);

	clay_screen_t *cs = clay_get_screen(L, 1);
	active_screen = cs;

	cs->offset_x = 0;
	cs->offset_y = 0;

	if (lua_istable(L, 4)) {
		lua_getfield(L, 4, "offset_x");
		if (lua_isnumber(L, -1))
			cs->offset_x = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 4, "offset_y");
		if (lua_isnumber(L, -1))
			cs->offset_y = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);
	}

	/* Release leftover refs from previous unconsumed layout */
	for (int i = 0; i < cs->results_count; i++)
		luaL_unref(L, LUA_REGISTRYINDEX, cs->results[i].lua_ref);
	cs->results_count = 0;
	cs->has_pending = false;

	Clay_SetCurrentContext(cs->ctx);
	Clay_SetLayoutDimensions((Clay_Dimensions){ width, height });
	Clay_BeginLayout();
	cs->element_id_counter = 0;

	return 0;
}

/* _somewm_clay.open_container(config_table) */
static int
luaA_clay_open_container(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: open_container called outside begin/end_layout");

	Clay_LayoutConfig layout = clay_read_layout_config(L, 1);

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
	});

	return 0;
}

/* _somewm_clay.close_container() */
static int
luaA_clay_close_container(lua_State *L)
{
	(void)L;
	if (!active_screen)
		return luaL_error(L, "clay: close_container called outside begin/end_layout");

	Clay__CloseElement();
	return 0;
}

/* _somewm_clay.client_element(client, config) */
static int
luaA_clay_client_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: client_element called outside begin/end_layout");

	client_t *c = luaA_checkudata(L, 1, &client_class);
	lua_pushvalue(L, 1);
	int ref = luaL_ref(L, LUA_REGISTRYINDEX);

	clay_results_ensure_cap(active_screen);
	clay_result_t *r = &active_screen->results[active_screen->results_count++];
	r->type = CLAY_ELEM_CLIENT;
	r->client = c;
	r->lua_ref = ref;
	r->x = r->y = r->w = r->h = 0;

	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 2))
		layout = clay_read_layout_config(L, 2);

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.drawin_element(drawin, config) */
static int
luaA_clay_drawin_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: drawin_element called outside begin/end_layout");

	drawin_t *d = luaA_checkudata(L, 1, &drawin_class);
	lua_pushvalue(L, 1);
	int ref = luaL_ref(L, LUA_REGISTRYINDEX);

	clay_results_ensure_cap(active_screen);
	clay_result_t *r = &active_screen->results[active_screen->results_count++];
	r->type = CLAY_ELEM_DRAWIN;
	r->drawin = d;
	r->lua_ref = ref;
	r->x = r->y = r->w = r->h = 0;

	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 2))
		layout = clay_read_layout_config(L, 2);

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.workarea_element(config)
 * Marker element whose computed bounds represent the workarea.
 * No Lua ref needed - it's not a real object. */
static int
luaA_clay_workarea_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: workarea_element called outside begin/end_layout");

	clay_results_ensure_cap(active_screen);
	clay_result_t *r = &active_screen->results[active_screen->results_count++];
	r->type = CLAY_ELEM_WORKAREA;
	r->client = NULL;
	r->lua_ref = LUA_NOREF;
	r->x = r->y = r->w = r->h = 0;

	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 1))
		layout = clay_read_layout_config(L, 1);

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.end_layout() */
static int
luaA_clay_end_layout(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: end_layout called without begin_layout");

	Clay_RenderCommandArray commands = Clay_EndLayout();

	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd =
			Clay_RenderCommandArray_Get(&commands, i);

		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;

		int idx = (int)(intptr_t)cmd->renderData.custom.customData;
		if (idx <= 0 || idx > active_screen->results_count)
			continue;

		clay_result_t *r = &active_screen->results[idx - 1];
		r->x = cmd->boundingBox.x;
		r->y = cmd->boundingBox.y;
		r->w = cmd->boundingBox.width;
		r->h = cmd->boundingBox.height;
	}

	active_screen->has_pending = true;

	/* If a workarea element was present, return its bounds as a table.
	 * This lets compose_screen() read the workarea without waiting
	 * for clay_apply_all(). */
	for (int j = 0; j < active_screen->results_count; j++) {
		clay_result_t *r = &active_screen->results[j];
		if (r->type == CLAY_ELEM_WORKAREA) {
			lua_newtable(L);
			lua_pushnumber(L, r->x + active_screen->offset_x);
			lua_setfield(L, -2, "x");
			lua_pushnumber(L, r->y + active_screen->offset_y);
			lua_setfield(L, -2, "y");
			lua_pushnumber(L, r->w);
			lua_setfield(L, -2, "width");
			lua_pushnumber(L, r->h);
			lua_setfield(L, -2, "height");
			active_screen = NULL;
			return 1;
		}
	}

	active_screen = NULL;
	return 0;
}

/* _somewm_clay.set_screen_workarea(screen, x, y, width, height)
 * Update a screen's workarea from Clay's computed bounds. */
static int
luaA_clay_set_screen_workarea(lua_State *L)
{
	screen_t *s = luaA_checkscreen(L, 1);
	struct wlr_box wa = {
		.x      = (int)luaL_checknumber(L, 2),
		.y      = (int)luaL_checknumber(L, 3),
		.width  = (int)luaL_checknumber(L, 4),
		.height = (int)luaL_checknumber(L, 5),
	};
	screen_set_workarea(L, s, &wa);
	return 0;
}

static const luaL_Reg clay_methods[] = {
	{ "begin_layout", luaA_clay_begin_layout },
	{ "open_container", luaA_clay_open_container },
	{ "close_container", luaA_clay_close_container },
	{ "client_element", luaA_clay_client_element },
	{ "drawin_element", luaA_clay_drawin_element },
	{ "workarea_element", luaA_clay_workarea_element },
	{ "end_layout", luaA_clay_end_layout },
	{ "set_screen_workarea", luaA_clay_set_screen_workarea },
	{ NULL, NULL }
};

void
luaA_clay_setup(lua_State *L)
{
	lua_newtable(L);
	luaL_setfuncs(L, clay_methods, 0);
	lua_setglobal(L, "_somewm_clay");
}

/* Apply pending Clay layout results to client/drawin geometry.
 * Called from some_refresh() at Step 1.75. */
void
clay_apply_all(void)
{
	lua_State *L = globalconf_get_lua_State();

	for (int i = 0; i < screen_count; i++) {
		clay_screen_t *cs = &screens[i];
		if (!cs->has_pending)
			continue;

		for (int j = 0; j < cs->results_count; j++) {
			clay_result_t *r = &cs->results[j];

			int x = (int)(r->x + cs->offset_x);
			int y = (int)(r->y + cs->offset_y);
			int w = (int)r->w;
			int h = (int)r->h;

			if (r->type == CLAY_ELEM_CLIENT) {
				int bw2 = r->client->border_width * 2;
				area_t geo = {
					.x = x,
					.y = y,
					.width  = MAX(1, w - bw2),
					.height = MAX(1, h - bw2),
				};
				client_resize_do(r->client, geo, true);
			} else if (r->type == CLAY_ELEM_DRAWIN) {
				luaA_drawin_set_geometry(L, r->drawin,
				                         x, y, w, h);
			}
			/* CLAY_ELEM_WORKAREA: informational only, skip */

			if (r->lua_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, r->lua_ref);
		}
		cs->results_count = 0;
		cs->has_pending = false;
	}
}

void
clay_cleanup(void)
{
	lua_State *L = globalconf_get_lua_State();
	for (int i = 0; i < screen_count; i++) {
		for (int j = 0; j < screens[i].results_count; j++)
			luaL_unref(L, LUA_REGISTRYINDEX,
			           screens[i].results[j].lua_ref);
		free(screens[i].results);
		free(screens[i].arena_memory);
		memset(&screens[i], 0, sizeof(clay_screen_t));
	}
	screen_count = 0;
	active_screen = NULL;
}
