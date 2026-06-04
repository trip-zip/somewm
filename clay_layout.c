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
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_layer_shell_v1.h>

#include "clay_layout.h"
#include "somewm_types.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/screen.h"
#include "shadow.h"

/* Element types in layout results */
enum clay_element_type {
	CLAY_ELEM_CLIENT,
	CLAY_ELEM_DRAWIN,
	CLAY_ELEM_WORKAREA, /* Marker: computed bounds = workarea */
	CLAY_ELEM_WIDGET,   /* Widget element: bounds returned to Lua, not applied by C */
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
	/* For WORKAREA: padding to subtract from bounding box to get inner bounds */
	uint16_t pad_top, pad_right, pad_bottom, pad_left;
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

/* Dedicated context for widget layout passes (no screen association) */
static clay_screen_t widget_ctx = { 0 };

/* Solve-counting instrumentation. Each Clay_BeginLayout invocation
 * increments one of these counters keyed on the calling context. The
 * Lua side passes `source = "..."` in begin_layout opts; the two C-side
 * solve paths bump their counters directly. Read via
 * `_somewm_clay.get_solve_counts()`; reset via
 * `_somewm_clay.reset_solve_counts()`. Used to size the redraw-loop
 * load profile before any scheduler design decisions. */
typedef struct {
	uint64_t compose_screen;
	uint64_t preset;
	uint64_t wibox;
	uint64_t magnifier;
	uint64_t placement;
	uint64_t decoration;
	uint64_t layer_surface;
	uint64_t unknown;
	uint64_t total;
} clay_solve_counters_t;
static clay_solve_counters_t solve_counters = { 0 };

/* Dedicated context for per-client decoration sub-pass.
 * One Clay arena reused across every client; results are applied
 * synchronously inside clay_apply_client_decorations() so no result
 * storage is needed. Sized once on first use; geometry is rewritten
 * via Clay_SetLayoutDimensions() per call. */
static Clay_Context *decor_ctx = NULL;
static void *decor_arena_memory = NULL;

/* Tags carried in customData on the leaf elements of the decoration tree.
 * Walked after Clay_EndLayout() to dispatch positions to the correct
 * scene-graph node. Must be non-zero so customData != NULL is meaningful. */
enum {
	CDECOR_BORDER_TOP = 1,
	CDECOR_BORDER_BOTTOM,
	CDECOR_BORDER_LEFT,
	CDECOR_BORDER_RIGHT,
	CDECOR_TITLEBAR_TOP,
	CDECOR_TITLEBAR_RIGHT,
	CDECOR_TITLEBAR_BOTTOM,
	CDECOR_TITLEBAR_LEFT,
	CDECOR_SURFACE,
};

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
		config.padding = (Clay_Padding){
			.left = left, .right = right,
			.top = top, .bottom = bottom,
		};
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

	/* grow_max: cap GROW sizing at a maximum value */
	lua_getfield(L, idx, "grow_max");
	if (lua_isnumber(L, -1)) {
		float max = (float)lua_tonumber(L, -1);
		if (config.sizing.width.type == CLAY__SIZING_TYPE_GROW)
			config.sizing.width.size.minMax.max = max;
		if (config.sizing.height.type == CLAY__SIZING_TYPE_GROW)
			config.sizing.height.size.minMax.max = max;
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "align_x");
	if (lua_isstring(L, -1)) {
		const char *s = lua_tostring(L, -1);
		if (s[0] == 'c')
			config.childAlignment.x = CLAY_ALIGN_X_CENTER;
		else if (s[0] == 'r')
			config.childAlignment.x = CLAY_ALIGN_X_RIGHT;
		else
			config.childAlignment.x = CLAY_ALIGN_X_LEFT;
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "align_y");
	if (lua_isstring(L, -1)) {
		const char *s = lua_tostring(L, -1);
		if (s[0] == 'c')
			config.childAlignment.y = CLAY_ALIGN_Y_CENTER;
		else if (s[0] == 'b')
			config.childAlignment.y = CLAY_ALIGN_Y_BOTTOM;
		else
			config.childAlignment.y = CLAY_ALIGN_Y_TOP;
	}
	lua_pop(L, 1);

	return config;
}

