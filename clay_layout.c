/* clay_layout.c - Clay layout engine bindings for Lua
 *
 * Exposes Clay's flexbox layout computation to Lua via the _somewm_clay
 * global table. Each screen gets its own Clay_Context for independent
 * layout computation.
 *
 * Phase 3A: Lua builds tree, Clay computes, results returned to Lua.
 * Phase 3B: Results stored C-side, applied directly by clay_apply_all()
 *           during the frame refresh cycle (Step 1.75).
 *
 * Lua API:
 *   _somewm_clay.begin_layout(screen, width, height, opts?)
 *   _somewm_clay.open_container(config)
 *   _somewm_clay.close_container()
 *   _somewm_clay.client_element(client, config)
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

/* Layout result for a single element */
typedef struct {
	client_t *client;
	int client_ref;     /* Lua registry ref (prevents GC) */
	float x, y, w, h;
} clay_result_t;

/* Per-screen Clay state */
typedef struct {
	Clay_Context *ctx;
	void *arena_memory;
	int screen_ref;             /* Lua registry ref to screen object */
	uint32_t element_id_counter;
	/* Layout metadata from begin_layout opts */
	float offset_x, offset_y;  /* Workarea origin */
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

/* Find or create a per-screen Clay context.
 * The screen Lua object at stack index `idx` is used as the key. */
static clay_screen_t *
clay_get_screen(lua_State *L, int idx)
{
	/* Push the screen value for comparison */
	lua_pushvalue(L, idx);

	/* Search existing screens */
	for (int i = 0; i < screen_count; i++) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, screens[i].screen_ref);
		if (lua_rawequal(L, -1, -2)) {
			lua_pop(L, 2);
			return &screens[i];
		}
		lua_pop(L, 1);
	}

	/* Create new screen context */
	if (screen_count >= MAX_SCREENS) {
		lua_pop(L, 1);
		luaL_error(L, "clay: too many screens (max %d)", MAX_SCREENS);
		return NULL;
	}

	clay_screen_t *cs = &screens[screen_count++];
	memset(cs, 0, sizeof(*cs));

	/* Store Lua screen reference */
	cs->screen_ref = luaL_ref(L, LUA_REGISTRYINDEX); /* pops the value */

	/* Initialize Clay context */
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

	/* Direction: "row" or "column" */
	lua_getfield(L, idx, "direction");
	if (lua_isstring(L, -1)) {
		const char *dir = lua_tostring(L, -1);
		if (dir[0] == 'c')
			config.layoutDirection = CLAY_TOP_TO_BOTTOM;
		else
			config.layoutDirection = CLAY_LEFT_TO_RIGHT;
	}
	lua_pop(L, 1);

	/* Gap between children */
	lua_getfield(L, idx, "gap");
	if (lua_isnumber(L, -1))
		config.childGap = (uint16_t)lua_tonumber(L, -1);
	lua_pop(L, 1);

	/* Padding */
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

	/* Width sizing */
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

	/* Height sizing */
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

	/* Grow: default to GROW on any axis not explicitly sized.
	 * Layout elements should fill available space since clients have no
	 * intrinsic content size (FIT would collapse to 0). */
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

/* _somewm_clay.begin_layout(screen, width, height, opts?)
 * opts is an optional table: { offset_x, offset_y } */
static int
luaA_clay_begin_layout(lua_State *L)
{
	luaL_checkany(L, 1); /* screen object */
	float width = (float)luaL_checknumber(L, 2);
	float height = (float)luaL_checknumber(L, 3);

	clay_screen_t *cs = clay_get_screen(L, 1);
	active_screen = cs;

	/* Reset layout metadata */
	cs->offset_x = 0;
	cs->offset_y = 0;

	/* Read optional opts table */
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

	/* Release any leftover refs from a previous layout pass that
	 * wasn't consumed (e.g., screen removed between layout and apply) */
	for (int i = 0; i < cs->results_count; i++)
		luaL_unref(L, LUA_REGISTRYINDEX, cs->results[i].client_ref);
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

/* _somewm_clay.client_element(client_userdata, config_table)
 * Store client_t pointer and Lua ref for C-side geometry application.
 * Uses CUSTOM render command type to identify client elements in output. */
static int
luaA_clay_client_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: client_element called outside begin/end_layout");

	/* Arg 1: client object - extract C pointer and store Lua ref */
	client_t *c = luaA_checkudata(L, 1, &client_class);
	lua_pushvalue(L, 1);
	int ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Store client + ref for result collection in end_layout */
	clay_results_ensure_cap(active_screen);
	clay_result_t *r = &active_screen->results[active_screen->results_count++];
	r->client = c;
	r->client_ref = ref;
	r->x = r->y = r->w = r->h = 0; /* filled by end_layout */

	/* Arg 2: optional config table */
	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 2))
		layout = clay_read_layout_config(L, 2);

	/* Use results_count as the custom data key (1-based index into results) */
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

/* _somewm_clay.end_layout()
 * Compute layout, store results C-side for clay_apply_all(). */
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

		/* idx is 1-based, results array is 0-based */
		clay_result_t *r = &active_screen->results[idx - 1];
		r->x = cmd->boundingBox.x;
		r->y = cmd->boundingBox.y;
		r->w = cmd->boundingBox.width;
		r->h = cmd->boundingBox.height;
	}

	active_screen->has_pending = true;
	active_screen = NULL;
	return 0;
}

static const luaL_Reg clay_methods[] = {
	{ "begin_layout", luaA_clay_begin_layout },
	{ "open_container", luaA_clay_open_container },
	{ "close_container", luaA_clay_close_container },
	{ "client_element", luaA_clay_client_element },
	{ "end_layout", luaA_clay_end_layout },
	{ NULL, NULL }
};

void
luaA_clay_setup(lua_State *L)
{
	lua_newtable(L);
	luaL_setfuncs(L, clay_methods, 0);
	lua_setglobal(L, "_somewm_clay");
}

/* Apply pending Clay layout results to client geometry.
 * Called from some_refresh() at Step 1.75 (after Lua layout, before
 * drawin_refresh/client_refresh). */
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

			int bw2 = r->client->border_width * 2;
			area_t geo = {
				.x      = (int)(r->x + cs->offset_x),
				.y      = (int)(r->y + cs->offset_y),
				.width  = MAX(1, (int)r->w - bw2),
				.height = MAX(1, (int)r->h - bw2),
			};
			client_resize_do(r->client, geo, true);

			luaL_unref(L, LUA_REGISTRYINDEX, r->client_ref);
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
		/* Release any pending result refs */
		for (int j = 0; j < screens[i].results_count; j++)
			luaL_unref(L, LUA_REGISTRYINDEX,
			           screens[i].results[j].client_ref);
		free(screens[i].results);
		free(screens[i].arena_memory);
		memset(&screens[i], 0, sizeof(clay_screen_t));
	}
	screen_count = 0;
	active_screen = NULL;
}
