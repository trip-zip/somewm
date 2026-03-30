/* clay_layout.c - Clay layout engine bindings for Lua
 *
 * Exposes Clay's flexbox layout computation to Lua via the _somewm_clay
 * global table. Each screen gets its own Clay_Context for independent
 * layout computation. Lua builds a layout tree per screen, Clay computes
 * positions, and results are returned as a table of client placements.
 *
 * Lua API:
 *   _somewm_clay.begin_layout(screen, width, height)
 *   _somewm_clay.open_container(config)
 *   _somewm_clay.close_container()
 *   _somewm_clay.client_element(client, config)
 *   _somewm_clay.end_layout() -> {{client, x, y, width, height}, ...}
 */

#define CLAY_IMPLEMENTATION
#include "third_party/clay.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdlib.h>
#include <string.h>

/* Per-screen Clay state */
typedef struct {
	Clay_Context *ctx;
	void *arena_memory;
	int screen_ref; /* Lua registry ref to screen object */
	uint32_t element_id_counter;
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

/* _somewm_clay.begin_layout(screen, width, height) */
static int
luaA_clay_begin_layout(lua_State *L)
{
	luaL_checkany(L, 1); /* screen object */
	float width = (float)luaL_checknumber(L, 2);
	float height = (float)luaL_checknumber(L, 3);

	clay_screen_t *cs = clay_get_screen(L, 1);
	active_screen = cs;

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
 * Store the Lua registry index so we can push the client back in results.
 * Uses CUSTOM render command type to identify client elements in output. */
static int
luaA_clay_client_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: client_element called outside begin/end_layout");

	/* Arg 1: client (any Lua value - we store a ref) */
	luaL_checkany(L, 1);
	lua_pushvalue(L, 1);
	int ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Arg 2: optional config table */
	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 2))
		layout = clay_read_layout_config(L, 2);

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.custom = { .customData = (void *)(intptr_t)ref },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.end_layout()
 * Compute layout and return results as {{client, x, y, width, height}, ...} */
static int
luaA_clay_end_layout(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: end_layout called without begin_layout");

	Clay_RenderCommandArray commands = Clay_EndLayout();

	lua_newtable(L);
	int result_idx = 1;

	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd =
			Clay_RenderCommandArray_Get(&commands, i);

		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;

		int ref = (int)(intptr_t)cmd->renderData.custom.customData;
		if (ref == 0)
			continue;

		lua_newtable(L);

		lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
		lua_setfield(L, -2, "client");

		lua_pushnumber(L, cmd->boundingBox.x);
		lua_setfield(L, -2, "x");
		lua_pushnumber(L, cmd->boundingBox.y);
		lua_setfield(L, -2, "y");
		lua_pushnumber(L, cmd->boundingBox.width);
		lua_setfield(L, -2, "width");
		lua_pushnumber(L, cmd->boundingBox.height);
		lua_setfield(L, -2, "height");

		lua_rawseti(L, -2, result_idx++);

		luaL_unref(L, LUA_REGISTRYINDEX, ref);
	}

	active_screen = NULL;
	return 1;
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

void
clay_cleanup(void)
{
	for (int i = 0; i < screen_count; i++) {
		/* Clay contexts are allocated within the arena memory block.
		 * Freeing the arena memory is sufficient cleanup. */
		free(screens[i].arena_memory);
		screens[i].arena_memory = NULL;
		screens[i].ctx = NULL;
		/* Note: screen_ref is a Lua registry ref. If the Lua state is
		 * being torn down (hot-reload), it will be collected. If not,
		 * we should unref - but clay_cleanup is only called during
		 * teardown, so this is safe. */
	}
	screen_count = 0;
	active_screen = NULL;
}