/* Read floating-element configuration from a Lua table.
 *
 * When a child of a `layout.stack` container is emitted, the substrate
 * sets `attach_to_parent = true` along with optional `x_offset` /
 * `y_offset`. Clay then attaches this element to its layout parent at
 * the given offset, outside the parent's flow. Used by `clay.max`
 * (overlap), `wibox.layout.{stack, manual, grid}` (absolute coords),
 * and `clay.floating` (per-client screen coords).
 *
 * When `attach_to_parent` is unset, returns a zeroed struct: Clay
 * treats this as `CLAY_ATTACH_TO_NONE`, i.e. the element participates
 * in normal flow.
 */
static Clay_FloatingElementConfig
clay_read_floating_config(lua_State *L, int idx)
{
	Clay_FloatingElementConfig fc = { 0 };
	if (!lua_istable(L, idx))
		return fc;

	lua_getfield(L, idx, "attach_to_parent");
	bool floating = lua_toboolean(L, -1);
	lua_pop(L, 1);

	if (!floating)
		return fc;

	fc.attachTo = CLAY_ATTACH_TO_PARENT;
	fc.attachPoints = (Clay_FloatingAttachPoints){
		.element = CLAY_ATTACH_POINT_LEFT_TOP,
		.parent  = CLAY_ATTACH_POINT_LEFT_TOP,
	};

	lua_getfield(L, idx, "x_offset");
	if (lua_isnumber(L, -1))
		fc.offset.x = (float)lua_tonumber(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, idx, "y_offset");
	if (lua_isnumber(L, -1))
		fc.offset.y = (float)lua_tonumber(L, -1);
	lua_pop(L, 1);

	return fc;
}

/* _somewm_clay.begin_layout(screen_or_nil, width, height, opts?)
 * Pass nil as screen for widget layout passes (uses shared widget context). */
static int
luaA_clay_begin_layout(lua_State *L)
{
	float width = (float)luaL_checknumber(L, 2);
	float height = (float)luaL_checknumber(L, 3);

	clay_screen_t *cs;
	if (lua_isnil(L, 1) || lua_isnone(L, 1)) {
		/* Widget layout pass: use shared context */
		cs = &widget_ctx;
		if (!cs->ctx) {
			uint32_t mem_size = Clay_MinMemorySize();
			cs->arena_memory = malloc(mem_size);
			Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
				mem_size, cs->arena_memory);
			cs->ctx = Clay_Initialize(
				arena,
				(Clay_Dimensions){ 1920, 1080 },
				(Clay_ErrorHandler){ clay_error_handler, NULL });
			Clay_SetCurrentContext(cs->ctx);
			Clay_SetMeasureTextFunction(clay_measure_text, NULL);
		}
	} else {
		cs = clay_get_screen(L, 1);
	}
	active_screen = cs;

	cs->offset_x = 0;
	cs->offset_y = 0;

	const char *source = NULL;
	if (lua_istable(L, 4)) {
		lua_getfield(L, 4, "offset_x");
		if (lua_isnumber(L, -1))
			cs->offset_x = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 4, "offset_y");
		if (lua_isnumber(L, -1))
			cs->offset_y = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 4, "source");
		if (lua_isstring(L, -1))
			source = lua_tostring(L, -1);
		lua_pop(L, 1);
	}

	if (!source) {
		solve_counters.unknown++;
	} else if (strcmp(source, "compose_screen") == 0) {
		solve_counters.compose_screen++;
	} else if (strcmp(source, "preset") == 0) {
		solve_counters.preset++;
	} else if (strcmp(source, "wibox") == 0) {
		solve_counters.wibox++;
	} else if (strcmp(source, "magnifier") == 0) {
		solve_counters.magnifier++;
	} else if (strcmp(source, "placement") == 0) {
		solve_counters.placement++;
	} else {
		solve_counters.unknown++;
	}
	solve_counters.total++;

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
	Clay_FloatingElementConfig floating = clay_read_floating_config(L, 1);

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
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
	Clay_FloatingElementConfig floating = { 0 };
	if (lua_istable(L, 2)) {
		layout = clay_read_layout_config(L, 2);
		floating = clay_read_floating_config(L, 2);
	}

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
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
	Clay_FloatingElementConfig floating = { 0 };
	if (lua_istable(L, 2)) {
		layout = clay_read_layout_config(L, 2);
		floating = clay_read_floating_config(L, 2);
	}

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.widget_element(widget, config)
 * For widget layout passes. Stores a Lua widget ref. Bounds are returned
 * to Lua via end_layout_to_lua(), not applied by clay_apply_all(). */
static int
luaA_clay_widget_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: widget_element called outside begin/end_layout");

	luaL_checkany(L, 1);
	lua_pushvalue(L, 1);
	int ref = luaL_ref(L, LUA_REGISTRYINDEX);

	clay_results_ensure_cap(active_screen);
	clay_result_t *r = &active_screen->results[active_screen->results_count++];
	r->type = CLAY_ELEM_WIDGET;
	r->client = NULL;
	r->lua_ref = ref;
	r->x = r->y = r->w = r->h = 0;

	Clay_LayoutConfig layout = { 0 };
	Clay_FloatingElementConfig floating = { 0 };
	if (lua_istable(L, 2)) {
		layout = clay_read_layout_config(L, 2);
		floating = clay_read_floating_config(L, 2);
	}

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
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
	Clay_FloatingElementConfig floating = { 0 };
	if (lua_istable(L, 1)) {
		layout = clay_read_layout_config(L, 1);
		floating = clay_read_floating_config(L, 1);
	}

	/* Store padding so end_layout can return inner bounds as workarea */
	r->pad_top = layout.padding.top;
	r->pad_right = layout.padding.right;
	r->pad_bottom = layout.padding.bottom;
	r->pad_left = layout.padding.left;

	active_screen->element_id_counter++;
	Clay__OpenElementWithId(
		(Clay_ElementId){ .id = active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
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
			/* Return inner bounds (bounding box minus padding) as workarea */
			lua_newtable(L);
			lua_pushnumber(L, r->x + r->pad_left + active_screen->offset_x);
			lua_setfield(L, -2, "x");
			lua_pushnumber(L, r->y + r->pad_top + active_screen->offset_y);
			lua_setfield(L, -2, "y");
			lua_pushnumber(L, r->w - r->pad_left - r->pad_right);
			lua_setfield(L, -2, "width");
			lua_pushnumber(L, r->h - r->pad_top - r->pad_bottom);
			lua_setfield(L, -2, "height");
			active_screen = NULL;
			return 1;
		}
	}

	active_screen = NULL;
	return 0;
}

/* _somewm_clay.end_layout_to_lua()
 * Like end_layout(), but returns ALL results as a Lua table instead of
 * storing them C-side. Used by widget layout passes where the results
 * need to be converted to placement objects in Lua. */
static int
luaA_clay_end_layout_to_lua(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: end_layout_to_lua called without begin_layout");

	Clay_RenderCommandArray commands = Clay_EndLayout();

	/* Fill in computed positions from Clay render commands */
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

	/* Build Lua result table */
	lua_newtable(L);
	int result_idx = 1;
	clay_result_t *workarea_r = NULL;

	for (int j = 0; j < active_screen->results_count; j++) {
		clay_result_t *r = &active_screen->results[j];

		/* Workarea is metadata, not a placement; attach as a named field below. */
		if (r->type == CLAY_ELEM_WORKAREA) {
			workarea_r = r;
			continue;
		}

		lua_newtable(L);

		/* Push the widget from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, r->lua_ref);
		lua_setfield(L, -2, "widget");

		lua_pushnumber(L, r->x);
		lua_setfield(L, -2, "x");
		lua_pushnumber(L, r->y);
		lua_setfield(L, -2, "y");
		lua_pushnumber(L, r->w);
		lua_setfield(L, -2, "width");
		lua_pushnumber(L, r->h);
		lua_setfield(L, -2, "height");

		lua_rawseti(L, -2, result_idx++);

		luaL_unref(L, LUA_REGISTRYINDEX, r->lua_ref);
	}

	/* Surface workarea bounds as a named field so callers (somewm.placement)
	 * can use a workarea leaf as a position-query marker without going through
	 * screen mode. Mirrors the inner-bounds calc in luaA_clay_end_layout. */
	if (workarea_r) {
		lua_newtable(L);
		lua_pushnumber(L, workarea_r->x + workarea_r->pad_left
			+ active_screen->offset_x);
		lua_setfield(L, -2, "x");
		lua_pushnumber(L, workarea_r->y + workarea_r->pad_top
			+ active_screen->offset_y);
		lua_setfield(L, -2, "y");
		lua_pushnumber(L, workarea_r->w - workarea_r->pad_left
			- workarea_r->pad_right);
		lua_setfield(L, -2, "width");
		lua_pushnumber(L, workarea_r->h - workarea_r->pad_top
			- workarea_r->pad_bottom);
		lua_setfield(L, -2, "height");
		lua_setfield(L, -2, "workarea");
	}

	active_screen->results_count = 0;
	active_screen->has_pending = false;
	active_screen = NULL;
	return 1;
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

/* _somewm_clay.layer_exclusive(screen) -> top, right, bottom, left
 * Read the per-screen layer-shell exclusive zones populated by arrangelayers().
 * compose_screen applies these as workarea-container padding. */
static int
luaA_clay_layer_exclusive(lua_State *L)
{
	screen_t *s = luaA_checkscreen(L, 1);
	lua_pushinteger(L, s->layer_exclusive[0]);
	lua_pushinteger(L, s->layer_exclusive[1]);
	lua_pushinteger(L, s->layer_exclusive[2]);
	lua_pushinteger(L, s->layer_exclusive[3]);
	return 4;
}

void clay_apply_all(void);

/* _somewm_clay.apply_all() - apply pending Clay results synchronously.
 * Mirrors clay_apply_all() so layouts can flush results within the same
 * Lua tick, ensuring screen::arrange observers see the new geometry. */
static int
luaA_clay_apply_all(lua_State *L)
{
	(void)L;
	clay_apply_all();
	return 0;
}

/* _somewm_clay.get_solve_counts() - return per-source solve counters
 * since startup (or since the last reset_solve_counts() call). */
static int
luaA_clay_get_solve_counts(lua_State *L)
{
	lua_newtable(L);
#define PUSH(k) do { \
	lua_pushinteger(L, (lua_Integer)solve_counters.k); \
	lua_setfield(L, -2, #k); \
} while (0)
	PUSH(compose_screen);
	PUSH(preset);
	PUSH(wibox);
	PUSH(magnifier);
	PUSH(placement);
	PUSH(decoration);
	PUSH(layer_surface);
	PUSH(unknown);
	PUSH(total);
#undef PUSH
	return 1;
}

/* _somewm_clay.reset_solve_counts() - zero every counter. */
static int
luaA_clay_reset_solve_counts(lua_State *L)
{
	(void)L;
	memset(&solve_counters, 0, sizeof(solve_counters));
	return 0;
}

static const luaL_Reg clay_methods[] = {
	{ "begin_layout", luaA_clay_begin_layout },
	{ "open_container", luaA_clay_open_container },
	{ "close_container", luaA_clay_close_container },
	{ "client_element", luaA_clay_client_element },
	{ "drawin_element", luaA_clay_drawin_element },
	{ "widget_element", luaA_clay_widget_element },
	{ "workarea_element", luaA_clay_workarea_element },
	{ "end_layout", luaA_clay_end_layout },
	{ "end_layout_to_lua", luaA_clay_end_layout_to_lua },
	{ "set_screen_workarea", luaA_clay_set_screen_workarea },
	{ "layer_exclusive", luaA_clay_layer_exclusive },
	{ "apply_all", luaA_clay_apply_all },
	{ "get_solve_counts", luaA_clay_get_solve_counts },
	{ "reset_solve_counts", luaA_clay_reset_solve_counts },
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
				client_resize(r->client, geo, false, true);
			} else if (r->type == CLAY_ELEM_DRAWIN) {
				luaA_drawin_set_geometry(L, r->drawin,
				                         x, y, w, h);
			}
			/* CLAY_ELEM_WORKAREA and CLAY_ELEM_WIDGET: not applied by C */

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
	/* Called during hot-reload teardown or shutdown. The old Lua state is
	 * being abandoned (GC frozen, state leaked), so skip luaL_unref calls
	 * which would corrupt the registry free list. Just free C allocations. */
	for (int i = 0; i < screen_count; i++) {
		free(screens[i].results);
		free(screens[i].arena_memory);
	}
	memset(screens, 0, sizeof(screens));
	screen_count = 0;
	active_screen = NULL;

	/* Clean up widget context */
	free(widget_ctx.results);
	free(widget_ctx.arena_memory);
	memset(&widget_ctx, 0, sizeof(widget_ctx));

	/* Clean up decoration context */
	free(decor_arena_memory);
	decor_arena_memory = NULL;
	decor_ctx = NULL;

	/* Clear Clay's global context pointer so Clay_MinMemorySize() doesn't
	 * dereference the freed arena on the next clay_get_screen() call. */
	Clay_SetCurrentContext(NULL);
}

static inline Clay_SizingAxis
decor_grow(void)
{
	return (Clay_SizingAxis){ .type = CLAY__SIZING_TYPE_GROW };
}

static inline Clay_SizingAxis
decor_fixed(float v)
{
	return (Clay_SizingAxis){
		.type = CLAY__SIZING_TYPE_FIXED,
		.size.minMax = { v, v },
	};
}

static inline void
decor_open_container(uint32_t id, Clay_LayoutDirection dir)
{
	Clay__OpenElementWithId((Clay_ElementId){ .id = id });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = {
			.layoutDirection = dir,
			.sizing = { .width = decor_grow(), .height = decor_grow() },
		},
	});
}

static inline void
decor_leaf(intptr_t tag, Clay_SizingAxis w, Clay_SizingAxis h)
{
	Clay__OpenElementWithId((Clay_ElementId){ .id = (uint32_t)tag });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = { .sizing = { .width = w, .height = h } },
		.custom = { .customData = (void *)tag },
	});
	Clay__CloseElement();
}

/* Visibility was pre-set for all four titlebars; only writes position when
 * the titlebar is visible. */
static inline void
decor_apply_titlebar_pos(client_t *c, client_titlebar_t bar, int x, int y, bool fs)
{
	if (c->titlebar[bar].scene_buffer
	    && c->titlebar[bar].size > 0 && !fs) {
		wlr_scene_node_set_position(
			&c->titlebar[bar].scene_buffer->node, x, y);
	}
}

void
clay_apply_client_decorations(client_t *c, int *out_inner_w, int *out_inner_h)
{
	int geo_w = c->geometry.width;
	int geo_h = c->geometry.height;
	bool fs   = c->fullscreen;
	int  bw_i = (int)c->bw;
	uint16_t ts[CLIENT_TITLEBAR_COUNT] = {
		c->titlebar[CLIENT_TITLEBAR_TOP].size,
		c->titlebar[CLIENT_TITLEBAR_RIGHT].size,
		c->titlebar[CLIENT_TITLEBAR_BOTTOM].size,
		c->titlebar[CLIENT_TITLEBAR_LEFT].size,
	};
	float fbw = (float)c->bw;
	float ftt = fs ? 0.0f : (float)ts[0];
	float ftr = fs ? 0.0f : (float)ts[1];
	float ftb = fs ? 0.0f : (float)ts[2];
	float ftl = fs ? 0.0f : (float)ts[3];

	/* Pre-set titlebar visibility based on size + fullscreen so 0-sized
	 * titlebars (which Clay may cull from render commands) still get
	 * hidden. Mirrors the legacy client_update_titlebar_positions() invariant.
	 * Runs every call (outside the cache) so a late scene_buffer init
	 * gets enabled even when geometry hasn't changed. */
	for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP;
	     bar < CLIENT_TITLEBAR_COUNT; bar++) {
		if (c->titlebar[bar].scene_buffer) {
			bool visible = c->titlebar[bar].size > 0 && !fs;
			wlr_scene_node_set_enabled(
				&c->titlebar[bar].scene_buffer->node, visible);
		}
	}

	/* Decoration cache: skip the Clay solve and the scene-graph
	 * mutations when nothing the tree depends on has changed. The
	 * scene-graph positions from the last solve are still valid (no
	 * other path touches the border/titlebar/surface child positions
	 * inside c->scene). Border RECT sizes are also still correct. */
	if (c->decor_cache.valid
	    && c->decor_cache.width      == geo_w
	    && c->decor_cache.height     == geo_h
	    && c->decor_cache.bw         == bw_i
	    && c->decor_cache.fullscreen == fs
	    && memcmp(c->decor_cache.titlebar_size, ts, sizeof(ts)) == 0) {
		if (out_inner_w) *out_inner_w = c->decor_cache.inner_w;
		if (out_inner_h) *out_inner_h = c->decor_cache.inner_h;
		return;
	}

	if (!decor_ctx) {
		uint32_t mem_size = Clay_MinMemorySize();
		decor_arena_memory = malloc(mem_size);
		Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
			mem_size, decor_arena_memory);
		decor_ctx = Clay_Initialize(
			arena,
			(Clay_Dimensions){ (float)geo_w, (float)geo_h },
			(Clay_ErrorHandler){ clay_error_handler, NULL });
		Clay_SetCurrentContext(decor_ctx);
		Clay_SetMeasureTextFunction(clay_measure_text, NULL);
	}

	Clay_SetCurrentContext(decor_ctx);
	Clay_SetLayoutDimensions((Clay_Dimensions){ (float)geo_w, (float)geo_h });
	Clay_BeginLayout();
	solve_counters.decoration++;
	solve_counters.total++;

	uint32_t cid = 100; /* container ids; leaves use 1..9 (CDECOR_*) */

	decor_open_container(++cid, CLAY_TOP_TO_BOTTOM);                /* outer column */
		decor_leaf(CDECOR_BORDER_TOP, decor_grow(), decor_fixed(fbw));
		decor_open_container(++cid, CLAY_LEFT_TO_RIGHT);            /* middle row */
			decor_leaf(CDECOR_BORDER_LEFT, decor_fixed(fbw), decor_grow());
			decor_open_container(++cid, CLAY_TOP_TO_BOTTOM);        /* inner column */
				decor_leaf(CDECOR_TITLEBAR_TOP, decor_grow(), decor_fixed(ftt));
				decor_open_container(++cid, CLAY_LEFT_TO_RIGHT);    /* surface row */
					decor_leaf(CDECOR_TITLEBAR_LEFT,  decor_fixed(ftl), decor_grow());
					decor_leaf(CDECOR_SURFACE,        decor_grow(),     decor_grow());
					decor_leaf(CDECOR_TITLEBAR_RIGHT, decor_fixed(ftr), decor_grow());
				Clay__CloseElement();                               /* surface row */
				decor_leaf(CDECOR_TITLEBAR_BOTTOM, decor_grow(), decor_fixed(ftb));
			Clay__CloseElement();                                   /* inner column */
			decor_leaf(CDECOR_BORDER_RIGHT, decor_fixed(fbw), decor_grow());
		Clay__CloseElement();                                       /* middle row */
		decor_leaf(CDECOR_BORDER_BOTTOM, decor_grow(), decor_fixed(fbw));
	Clay__CloseElement();                                           /* outer column */

	Clay_RenderCommandArray commands = Clay_EndLayout();

	int inner_w = 0;
	int inner_h = 0;

	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;

		intptr_t tag = (intptr_t)cmd->renderData.custom.customData;
		int x = (int)cmd->boundingBox.x;
		int y = (int)cmd->boundingBox.y;
		int w = (int)cmd->boundingBox.width;
		int h = (int)cmd->boundingBox.height;

		switch (tag) {
		case CDECOR_BORDER_TOP:
			wlr_scene_rect_set_size(c->border[0], w, h);
			wlr_scene_node_set_position(&c->border[0]->node, x, y);
			break;
		case CDECOR_BORDER_BOTTOM:
			wlr_scene_rect_set_size(c->border[1], w, h);
			wlr_scene_node_set_position(&c->border[1]->node, x, y);
			break;
		case CDECOR_BORDER_LEFT:
			wlr_scene_rect_set_size(c->border[2], w, h);
			wlr_scene_node_set_position(&c->border[2]->node, x, y);
			break;
		case CDECOR_BORDER_RIGHT:
			wlr_scene_rect_set_size(c->border[3], w, h);
			wlr_scene_node_set_position(&c->border[3]->node, x, y);
			break;
		case CDECOR_TITLEBAR_TOP:
			decor_apply_titlebar_pos(c, CLIENT_TITLEBAR_TOP, x, y, fs);
			break;
		case CDECOR_TITLEBAR_RIGHT:
			decor_apply_titlebar_pos(c, CLIENT_TITLEBAR_RIGHT, x, y, fs);
			break;
		case CDECOR_TITLEBAR_BOTTOM:
			decor_apply_titlebar_pos(c, CLIENT_TITLEBAR_BOTTOM, x, y, fs);
			break;
		case CDECOR_TITLEBAR_LEFT:
			decor_apply_titlebar_pos(c, CLIENT_TITLEBAR_LEFT, x, y, fs);
			break;
		case CDECOR_SURFACE:
			wlr_scene_node_set_position(&c->scene_surface->node, x, y);
			inner_w = w;
			inner_h = h;
			break;
		}
	}

	int final_inner_w = inner_w < 1 ? 1 : inner_w;
	int final_inner_h = inner_h < 1 ? 1 : inner_h;
	if (out_inner_w) *out_inner_w = final_inner_w;
	if (out_inner_h) *out_inner_h = final_inner_h;

	/* Stamp the cache so the next call with the same inputs short-
	 * circuits at the head of the function. */
	c->decor_cache.width      = geo_w;
	c->decor_cache.height     = geo_h;
	c->decor_cache.bw         = bw_i;
	c->decor_cache.fullscreen = fs;
	memcpy(c->decor_cache.titlebar_size, ts, sizeof(ts));
	c->decor_cache.inner_w    = final_inner_w;
	c->decor_cache.inner_h    = final_inner_h;
	c->decor_cache.valid      = true;

	/* Shadow positioning. The 9-slice tree has signed offsets, directional
	 * clipping, and fill strips that don't fit Clay's flexbox model, so the
	 * specialized math stays in shadow.c. The call lives here so one C entry
	 * point owns the full per-client decoration sub-pass. */
	const shadow_config_t *shadow_config = shadow_get_effective_config(
		c->shadow_config, false);
	if (shadow_config && shadow_config->enabled) {
		if (c->shadow.tree) {
			shadow_update_geometry(&c->shadow, shadow_config,
				geo_w, geo_h);
		} else {
			shadow_create(c->scene, &c->shadow, shadow_config,
				geo_w, geo_h);
		}
	}
}

/* Layer-shell sub-pass context. One Clay arena reused for every layer
 * surface; geometry is rewritten via Clay_SetLayoutDimensions per call. */
static Clay_Context *layer_ctx = NULL;
static void *layer_arena_memory = NULL;

/* Phase 13: position a layer-shell surface via Clay instead of wlroots'
 * wlr_scene_layer_surface_v1_configure helper. Reads anchor / exclusive_zone
 * / margin / desired_size from layer_surface->current, builds a single-leaf
 * Clay tree inside `layout_box`, and applies the result by sending a
 * configure event and positioning the scene node directly. Subtracts the
 * exclusive zone from *usable_area per layer-shell protocol semantics.
 *
 * The caller picks `layout_box`: the *usable* area for surfaces with
 * exclusive_zone >= 0 (so they respect other exclusives), or the *full*
 * monitor area for exclusive_zone == -1 (which by spec ignores other
 * exclusives and extends to its anchored edges). */
void
clay_apply_layer_surface(LayerSurface *l, struct wlr_box layout_box,
                         struct wlr_box *usable_area)
{
	struct wlr_layer_surface_v1 *ls = l->layer_surface;
	const struct wlr_layer_surface_v1_state *state = &ls->current;

	uint32_t anchor         = state->anchor;
	int32_t  exclusive_zone = state->exclusive_zone;
	int32_t  m_top    = state->margin.top;
	int32_t  m_right  = state->margin.right;
	int32_t  m_bottom = state->margin.bottom;
	int32_t  m_left   = state->margin.left;
	int32_t  desired_w = (int32_t)state->desired_width;
	int32_t  desired_h = (int32_t)state->desired_height;

	bool a_left   = (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT)   != 0;
	bool a_right  = (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)  != 0;
	bool a_top    = (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP)    != 0;
	bool a_bottom = (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM) != 0;

	/* Per layer-shell spec: a surface anchored to opposite edges (or with
	 * desired_size == 0) takes the available area on that axis. Otherwise it
	 * uses desired_size. Available area subtracts both perpendicular margins
	 * because the surface is bounded between them. */
	int32_t target_w, target_h;
	if ((a_left && a_right) || desired_w == 0) {
		target_w = layout_box.width - m_left - m_right;
		if (target_w < 1) target_w = 1;
	} else {
		target_w = desired_w;
	}
	if ((a_top && a_bottom) || desired_h == 0) {
		target_h = layout_box.height - m_top - m_bottom;
		if (target_h < 1) target_h = 1;
	} else {
		target_h = desired_h;
	}

	/* Padding pushes only on the side(s) anchored without being opposite-
	 * anchored. Both opposite edges anchored = no padding (already accounted
	 * for in target size); one edge anchored = that side's margin pushes;
	 * neither edge anchored = surface centers, padding irrelevant. */
	int pad_l = (a_left   && !a_right)  ? m_left   : 0;
	int pad_r = (a_right  && !a_left)   ? m_right  : 0;
	int pad_t = (a_top    && !a_bottom) ? m_top    : 0;
	int pad_b = (a_bottom && !a_top)    ? m_bottom : 0;

	Clay_LayoutAlignmentX ax;
	if (a_left && !a_right)       ax = CLAY_ALIGN_X_LEFT;
	else if (a_right && !a_left)  ax = CLAY_ALIGN_X_RIGHT;
	else                          ax = CLAY_ALIGN_X_CENTER;
	Clay_LayoutAlignmentY ay;
	if (a_top && !a_bottom)       ay = CLAY_ALIGN_Y_TOP;
	else if (a_bottom && !a_top)  ay = CLAY_ALIGN_Y_BOTTOM;
	else                          ay = CLAY_ALIGN_Y_CENTER;

	if (!layer_ctx) {
		uint32_t mem_size = Clay_MinMemorySize();
		layer_arena_memory = malloc(mem_size);
		Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
			mem_size, layer_arena_memory);
		layer_ctx = Clay_Initialize(
			arena,
			(Clay_Dimensions){ (float)layout_box.width, (float)layout_box.height },
			(Clay_ErrorHandler){ clay_error_handler, NULL });
		Clay_SetCurrentContext(layer_ctx);
		Clay_SetMeasureTextFunction(clay_measure_text, NULL);
	}

	Clay_SetCurrentContext(layer_ctx);
	Clay_SetLayoutDimensions(
		(Clay_Dimensions){ (float)layout_box.width, (float)layout_box.height });
	Clay_BeginLayout();
	solve_counters.layer_surface++;
	solve_counters.total++;

	/* Outer container fills layout_box with padding/alignment from the anchor
	 * mask. One leaf with fixed size = target dimensions; we read its bounding
	 * box back as the chosen position. customData = 1 to identify it. */
	Clay__OpenElementWithId((Clay_ElementId){ .id = 1 });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = {
			.sizing = { .width = decor_grow(), .height = decor_grow() },
			.padding = (Clay_Padding){
				.left = (uint16_t)pad_l, .right = (uint16_t)pad_r,
				.top = (uint16_t)pad_t, .bottom = (uint16_t)pad_b,
			},
			.childAlignment = { .x = ax, .y = ay },
		},
	});
		Clay__OpenElementWithId((Clay_ElementId){ .id = 2 });
		Clay__ConfigureOpenElement((Clay_ElementDeclaration){
			.layout = {
				.sizing = {
					.width  = decor_fixed((float)target_w),
					.height = decor_fixed((float)target_h),
				},
			},
			.custom = { .customData = (void *)(intptr_t)1 },
		});
		Clay__CloseElement();
	Clay__CloseElement();

	Clay_RenderCommandArray commands = Clay_EndLayout();

	int x = 0, y = 0, w = target_w, h = target_h;
	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd =
			Clay_RenderCommandArray_Get(&commands, i);
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;
		if ((intptr_t)cmd->renderData.custom.customData != 1)
			continue;
		x = (int)cmd->boundingBox.x;
		y = (int)cmd->boundingBox.y;
		w = (int)cmd->boundingBox.width;
		h = (int)cmd->boundingBox.height;
		break;
	}

	wlr_layer_surface_v1_configure(ls, (uint32_t)w, (uint32_t)h);
	wlr_scene_node_set_position(&l->scene->node,
		layout_box.x + x, layout_box.y + y);

	/* Subtract exclusive zone from usable_area per layer-shell spec. The zone
	 * includes the surface size plus its perpendicular margins (top/bottom
	 * margins on a horizontal bar; left/right on a vertical sidebar). Applies
	 * only when the surface is anchored to exactly one edge or to one edge
	 * plus the two perpendicular edges (forming a bar/sidebar shape). */
	if (exclusive_zone > 0 && usable_area) {
		bool full_x = a_left == a_right;
		bool full_y = a_top == a_bottom;
		if (a_top && !a_bottom && full_x) {
			int delta = exclusive_zone + m_top + m_bottom;
			usable_area->y      += delta;
			usable_area->height -= delta;
		} else if (a_bottom && !a_top && full_x) {
			int delta = exclusive_zone + m_top + m_bottom;
			usable_area->height -= delta;
		} else if (a_left && !a_right && full_y) {
			int delta = exclusive_zone + m_left + m_right;
			usable_area->x     += delta;
			usable_area->width -= delta;
		} else if (a_right && !a_left && full_y) {
			int delta = exclusive_zone + m_left + m_right;
			usable_area->width -= delta;
		}
	}
}
