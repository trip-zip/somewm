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
#include "somewm.h"            /* scene, layers[], cursor externs */
#include "globalconf.h"        /* globalconf.button_state */
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/drawable.h"  /* drawable_create_buffer_from_data, cairo */
#include "objects/screen.h"
#include "shadow.h"
#include "color.h"            /* color_init_from_string for the border config */

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
	float dim_w, dim_h;         /* solve dimensions (debug overlay size) */
	/* Result storage for C-side apply */
	clay_result_t *results;
	int results_count;
	int results_cap;
	bool has_pending;
	/* Debug-view render target: a per-screen scene buffer the Clay debug
	 * commands are drawn into. The cairo surface is cached and reused across
	 * frames (the buffer helper copies the pixels), recreated on size change. */
	struct wlr_scene_buffer *debug_overlay;
	cairo_surface_t *debug_surface;
	int debug_w, debug_h;
	/* Per-solve debug flags (set in begin_layout, read in end_layout).
	 * debug_compose_solve: this solve is the screen-composition solve (merged/
	 * compose_screen), the only source that drives the debug overlay -- so
	 * placement / magnifier solves sharing this context never touch it.
	 * debug_only_solve: a pointer-motion overlay refresh; skip has_pending so
	 * clay_apply_all does not defer-apply its (unchanged) geometry. */
	bool debug_compose_solve;
	bool debug_only_solve;
	/* debug_render: this solve is the one the debug view renders (debug on +
	 * composition source). When set, elements get readable string ids drawn
	 * from name_pool, a per-solve scratch buffer reset each begin_layout and
	 * valid until the next one (covers EndLayout's debug pass). Off otherwise,
	 * so normal solves pay no string-hashing cost. */
	bool debug_render;
	/* read_anchor_refs: this solve has registered popups, so a widget element may
	 * carry a stable clay_ref a popup attaches to by id. Only then does
	 * clay_open_element read cfg.clay_ref, so popup-free solves pay no per-element
	 * getfield (the common case). */
	bool read_anchor_refs;
	char *name_pool;
	int name_pool_len;
} clay_screen_t;

#define MAX_SCREENS 16
static clay_screen_t screens[MAX_SCREENS];
static int screen_count = 0;
static clay_screen_t *active_screen = NULL;

/* Set by client_open() to the current framed client's 1-based result index
 * while its frame subtree (border leaves + titlebar nodes + surface,
 * built in Lua) is being emitted, so frame_box() / titlebar children route their
 * boxes into that client's merged_frame. Zero outside a client_open/close pair. */
static int g_frame_client_idx = 0;

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
	uint64_t merged;
	uint64_t wibox;
	uint64_t magnifier;
	uint64_t placement;
	uint64_t decoration;  /* per-client fallback frame solve (kept name = proof metric) */
	uint64_t layer_surface;
	uint64_t unknown;
	uint64_t total;
} clay_solve_counters_t;
static clay_solve_counters_t solve_counters = { 0 };

/* Clay debug-view state. clay_debug_enabled drives Clay's per-context
 * debugModeEnabled (set on the per-screen contexts in begin_layout), the
 * pointer feed, and the overlay renderer. Clay can self-disable from inside
 * Clay_EndLayout (the panel's close button), so end_layout reads the flag back
 * and syncs. clay_debug_dirty marks a pending pointer-driven overlay re-solve;
 * clay_debug_reflow_pending marks a pending full arrange after a self-disable
 * (so windows reflow back to full width). The resolver is a Lua callback that
 * rebuilds + re-solves a screen (Clay can't rebuild its tree alone). */
static bool clay_debug_enabled = false;
static bool clay_debug_dirty = false;
static bool clay_debug_reflow_pending = false;
static int  clay_debug_resolver_ref = LUA_NOREF;
static struct wlr_scene_tree *clay_debug_tree = NULL;
static cairo_t *clay_debug_scratch_cr = NULL;
static cairo_surface_t *clay_debug_scratch_surface = NULL;

/* Tree == scene assertion mode. Once the Gate phase wires it up, clay_apply_all()
 * (Gate 3) and the clay.tree IPC walker (Gate 4) consult this to decide whether a
 * mismatch between the solved Clay box and the assigned scene geometry is silent
 * (OFF), logged (WARN), or fatal (ABORT). Read once at startup from
 * SOMEWM_TREE_ASSERT; default WARN. Not consulted yet. */
typedef enum {
	CLAY_TREE_ASSERT_OFF,
	CLAY_TREE_ASSERT_WARN,
	CLAY_TREE_ASSERT_ABORT,
} clay_tree_assert_mode_t;

static clay_tree_assert_mode_t clay_tree_assert_mode = CLAY_TREE_ASSERT_WARN;

void
clay_tree_assert_init(void)
{
	const char *v = getenv("SOMEWM_TREE_ASSERT");
	if (!a_strcasecmp(v, "off"))
		clay_tree_assert_mode = CLAY_TREE_ASSERT_OFF;
	else if (!a_strcasecmp(v, "abort"))
		clay_tree_assert_mode = CLAY_TREE_ASSERT_ABORT;
	else
		clay_tree_assert_mode = CLAY_TREE_ASSERT_WARN;
}

/* Dedicated context for per-client frame sub-pass.
 * One Clay arena reused across every client; results are applied
 * synchronously inside clay_apply_client_frame() so no result
 * storage is needed. Sized once on first use; geometry is rewritten
 * via Clay_SetLayoutDimensions() per call. */
static Clay_Context *frame_ctx = NULL;
static void *frame_arena_memory = NULL;

/* Tags carried in customData on the leaf elements of the frame tree.
 * Walked after Clay_EndLayout() to dispatch positions to the correct
 * scene-graph node. Must be non-zero so customData != NULL is meaningful.
 * Borders carry no element: their scene rects are positioned by arithmetic
 * in frame_apply_boxes(), not solved as boxes. */
enum {
	CFRAME_TITLEBAR_TOP = 1,
	CFRAME_TITLEBAR_RIGHT,
	CFRAME_TITLEBAR_BOTTOM,
	CFRAME_TITLEBAR_LEFT,
	CFRAME_SURFACE,
};

/* In the merged screen solve, frame leaves are emitted as children of
 * their client's node. Their customData packs the owning client's 1-based
 * result index in the low bits and the CFRAME_* role in the high bits, so
 * end_layout() can route each box to the right client's merged_frame scratch.
 * The isolated per-client frame solve passes idx == 0, so customData is
 * just the role (1..5) and its render-command walk reads it directly. */
#define CLAY_FRAME_ROLE_SHIFT 24
#define CLAY_FRAME_IDX_MASK   (((uint32_t)1 << CLAY_FRAME_ROLE_SHIFT) - 1)

static inline intptr_t
frame_cd(int idx, int role)
{
	return (intptr_t)((uint32_t)idx | ((uint32_t)role << CLAY_FRAME_ROLE_SHIFT));
}

/* Defined below with the frame sub-pass; forward-declared so
 * client_element can emit a client's frame children inline. */
static void emit_frame_tree(uint32_t *idc, int idx, float fbw,
                                 float ftt, float ftr, float ftb, float ftl);

/* Shared cairo font setup for the debug view: monospace at the command's pixel
 * size. Used by BOTH clay_measure_text and clay_render_debug_overlay so the
 * panel's measured text widths match the drawn glyphs (no layout drift). */
static void
clay_debug_set_font(cairo_t *cr, uint16_t font_size)
{
	cairo_select_font_face(cr, "monospace",
	                       CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(cr, font_size > 0 ? (double)font_size : 16.0);
}

/* Copy a (non-NUL-terminated) Clay string slice into a bounded C string.
 * Debug-view strings are short labels/numbers, so 512 is ample; both the
 * measurer and the renderer truncate identically, so widths stay consistent. */
static void
clay_slice_to_cstr(Clay_StringSlice s, char *buf, size_t cap)
{
	int n = s.length;
	if (n < 0 || !s.chars) n = 0;
	if (n > (int)cap - 1) n = (int)cap - 1;
	if (n > 0) memcpy(buf, s.chars, n);
	buf[n] = '\0';
}

/* Text measurement for Clay. Only ever invoked for the debug view's TEXT
 * elements (somewm's normal solves emit no TEXT), so it is safe to install on
 * every context. Measures the same monospace font the renderer draws with. */
static Clay_Dimensions
clay_measure_text(Clay_StringSlice text, Clay_TextElementConfig *config,
                  void *userData)
{
	(void)userData;

	if (!clay_debug_scratch_cr) {
		clay_debug_scratch_surface =
			cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
		clay_debug_scratch_cr = cairo_create(clay_debug_scratch_surface);
	}

	clay_debug_set_font(clay_debug_scratch_cr, config ? config->fontSize : 16);

	cairo_font_extents_t fe;
	cairo_font_extents(clay_debug_scratch_cr, &fe);
	if (text.length <= 0)
		return (Clay_Dimensions){ 0, (float)fe.height };

	char buf[512];
	clay_slice_to_cstr(text, buf, sizeof(buf));
	cairo_text_extents_t te;
	cairo_text_extents(clay_debug_scratch_cr, buf, &te);
	return (Clay_Dimensions){ (float)te.x_advance, (float)fe.height };
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

	int free_slot = -1;
	for (int i = 0; i < screen_count; i++) {
		if (!screens[i].ctx) {        /* slot freed by clay_screen_removed */
			if (free_slot < 0)
				free_slot = i;
			continue;
		}
		lua_rawgeti(L, LUA_REGISTRYINDEX, screens[i].screen_ref);
		if (lua_rawequal(L, -1, -2)) {
			lua_pop(L, 2);
			return &screens[i];
		}
		lua_pop(L, 1);
	}

	clay_screen_t *cs;
	if (free_slot >= 0) {
		cs = &screens[free_slot];     /* reuse a removed screen's slot */
	} else {
		if (screen_count >= MAX_SCREENS) {
			lua_pop(L, 1);
			luaL_error(L, "clay: too many screens (max %d)", MAX_SCREENS);
			return NULL;
		}
		cs = &screens[screen_count++];
	}
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

/* Release a removed screen's Clay context so its slot can be reused and its
 * resources (arena, results, debug overlay/surface, screen registry ref) don't
 * leak. Called from screen_removed() on output unplug / fake-screen removal.
 * clay_get_screen reuses any slot left with ctx == NULL. */
void
clay_screen_removed(lua_State *L, screen_t *s)
{
	for (int i = 0; i < screen_count; i++) {
		clay_screen_t *cs = &screens[i];
		if (!cs->ctx)
			continue;
		lua_rawgeti(L, LUA_REGISTRYINDEX, cs->screen_ref);
		screen_t *cand = lua_touserdata(L, -1);
		lua_pop(L, 1);
		if (cand != s)
			continue;

		for (int j = 0; j < cs->results_count; j++)
			if (cs->results[j].lua_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, cs->results[j].lua_ref);
		if (cs->debug_overlay)
			wlr_scene_node_destroy(&cs->debug_overlay->node);
		if (cs->debug_surface)
			cairo_surface_destroy(cs->debug_surface);
		free(cs->results);
		free(cs->arena_memory);
		free(cs->name_pool);
		luaL_unref(L, LUA_REGISTRYINDEX, cs->screen_ref);
		if (active_screen == cs)
			active_screen = NULL;
		memset(cs, 0, sizeof(*cs)); /* ctx == NULL marks the slot reusable */
		return;
	}
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
			.size = { .percent = (float)lua_tonumber(L, -1) },
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
			.size = { .percent = (float)lua_tonumber(L, -1) },
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
 * Two attachment modes, both placing the element outside the parent's flow:
 *   - `attach_to_parent = true`: Clay attaches this element to its layout
 *     parent at `x_offset` / `y_offset`. Used by `layout.stack` children:
 *     `clay.max` (overlap), `wibox.layout.{stack, manual, grid}` (absolute
 *     coords), `clay.floating` (per-client coords), and the magnifier overlay.
 *   - `attach_to_root = true`: Clay attaches this element to the layout root
 *     at `x_offset` / `y_offset` (absolute positioning). Used by
 *     `layout.floating_client` to reflect a floating/fullscreen client at
 *     absolute screen coords inside `compose_screen`'s one solve, and by the
 *     `clay.max.fullscreen` graft (a root-attached container spanning the
 *     full screen rather than the wibar-inset workarea node).
 *
 * `z_index` orders floating roots for render only; the single-buffer apply
 * reads geometry back by customData index, so it never affects which client
 * gets which box. When neither flag is set, returns a zeroed struct: Clay
 * treats this as `CLAY_ATTACH_TO_NONE`, i.e. normal flow participation.
 */
/* Map a Lua attach-point name to Clay's 9-value enum. Names mirror
 * CLAY_ATTACH_POINT_<vertical>_<horizontal>, vertical {left,center,right} x
 * horizontal {top,center,bottom}. Absent / unknown -> LEFT_TOP (Clay's default
 * and the value the binding hardcoded before popups needed real attach points). */
static Clay_FloatingAttachPointType
clay_attach_point_from_name(const char *s)
{
	if (!s)                          return CLAY_ATTACH_POINT_LEFT_TOP;
	if (!strcmp(s, "left_top"))      return CLAY_ATTACH_POINT_LEFT_TOP;
	if (!strcmp(s, "left_center"))   return CLAY_ATTACH_POINT_LEFT_CENTER;
	if (!strcmp(s, "left_bottom"))   return CLAY_ATTACH_POINT_LEFT_BOTTOM;
	if (!strcmp(s, "center_top"))    return CLAY_ATTACH_POINT_CENTER_TOP;
	if (!strcmp(s, "center_center")) return CLAY_ATTACH_POINT_CENTER_CENTER;
	if (!strcmp(s, "center_bottom")) return CLAY_ATTACH_POINT_CENTER_BOTTOM;
	if (!strcmp(s, "right_top"))     return CLAY_ATTACH_POINT_RIGHT_TOP;
	if (!strcmp(s, "right_center"))  return CLAY_ATTACH_POINT_RIGHT_CENTER;
	if (!strcmp(s, "right_bottom"))  return CLAY_ATTACH_POINT_RIGHT_BOTTOM;
	return CLAY_ATTACH_POINT_LEFT_TOP;
}

static Clay_FloatingElementConfig
clay_read_floating_config(lua_State *L, int idx)
{
	Clay_FloatingElementConfig fc = { 0 };
	if (!lua_istable(L, idx))
		return fc;

	/* Attach mode: an explicit element id wins, then root, then parent. The
	 * element-id form is how a popup/tooltip floats off its anchor widget; the
	 * parentId is the counter-independent hash of the anchor's clay_ref string,
	 * so it matches the id clay_element_id assigns that anchor (see clay.h
	 * CLAY_ATTACH_TO_ELEMENT_WITH_ID / .parentId). */
	lua_getfield(L, idx, "attach_to_element_id");
	const char *anchor = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;

	lua_getfield(L, idx, "attach_to_root");
	bool to_root = lua_toboolean(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, idx, "attach_to_parent");
	bool to_parent = lua_toboolean(L, -1);
	lua_pop(L, 1);

	if (anchor) {
		fc.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
		fc.parentId = Clay__HashString(
			(Clay_String){ .length = (int32_t)strlen(anchor), .chars = anchor },
			0).id;
		lua_pop(L, 1); /* attach_to_element_id (kept on stack until hashed) */
	} else {
		lua_pop(L, 1); /* attach_to_element_id (not a string) */
		if (!to_parent && !to_root)
			return fc;
		fc.attachTo = to_root ? CLAY_ATTACH_TO_ROOT : CLAY_ATTACH_TO_PARENT;
	}

	/* attachPoints default to LEFT_TOP/LEFT_TOP (what the in-flow root/parent
	 * callers relied on); popups pass an explicit {element, parent} pair. */
	fc.attachPoints = (Clay_FloatingAttachPoints){
		.element = CLAY_ATTACH_POINT_LEFT_TOP,
		.parent  = CLAY_ATTACH_POINT_LEFT_TOP,
	};
	lua_getfield(L, idx, "attach_points");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "element");
		fc.attachPoints.element = clay_attach_point_from_name(
			lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL);
		lua_pop(L, 1);
		lua_getfield(L, -1, "parent");
		fc.attachPoints.parent = clay_attach_point_from_name(
			lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	lua_getfield(L, idx, "x_offset");
	if (lua_isnumber(L, -1))
		fc.offset.x = (float)lua_tonumber(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, idx, "y_offset");
	if (lua_isnumber(L, -1))
		fc.offset.y = (float)lua_tonumber(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, idx, "z_index");
	if (lua_isnumber(L, -1))
		fc.zIndex = (int16_t)lua_tonumber(L, -1);
	lua_pop(L, 1);

	return fc;
}

/* Read a client border from a Lua table at `idx`: cfg.border = { width, color }.
 * width drives CLAY_BORDER_OUTSIDE() (a uniform perimeter border, no
 * betweenChildren); color is a "#RRGGBB[AA]" string (color_t channels are 0-255,
 * which is what Clay_Color wants). Returns a zeroed config (no border) when the
 * field is absent or width is 0; Clay emits a BORDER render command only for a
 * width > 0. The drawn border is the four scene rects positioned by arithmetic in
 * frame_apply_boxes(); this config is the declared value for `clay tree` and the
 * debug inspector, and the live rect color is set C-side on focus. */
static Clay_BorderElementConfig
clay_read_border_config(lua_State *L, int idx)
{
	Clay_BorderElementConfig bc = { 0 };
	if (!lua_istable(L, idx))
		return bc;

	lua_getfield(L, idx, "border");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "width");
		uint16_t w = lua_isnumber(L, -1) ? (uint16_t)lua_tonumber(L, -1) : 0;
		lua_pop(L, 1);
		bc.width = (Clay_BorderWidth)CLAY_BORDER_OUTSIDE(w);

		lua_getfield(L, -1, "color");
		if (lua_isstring(L, -1)) {
			color_t col;
			if (color_init_from_string(&col, lua_tostring(L, -1)))
				bc.color = (Clay_Color){
					(float)col.red, (float)col.green,
					(float)col.blue, (float)col.alpha,
				};
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return bc;
}

/* Lazily create the dedicated scene tree that parents every per-screen debug
 * overlay. Placed above LyrBlock so the debug view sits on top of everything,
 * including the session lock (correct for a developer tool). */
static void
clay_debug_ensure_tree(void)
{
	if (clay_debug_tree || !scene)
		return;
	clay_debug_tree = wlr_scene_tree_create(&scene->tree);
	if (clay_debug_tree)
		wlr_scene_node_place_above(&clay_debug_tree->node,
		                           &layers[LyrBlock]->node);
}

static void
clay_debug_hide_overlay(clay_screen_t *cs)
{
	if (cs->debug_overlay)
		wlr_scene_node_set_enabled(&cs->debug_overlay->node, false);
}

static inline void
clay_set_cairo_color(cairo_t *cr, Clay_Color c)
{
	cairo_set_source_rgba(cr, c.r / 255.0, c.g / 255.0, c.b / 255.0,
	                      c.a / 255.0);
}

/* Minimal Clay render-command renderer: walk the command array (already
 * z-sorted, so naive order is correct) and draw the RECTANGLE / BORDER / TEXT /
 * SCISSOR commands of Clay's debug view into a per-screen cairo surface, then
 * push it to a scene buffer at the screen origin. The CUSTOM commands (the
 * actual clients/wibars/widgets) are handled by the normal layout path; here
 * they are skipped. */
static void
clay_render_debug_overlay(clay_screen_t *cs, Clay_RenderCommandArray cmds,
                          int w, int h)
{
	if (w < 1) w = 1;
	if (h < 1) h = 1;

	if (cs->debug_surface && (cs->debug_w != w || cs->debug_h != h)) {
		cairo_surface_destroy(cs->debug_surface);
		cs->debug_surface = NULL;
	}
	if (!cs->debug_surface) {
		cairo_surface_t *surf =
			cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
		/* On failure (e.g. a bogus huge dimension), bail without caching the
		 * size, so a later valid solve at the same size retries the create. */
		if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
			cairo_surface_destroy(surf);
			return;
		}
		cs->debug_surface = surf;
		cs->debug_w = w;
		cs->debug_h = h;
	}

	cairo_t *cr = cairo_create(cs->debug_surface);

	/* Clear to fully transparent (premultiplied: rgb must be 0 when a is 0). */
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_set_source_rgba(cr, 0, 0, 0, 0);
	cairo_paint(cr);
	cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

	int scissor_depth = 0;
	for (int32_t i = 0; i < cmds.length; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&cmds, i);
		Clay_BoundingBox b = cmd->boundingBox;

		switch (cmd->commandType) {
		case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
			clay_set_cairo_color(cr,
				cmd->renderData.rectangle.backgroundColor);
			cairo_rectangle(cr, b.x, b.y, b.width, b.height);
			cairo_fill(cr);
			break;

		case CLAY_RENDER_COMMAND_TYPE_BORDER: {
			Clay_BorderRenderData bd = cmd->renderData.border;
			clay_set_cairo_color(cr, bd.color);
			if (bd.width.left)
				cairo_rectangle(cr, b.x, b.y,
				                bd.width.left, b.height);
			if (bd.width.right)
				cairo_rectangle(cr,
				                b.x + b.width - bd.width.right, b.y,
				                bd.width.right, b.height);
			if (bd.width.top)
				cairo_rectangle(cr, b.x, b.y,
				                b.width, bd.width.top);
			if (bd.width.bottom)
				cairo_rectangle(cr, b.x,
				                b.y + b.height - bd.width.bottom,
				                b.width, bd.width.bottom);
			cairo_fill(cr);
			break;
		}

		case CLAY_RENDER_COMMAND_TYPE_TEXT: {
			Clay_TextRenderData td = cmd->renderData.text;
			char buf[512];
			clay_slice_to_cstr(td.stringContents, buf, sizeof(buf));
			clay_debug_set_font(cr, td.fontSize);
			cairo_font_extents_t fe;
			cairo_font_extents(cr, &fe);
			clay_set_cairo_color(cr, td.textColor);
			/* boundingBox is top-left; cairo draws from the baseline. */
			cairo_move_to(cr, b.x, b.y + fe.ascent);
			cairo_show_text(cr, buf);
			break;
		}

		case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START:
			cairo_save(cr);
			cairo_rectangle(cr, b.x, b.y, b.width, b.height);
			cairo_clip(cr);
			scissor_depth++;
			break;

		case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END:
			if (scissor_depth > 0) {
				cairo_restore(cr);
				scissor_depth--;
			}
			break;

		default:
			break;
		}
	}
	/* Balance any scissor START left open by a malformed array. */
	while (scissor_depth-- > 0)
		cairo_restore(cr);

	cairo_destroy(cr);
	cairo_surface_flush(cs->debug_surface);

	struct wlr_buffer *buffer = drawable_create_buffer_from_data(
		w, h,
		cairo_image_surface_get_data(cs->debug_surface),
		cairo_image_surface_get_stride(cs->debug_surface));
	if (!buffer)
		return;

	clay_debug_ensure_tree();
	if (!clay_debug_tree) {
		wlr_buffer_drop(buffer);
		return;
	}
	if (!cs->debug_overlay)
		cs->debug_overlay = wlr_scene_buffer_create(clay_debug_tree, buffer);
	else
		wlr_scene_buffer_set_buffer(cs->debug_overlay, buffer);

	if (cs->debug_overlay) {
		wlr_scene_node_set_position(&cs->debug_overlay->node,
		                            (int)cs->offset_x, (int)cs->offset_y);
		wlr_scene_node_set_enabled(&cs->debug_overlay->node, true);
	}
	wlr_buffer_drop(buffer);
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
	cs->debug_only_solve = false;
	cs->read_anchor_refs = false;

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

		lua_getfield(L, 4, "debug_only");
		cs->debug_only_solve = lua_toboolean(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, 4, "read_anchor_refs");
		cs->read_anchor_refs = lua_toboolean(L, -1);
		lua_pop(L, 1);
	}

	if (!source) {
		solve_counters.unknown++;
	} else if (strcmp(source, "compose_screen") == 0) {
		solve_counters.compose_screen++;
	} else if (strcmp(source, "preset") == 0) {
		solve_counters.preset++;
	} else if (strcmp(source, "merged") == 0) {
		solve_counters.merged++;
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
	cs->dim_w = width;
	cs->dim_h = height;

	Clay_SetCurrentContext(cs->ctx);

	/* Debug view: scoped to the screen-COMPOSITION solve only. Other solves
	 * that share a screen context (placement positioning, magnifier) must NOT
	 * enable debug -- it would shrink their root by Clay__debugViewWidth and
	 * mis-position the result. debugModeEnabled persists on the context, so set
	 * it false explicitly for those, not just "skip". The widget pass uses
	 * widget_ctx and is left untouched (never enabled). When on, the pointer
	 * feed (screen-local coords, left button) drives the hover highlight, read
	 * from the previous frame's retained layout. */
	bool is_compose = source && (strcmp(source, "merged") == 0
	                             || strcmp(source, "compose_screen") == 0);
	cs->debug_compose_solve = (cs != &widget_ctx) && is_compose;
	cs->debug_render = false;
	if (cs != &widget_ctx) {
		bool debug_this = clay_debug_enabled && is_compose;
		cs->debug_render = debug_this;
		if (debug_this)
			cs->name_pool_len = 0;  /* reset the per-solve name scratch */
		Clay_SetDebugModeEnabled(debug_this);
		if (debug_this)
			Clay_SetPointerState(
				(Clay_Vector2){ (float)(cursor->x - cs->offset_x),
				                (float)(cursor->y - cs->offset_y) },
				globalconf.button_state.buttons[0]);
	}

	Clay_SetLayoutDimensions((Clay_Dimensions){ width, height });
	Clay_BeginLayout();
	cs->element_id_counter = 0;
	/* Reset the framed-client context: a Lua error between client_open and
	 * client_close (swallowed by the arrange pcall) would otherwise leak a stale
	 * index into this solve and misroute frame_box boxes. */
	g_frame_client_idx = 0;

	return 0;
}

/* Per-solve name scratch capacity. Names are short; this holds ~2000 of them.
 * Only allocated once a screen first renders the debug view. */
#define CLAY_NAME_POOL_CAP (32 * 1024)

/* Append a name to the per-solve name pool, returning a Clay_String into it (or
 * a zero string on overflow / no name). The pool is stable until the next
 * begin_layout reset, which is after this solve's EndLayout debug pass, so the
 * Clay_String Clay stores for the element id stays valid that whole time. */
static Clay_String
clay_name_pool_add(clay_screen_t *cs, const char *name, int len)
{
	if (!name || len <= 0)
		return (Clay_String){ 0 };
	if (!cs->name_pool) {
		cs->name_pool = malloc(CLAY_NAME_POOL_CAP);
		if (!cs->name_pool)
			return (Clay_String){ 0 };
	}
	if (cs->name_pool_len + len > CLAY_NAME_POOL_CAP)
		return (Clay_String){ 0 };
	char *dst = cs->name_pool + cs->name_pool_len;
	memcpy(dst, name, len);
	cs->name_pool_len += len;
	return (Clay_String){ .isStaticallyAllocated = false,
	                      .length = len, .chars = dst };
}

/* Bump the element counter and return its Clay id. With `stable` set the id is
 * the counter-independent hash of `name` (clay_ref), so a floating popup whose
 * parentId is the hash of the same string resolves to this element across
 * solves; the counter still bumps so every other element's numeric id stays
 * dense. Otherwise: when the debug view renders this solve and a name is
 * supplied, the id carries a readable stringId (the counter as a uniquifying
 * offset so equal names don't collide), which the inspector displays; else a
 * plain numeric id (no string hashing). */
static Clay_ElementId
clay_element_id(clay_screen_t *cs, const char *name, int name_len, bool stable)
{
	uint32_t n = ++cs->element_id_counter;
	if (stable && name && name_len > 0) {
		Clay_ElementId id = Clay__HashString(
			(Clay_String){ .length = (int32_t)name_len, .chars = name }, 0);
		if (cs->debug_render) {
			Clay_String s = clay_name_pool_add(cs, name, name_len);
			if (s.length > 0)
				id.stringId = s;
		} else {
			id.stringId = (Clay_String){ 0 };
		}
		return id;
	}
	if (cs->debug_render && name) {
		Clay_String s = clay_name_pool_add(cs, name, name_len);
		if (s.length > 0)
			return Clay__HashStringWithOffset(s, n, 0);
	}
	return (Clay_ElementId){ .id = n };
}

/* Open a Clay element, taking its id from config.id. Every binding's config
 * table is either arg 2 (leaf bindings: client/drawin/widget, where arg 1 is
 * the object) or arg 1 (open_container / workarea, where arg 1 is the config),
 * so look at arg 2 then arg 1. The names themselves are assigned Lua-side in
 * emit() (client.<class>, wibar.<pos>, workarea, row/column/stack, ...). Reads
 * cfg.clay_ref only when this solve has registered popups (read_anchor_refs) and
 * cfg.id only when the debug view renders this solve, so a normal popup-free,
 * non-debug solve does no per-element getfield at all. The name string is copied
 * into the name pool while still on the stack, so it outlives this call. */
static void
clay_open_element(lua_State *L)
{
	const char *name = NULL;
	int len = 0, pushed = 0;
	bool stable = false;
	bool want_ref = active_screen->read_anchor_refs; /* popups present this solve */
	bool want_id  = active_screen->debug_render;     /* debug view renders this solve */

	if (want_ref || want_id) {
		int cfg_idx = lua_istable(L, 2) ? 2 : (lua_istable(L, 1) ? 1 : 0);
		if (cfg_idx) {
			/* Stable anchor id (clay_ref): a popup attaches to this element by
			 * id. Wins over the debug-only `id`. */
			if (want_ref) {
				lua_getfield(L, cfg_idx, "clay_ref");
				if (lua_isstring(L, -1)) {
					size_t l;
					name = lua_tolstring(L, -1, &l);
					len = (int)l;
					stable = true;
					pushed = 1;  /* keep on stack until the name is copied */
				} else {
					lua_pop(L, 1);
				}
			}
			/* Debug-only readable name (`id`): only when no clay_ref. */
			if (!stable && want_id) {
				lua_getfield(L, cfg_idx, "id");
				if (lua_isstring(L, -1)) {
					size_t l;
					name = lua_tolstring(L, -1, &l);
					len = (int)l;
					pushed = 1;
				} else {
					lua_pop(L, 1);
				}
			}
		}
	}

	Clay__OpenElementWithId(clay_element_id(active_screen, name, len, stable));
	if (pushed)
		lua_pop(L, 1);
}

/* _somewm_clay.open_container(config_table) */
static int
luaA_clay_open_container(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: open_container called outside begin/end_layout");

	Clay_LayoutConfig layout = clay_read_layout_config(L, 1);
	Clay_FloatingElementConfig floating = clay_read_floating_config(L, 1);
	/* .border only feeds the Clay debug overlay; the on-screen border is the
	 * arithmetic scene rects (frame_apply_boxes), colored on focus. Skip the
	 * per-solve color parse unless this is the solve the debug view renders. */
	Clay_BorderElementConfig border = active_screen->debug_render
		? clay_read_border_config(L, 1) : (Clay_BorderElementConfig){ 0 };

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.border = border,
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
/* Create a CLAY_ELEM_CLIENT result for the client at Lua stack index 1, ref it
 * to prevent GC, and return its 1-based result index (== the customData clients
 * carry). Shared by client_element (leaf) and client_open (framed). */
static int
clay_push_client_result(lua_State *L, client_t **out_c)
{
	client_t *c = luaA_checkudata(L, 1, &client_class);
	lua_pushvalue(L, 1);
	int ref = luaL_ref(L, LUA_REGISTRYINDEX);

	clay_results_ensure_cap(active_screen);
	clay_result_t *r = &active_screen->results[active_screen->results_count++];
	r->type = CLAY_ELEM_CLIENT;
	r->client = c;
	r->lua_ref = ref;
	r->x = r->y = r->w = r->h = 0;

	if (out_c) *out_c = c;
	return active_screen->results_count; /* 1-based; == customData */
}

/* _somewm_clay.client_element(client, config) - a client leaf (no frame
 * children). Used for unframed clients (e.g. floating reflections, magnifier
 * overlay); framed tiled clients use client_open/close instead. */
static int
luaA_clay_client_element(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: client_element called outside begin/end_layout");

	int idx = clay_push_client_result(L, NULL);

	Clay_LayoutConfig layout = { 0 };
	Clay_FloatingElementConfig floating = { 0 };
	if (lua_istable(L, 2)) {
		layout = clay_read_layout_config(L, 2);
		floating = clay_read_floating_config(L, 2);
	}

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)idx },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.client_open(client, config) / client_close()
 * Like client_element, but stays open so the client's frame subtree
 * (border leaves + titlebar nodes + surface, built in Lua) can be emitted as
 * children. Sets g_frame_client_idx so those children route their solved boxes
 * into this client's merged_frame (see frame_box, end_layout). The padding
 * insets the children to cell - 2*border_width, matching the frame box
 * clay_apply_all produces, anchored top-left. */
static int
luaA_clay_client_open(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: client_open called outside begin/end_layout");

	client_t *c = NULL;
	int idx = clay_push_client_result(L, &c);

	/* Clear this client's frame boxes so a role whose leaf is culled this
	 * solve (e.g. an off-screen edge in a future scrolling merge-capable layout)
	 * leaves a zeroed box, not a stale one. Mirrors the fallback's box[6]={0}. */
	memset(c->merged_frame.box, 0, sizeof(c->merged_frame.box));

	Clay_LayoutConfig layout = { 0 };
	Clay_FloatingElementConfig floating = { 0 };
	if (lua_istable(L, 2)) {
		layout = clay_read_layout_config(L, 2);
		floating = clay_read_floating_config(L, 2);
	}
	uint16_t pad = (uint16_t)(2 * c->border_width);
	layout.padding.right  = (uint16_t)(layout.padding.right + pad);
	layout.padding.bottom = (uint16_t)(layout.padding.bottom + pad);

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)idx },
	});
	g_frame_client_idx = idx;
	return 0;
}

static int
luaA_clay_client_close(lua_State *L)
{
	(void)L;
	if (!active_screen)
		return luaL_error(L, "clay: client_close called outside begin/end_layout");
	Clay__CloseElement();
	g_frame_client_idx = 0;
	return 0;
}

/* _somewm_clay.frame_box(role, config) - a border or surface leaf emitted inside
 * a client_open container. Its solved box is routed (end_layout, re-based to the
 * client frame origin) into the current framed client's merged_frame[role],
 * which apply_geometry_to_wlroots consumes to position the border rects and the
 * surface. role is a CFRAME_* value (exposed to Lua as _somewm_clay.frame). */
static int
luaA_clay_frame_box(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: frame_box called outside begin/end_layout");
	int role = (int)luaL_checkinteger(L, 1);

	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 2))
		layout = clay_read_layout_config(L, 2);

	Clay__OpenElementWithId((Clay_ElementId){ .id = ++active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.custom = { .customData = (void *)frame_cd(g_frame_client_idx, role) },
	});
	Clay__CloseElement();
	return 0;
}

/* _somewm_clay.titlebar_open(role, config) - like frame_box, but stays OPEN so
 * widget children can be emitted inside the titlebar before titlebar_close().
 * The titlebar's own box still routes (end_layout pass 2, re-based to the client
 * frame origin) into merged_frame[role] for client-relative scene_buffer
 * positioning, exactly like a box-only titlebar; the widget children inside are
 * plain CLAY_ELEM_WIDGET nodes whose boxes return to Lua. The widget root grows
 * to fill this element, so its box == the titlebar box and child placements
 * re-base to titlebar-local paint coords. */
static int
luaA_clay_titlebar_open(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: titlebar_open called outside begin/end_layout");
	int role = (int)luaL_checkinteger(L, 1);

	Clay_LayoutConfig layout = { 0 };
	if (lua_istable(L, 2))
		layout = clay_read_layout_config(L, 2);

	Clay__OpenElementWithId((Clay_ElementId){ .id = ++active_screen->element_id_counter });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.custom = { .customData = (void *)frame_cd(g_frame_client_idx, role) },
	});
	return 0;
}

/* _somewm_clay.titlebar_close() - close a titlebar_open() container. */
static int
luaA_clay_titlebar_close(lua_State *L)
{
	(void)L;
	if (!active_screen)
		return luaL_error(L, "clay: titlebar_close called outside begin/end_layout");
	Clay__CloseElement();
	return 0;
}

/* _somewm_clay.client_frame_sizes(client) -> bw, top, right, bottom, left
 * Side-effect-free read of the client's border width and the four titlebar sizes
 * (zeroed when fullscreen), so Lua can build the frame subtree without
 * the titlebar_* getters, which would lazily create titlebar drawables. */
static int
luaA_clay_client_frame_sizes(lua_State *L)
{
	client_t *c = luaA_checkudata(L, 1, &client_class);
	bool fs = c->fullscreen;
	lua_pushinteger(L, (lua_Integer)c->border_width);
	lua_pushinteger(L, fs ? 0 : (lua_Integer)c->titlebar[CLIENT_TITLEBAR_TOP].size);
	lua_pushinteger(L, fs ? 0 : (lua_Integer)c->titlebar[CLIENT_TITLEBAR_RIGHT].size);
	lua_pushinteger(L, fs ? 0 : (lua_Integer)c->titlebar[CLIENT_TITLEBAR_BOTTOM].size);
	lua_pushinteger(L, fs ? 0 : (lua_Integer)c->titlebar[CLIENT_TITLEBAR_LEFT].size);
	return 5;
}

/* _somewm_clay.client_frame_geometry(client) -> introspection of the APPLIED
 * frame scene geometry (frame-relative), regardless of which path (merged
 * consume or per-client fallback) positioned it. For tests: a broken frame
 * solve shows zero-size borders and a (0,0) surface offset. Returns
 *   { border = {[1..4] = {x,y,w,h}},      -- TOP, BOTTOM, LEFT, RIGHT
 *     surface = {x,y},
 *     titlebar = {[1..4] = {x,y,enabled,size}} }  -- TOP, RIGHT, BOTTOM, LEFT
 * mirroring c->border[] and the CFRAME titlebar order. */
static int
luaA_clay_client_frame_geometry(lua_State *L)
{
	client_t *c = luaA_checkudata(L, 1, &client_class);
	lua_newtable(L);

	lua_newtable(L);
	for (int i = 0; i < 4; i++) {
		lua_newtable(L);
		if (c->border[i]) {
			lua_pushinteger(L, c->border[i]->node.x); lua_setfield(L, -2, "x");
			lua_pushinteger(L, c->border[i]->node.y); lua_setfield(L, -2, "y");
			lua_pushinteger(L, c->border[i]->width);  lua_setfield(L, -2, "w");
			lua_pushinteger(L, c->border[i]->height); lua_setfield(L, -2, "h");
		}
		lua_rawseti(L, -2, i + 1);
	}
	lua_setfield(L, -2, "border");

	lua_newtable(L);
	if (c->scene_surface) {
		lua_pushinteger(L, c->scene_surface->node.x); lua_setfield(L, -2, "x");
		lua_pushinteger(L, c->scene_surface->node.y); lua_setfield(L, -2, "y");
	}
	lua_setfield(L, -2, "surface");

	lua_newtable(L);
	for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP;
	     bar < CLIENT_TITLEBAR_COUNT; bar++) {
		lua_newtable(L);
		struct wlr_scene_buffer *sb = c->titlebar[bar].scene_buffer;
		if (sb) {
			lua_pushinteger(L, sb->node.x);       lua_setfield(L, -2, "x");
			lua_pushinteger(L, sb->node.y);       lua_setfield(L, -2, "y");
			lua_pushboolean(L, sb->node.enabled); lua_setfield(L, -2, "enabled");
		}
		lua_pushinteger(L, c->titlebar[bar].size); lua_setfield(L, -2, "size");
		lua_rawseti(L, -2, bar + 1);
	}
	lua_setfield(L, -2, "titlebar");

	return 1;
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

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.drawin_open(drawin, config)
 * Like drawin_element, but leaves the element open so a widget subtree can be
 * emitted as its children before drawin_close(). The drawin still applies its
 * own geometry (CLAY_ELEM_DRAWIN) exactly as the leaf form does. */
static int
luaA_clay_drawin_open(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: drawin_open called outside begin/end_layout");

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

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});

	return 0;
}

/* _somewm_clay.drawin_close() - close a drawin_open() container. */
static int
luaA_clay_drawin_close(lua_State *L)
{
	(void)L;
	if (!active_screen)
		return luaL_error(L, "clay: drawin_close called outside begin/end_layout");

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

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.widget_open(widget, config)
 * Like widget_element, but leaves the element open so child widget nodes can be
 * emitted before widget_close(). Lets a container widget (margin/fixed/align/
 * background) be a CLAY_ELEM_WIDGET whose box is returned to Lua, so the widget
 * hierarchy can be rebuilt from the screen solve without the per-container
 * "wibox" solve forest. */
static int
luaA_clay_widget_open(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: widget_open called outside begin/end_layout");

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

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});

	return 0;
}

/* _somewm_clay.widget_close() - close a widget_open() container. */
static int
luaA_clay_widget_close(lua_State *L)
{
	(void)L;
	if (!active_screen)
		return luaL_error(L, "clay: widget_close called outside begin/end_layout");

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

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});
	Clay__CloseElement();

	return 0;
}

/* _somewm_clay.workarea_open(config)
 * Like workarea_element, but leaves the element open so a client subtree can
 * be emitted as its children before workarea_close(). The bounding box still
 * reports back as the workarea (minus padding), so screen.workarea is written
 * exactly as the leaf form does. */
static int
luaA_clay_workarea_open(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: workarea_open called outside begin/end_layout");

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

	r->pad_top = layout.padding.top;
	r->pad_right = layout.padding.right;
	r->pad_bottom = layout.padding.bottom;
	r->pad_left = layout.padding.left;

	clay_open_element(L);
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = layout,
		.floating = floating,
		.custom = { .customData = (void *)(intptr_t)active_screen->results_count },
	});

	return 0;
}

/* _somewm_clay.workarea_close() - close a workarea_open() container. */
static int
luaA_clay_workarea_close(lua_State *L)
{
	(void)L;
	if (!active_screen)
		return luaL_error(L, "clay: workarea_close called outside begin/end_layout");

	Clay__CloseElement();
	return 0;
}

/* _somewm_clay.end_layout() */
static int
luaA_clay_end_layout(lua_State *L)
{
	if (!active_screen)
		return luaL_error(L, "clay: end_layout called without begin_layout");

	clay_screen_t *cs = active_screen;
	Clay_RenderCommandArray commands = Clay_EndLayout();

	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd =
			Clay_RenderCommandArray_Get(&commands, i);

		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;

		uint32_t cd = (uint32_t)(intptr_t)cmd->renderData.custom.customData;
		if (cd >> CLAY_FRAME_ROLE_SHIFT)
			continue; /* frame leaf: handled in the pass below */

		int idx = (int)cd;
		if (idx <= 0 || idx > active_screen->results_count)
			continue;

		clay_result_t *r = &active_screen->results[idx - 1];
		r->x = cmd->boundingBox.x;
		r->y = cmd->boundingBox.y;
		r->w = cmd->boundingBox.width;
		r->h = cmd->boundingBox.height;
	}

	/* Second pass: frame leaves emitted under framed client nodes
	 * (emit_frame_tree). customData packs role (high bits) | client result
	 * index (low bits). Re-base each box to the client's frame origin (its node
	 * box, populated by the pass above) and store into the client's merged_frame
	 * scratch, which apply_geometry_to_wlroots consumes in place of the per-client
	 * solve. Both boxes are solve-local here, so the subtraction is offset-
	 * independent. The surface leaf (one per client) stamps the validity key. */
	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd =
			Clay_RenderCommandArray_Get(&commands, i);
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;
		uint32_t cd = (uint32_t)(intptr_t)cmd->renderData.custom.customData;
		int role = (int)(cd >> CLAY_FRAME_ROLE_SHIFT);
		if (role < CFRAME_TITLEBAR_TOP || role > CFRAME_SURFACE)
			continue;
		int idx = (int)(cd & CLAY_FRAME_IDX_MASK);
		if (idx <= 0 || idx > active_screen->results_count)
			continue;
		clay_result_t *r = &active_screen->results[idx - 1];
		if (r->type != CLAY_ELEM_CLIENT || !r->client)
			continue;
		client_t *c = r->client;
		struct frame_box *bx = &c->merged_frame.box[role];
		bx->x = (int)cmd->boundingBox.x - (int)r->x;
		bx->y = (int)cmd->boundingBox.y - (int)r->y;
		bx->w = (int)cmd->boundingBox.width;
		bx->h = (int)cmd->boundingBox.height;

		if (role == CFRAME_SURFACE) {
			int bw2 = (int)c->border_width * 2;
			c->merged_frame.geo_w      = MAX(1, (int)r->w - bw2);
			c->merged_frame.geo_h      = MAX(1, (int)r->h - bw2);
			/* Key on border_width to match the box geometry above (client_open
			 * padding + client_frame_sizes both use border_width), not c->bw. */
			c->merged_frame.bw         = (int)c->border_width;
			c->merged_frame.fullscreen = c->fullscreen;
			for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP;
			     bar < CLIENT_TITLEBAR_COUNT; bar++)
				c->merged_frame.titlebar_size[bar] = c->titlebar[bar].size;
			c->merged_frame.valid = true;
		}
	}

	/* Debug view: draw Clay's injected RECTANGLE/BORDER/TEXT/SCISSOR commands
	 * (the inspector panel + hover highlight) into the per-screen overlay. Only
	 * the screen-composition solve drives it (debug_compose_solve), so a
	 * placement / magnifier solve sharing this context neither renders nor
	 * triggers the self-disable path below. Clay can self-disable from inside
	 * Clay_EndLayout (the panel close button), so read the flag back: when it
	 * flips off under us, sync our flag, hide the overlay, and request a full
	 * arrange so windows reflow to full width. */
	if (cs->debug_compose_solve) {
		if (Clay_IsDebugModeEnabled()) {
			clay_render_debug_overlay(cs, commands,
			                          (int)cs->dim_w, (int)cs->dim_h);
		} else if (clay_debug_enabled) {
			clay_debug_enabled = false;
			clay_debug_dirty = false;
			clay_debug_reflow_pending = true;
			clay_debug_hide_overlay(cs);
		} else {
			clay_debug_hide_overlay(cs);
		}
	}

	/* A debug-only overlay refresh (pointer motion) must not arm the deferred
	 * apply: geometry is unchanged from the last real arrange, so leaving
	 * has_pending set would re-run client_resize on the next clay_apply_all.
	 * Results stay stored and are released by the next begin_layout. */
	if (!cs->debug_only_solve)
		active_screen->has_pending = true;

	/* Return value 1: the workarea bounds as a table (or nil). A workarea
	 * element lets compose_screen() read screen.workarea without waiting for
	 * clay_apply_all(). */
	clay_result_t *wa = NULL;
	for (int j = 0; j < active_screen->results_count; j++) {
		if (active_screen->results[j].type == CLAY_ELEM_WORKAREA) {
			wa = &active_screen->results[j];
			break;
		}
	}
	if (wa) {
		/* Inner bounds (bounding box minus padding). */
		lua_newtable(L);
		lua_pushnumber(L, wa->x + wa->pad_left + active_screen->offset_x);
		lua_setfield(L, -2, "x");
		lua_pushnumber(L, wa->y + wa->pad_top + active_screen->offset_y);
		lua_setfield(L, -2, "y");
		lua_pushnumber(L, wa->w - wa->pad_left - wa->pad_right);
		lua_setfield(L, -2, "width");
		lua_pushnumber(L, wa->h - wa->pad_top - wa->pad_bottom);
		lua_setfield(L, -2, "height");
	} else {
		lua_pushnil(L);
	}

	/* Return value 2: widget boxes as a list of { widget, x, y, width, height }
	 * in solve-local coords. Lets a screen solve (compose_screen) feed wibar
	 * widget boxes back into the widget hierarchy for paint instead of the
	 * per-container "wibox" solve forest recomputing them. Read the widget
	 * objects (not the registry ref) into the list; clay_apply_all() unrefs
	 * the registry slots afterward, the objects stay alive via this table. */
	lua_newtable(L);
	int widget_idx = 1;
	for (int j = 0; j < active_screen->results_count; j++) {
		clay_result_t *r = &active_screen->results[j];
		if (r->type != CLAY_ELEM_WIDGET || r->lua_ref == LUA_NOREF)
			continue;
		lua_newtable(L);
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
		lua_rawseti(L, -2, widget_idx++);
	}

	active_screen = NULL;
	return 2;
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

/* _somewm_clay.mark_stale(screen) - flag the screen's layout for the next drain.
 * Set by awful.layout.arrange; clay_drain_stale_screens() recomputes it. */
static int
luaA_clay_mark_stale(lua_State *L)
{
	screen_t *s = luaA_checkscreen(L, 1);
	if (s)
		s->layout_stale = true;
	return 0;
}

/* _somewm_clay.is_stale(screen) - true if the screen is marked for a drain. */
static int
luaA_clay_is_stale(lua_State *L)
{
	screen_t *s = luaA_checkscreen(L, 1);
	lua_pushboolean(L, s && s->layout_stale);
	return 1;
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
	PUSH(merged);
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

/* _somewm_clay.set_debug_enabled(bool) - turn the Clay debug view on/off. The
 * per-context Clay_SetDebugModeEnabled happens in begin_layout; this sets the
 * flag the per-screen solves read. The Lua caller (awful.layout.clay.set_debug)
 * triggers a normal arrange afterward so windows reflow and the panel appears
 * or hides. */
static int
luaA_clay_set_debug_enabled(lua_State *L)
{
	clay_debug_enabled = lua_toboolean(L, 1);
	clay_debug_dirty = true;
	return 0;
}

/* _somewm_clay.is_debug_enabled() -> bool */
static int
luaA_clay_is_debug_enabled(lua_State *L)
{
	lua_pushboolean(L, clay_debug_enabled);
	return 1;
}

/* _somewm_clay.set_debug_resolver(fn) - store the Lua callback clay_debug_tick
 * invokes to rebuild + re-solve screens. fn(reflow): reflow=true arranges all
 * screens (after a self-disable, to reflow back to full width); reflow=false
 * refreshes the debug overlay (no_apply). Clay can't rebuild its element tree
 * alone, so the re-solve must round-trip through Lua. */
static int
luaA_clay_set_debug_resolver(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TFUNCTION);
	if (clay_debug_resolver_ref != LUA_NOREF)
		luaL_unref(L, LUA_REGISTRYINDEX, clay_debug_resolver_ref);
	lua_pushvalue(L, 1);
	clay_debug_resolver_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

/* Flag a pending debug-overlay re-solve. Called from the pointer/button input
 * path; no-ops unless debug is on, so it's cheap on that hot path. */
void
clay_debug_mark_dirty(void)
{
	if (clay_debug_enabled)
		clay_debug_dirty = true;
}

/* Helper: call the Lua resolver with a single boolean (reflow) argument. */
static void
clay_debug_call_resolver(lua_State *L, bool reflow)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, clay_debug_resolver_ref);
	lua_pushboolean(L, reflow);
	if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
		fprintf(stderr, "[clay] debug resolver error: %s\n",
		        lua_tostring(L, -1));
		lua_pop(L, 1);
	}
}

/* Drive debug re-solves once per event-loop iteration (coalesces high-frequency
 * pointer motion). Called from some_refresh() after clay_apply_all(). The
 * resolver rebuilds the Clay tree so end_layout re-renders the overlay; the
 * overlay refresh runs no_apply, so this never moves clients. */
void
clay_debug_tick(void)
{
	if (clay_debug_resolver_ref == LUA_NOREF)
		return;

	lua_State *L = globalconf_get_lua_State();

	/* A self-disable (panel close button) requests a full arrange so windows
	 * reflow back to full width. If debug was re-enabled before this tick (rapid
	 * close-then-toggle), the reflow is stale -- the re-enable's own arrange
	 * handles the layout -- so clear it without arranging. */
	if (clay_debug_reflow_pending) {
		clay_debug_reflow_pending = false;
		if (!clay_debug_enabled)
			clay_debug_call_resolver(L, true);
	}

	if (!clay_debug_enabled || !clay_debug_dirty)
		return;
	clay_debug_dirty = false;
	clay_debug_call_resolver(L, false);
}

/* Composite each screen's debug overlay onto a screenshot cairo context. The
 * overlay is a standalone scene buffer (not a client surface or a registered
 * drawin), so root.content()'s scene-buffer and widget passes don't capture it;
 * this draws the cached cairo surface directly. Called last, so the inspector
 * lands on top exactly as it does on screen. No-op when debug is off (no
 * enabled overlay). */
void
clay_debug_composite_screenshot(cairo_t *cr)
{
	for (int i = 0; i < screen_count; i++) {
		clay_screen_t *cs = &screens[i];
		if (!cs->debug_surface || !cs->debug_overlay
		    || !cs->debug_overlay->node.enabled)
			continue;
		cairo_save(cr);
		cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
		cairo_set_source_surface(cr, cs->debug_surface,
		                         (double)cs->offset_x, (double)cs->offset_y);
		cairo_paint(cr);
		cairo_restore(cr);
	}
}

static const luaL_Reg clay_methods[] = {
	{ "begin_layout", luaA_clay_begin_layout },
	{ "open_container", luaA_clay_open_container },
	{ "close_container", luaA_clay_close_container },
	{ "client_element", luaA_clay_client_element },
	{ "client_open", luaA_clay_client_open },
	{ "client_close", luaA_clay_client_close },
	{ "frame_box", luaA_clay_frame_box },
	{ "titlebar_open", luaA_clay_titlebar_open },
	{ "titlebar_close", luaA_clay_titlebar_close },
	{ "client_frame_sizes", luaA_clay_client_frame_sizes },
	{ "client_frame_geometry", luaA_clay_client_frame_geometry },
	{ "drawin_element", luaA_clay_drawin_element },
	{ "drawin_open", luaA_clay_drawin_open },
	{ "drawin_close", luaA_clay_drawin_close },
	{ "widget_element", luaA_clay_widget_element },
	{ "widget_open", luaA_clay_widget_open },
	{ "widget_close", luaA_clay_widget_close },
	{ "workarea_element", luaA_clay_workarea_element },
	{ "workarea_open", luaA_clay_workarea_open },
	{ "workarea_close", luaA_clay_workarea_close },
	{ "end_layout", luaA_clay_end_layout },
	{ "end_layout_to_lua", luaA_clay_end_layout_to_lua },
	{ "set_screen_workarea", luaA_clay_set_screen_workarea },
	{ "layer_exclusive", luaA_clay_layer_exclusive },
	{ "apply_all", luaA_clay_apply_all },
	{ "mark_stale", luaA_clay_mark_stale },
	{ "is_stale", luaA_clay_is_stale },
	{ "get_solve_counts", luaA_clay_get_solve_counts },
	{ "reset_solve_counts", luaA_clay_reset_solve_counts },
	{ "set_debug_enabled", luaA_clay_set_debug_enabled },
	{ "is_debug_enabled", luaA_clay_is_debug_enabled },
	{ "set_debug_resolver", luaA_clay_set_debug_resolver },
	{ NULL, NULL }
};

void
luaA_clay_setup(lua_State *L)
{
	lua_newtable(L);
	luaL_setfuncs(L, clay_methods, 0);

	/* Frame roles for frame_box(role, ...), mirroring the CFRAME_* enum so
	 * Lua never hardcodes the integers. */
	lua_newtable(L);
#define FRAME_CONST(name, val) do { lua_pushinteger(L, (val)); \
	lua_setfield(L, -2, name); } while (0)
	FRAME_CONST("titlebar_top",    CFRAME_TITLEBAR_TOP);
	FRAME_CONST("titlebar_right",  CFRAME_TITLEBAR_RIGHT);
	FRAME_CONST("titlebar_bottom", CFRAME_TITLEBAR_BOTTOM);
	FRAME_CONST("titlebar_left",   CFRAME_TITLEBAR_LEFT);
	FRAME_CONST("surface",         CFRAME_SURFACE);
#undef FRAME_CONST
	lua_setfield(L, -2, "frame");

	lua_setglobal(L, "_somewm_clay");
}

/* Slow path only: a detected tree != scene mismatch is "expected" when the Lua
 * allow-list (_somewm_clay.assert_allowed(what, obj)) tolerates this node, e.g. a
 * layout not yet reflected in the Clay tree. A missing predicate or a Lua error
 * means "not allowed", so a real regression is never silently swallowed. r is
 * always a CLIENT or DRAWIN here (the assert skips the ref-less types), so its
 * lua_ref is the live object to hand the predicate. */
static bool
clay_assert_node_allowed(lua_State *L, clay_result_t *r)
{
	if (!L || r->lua_ref == LUA_NOREF)
		return false;
	lua_getglobal(L, "_somewm_clay");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return false;
	}
	lua_getfield(L, -1, "assert_allowed");
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 2);
		return false;
	}
	lua_pushstring(L, r->type == CLAY_ELEM_CLIENT ? "client" : "drawin");
	lua_rawgeti(L, LUA_REGISTRYINDEX, r->lua_ref);
	bool allowed = false;
	if (lua_pcall(L, 2, 1, 0) == 0)
		allowed = lua_toboolean(L, -1);
	lua_pop(L, 2);  /* call result (or error message) + _somewm_clay */
	return allowed;
}

/* Tree == scene assertion: check that the box Clay solved for a result matches the
 * geometry clay_apply_all() assigned it, keeping the scene a 1:1 reflection of the
 * solve. Apply insets a client by its border (the assigned width/height are the
 * solved box minus 2*border_width), so the scene box is reconstructed as
 * geometry + 2*border_width; drawins are applied 1:1. WIDGET/WORKAREA results carry
 * no scene geometry and are skipped. The caller runs this only after a client/drawin
 * apply that actually took effect, so it does not re-check managed-ness. A mismatch
 * over 1px (absorbs apply's float->int truncation) is reported unless the Lua
 * allow-list expects it; it then warns, or aborts in ABORT mode; OFF short-circuits. */
static void
clay_assert_node(lua_State *L, clay_screen_t *cs, clay_result_t *r)
{
	if (clay_tree_assert_mode == CLAY_TREE_ASSERT_OFF)
		return;

	int ax, ay, aw, ah;
	const char *what, *id = "";

	if (r->type == CLAY_ELEM_CLIENT) {
		if (!r->client)
			return;
		int bw2 = r->client->border_width * 2;
		ax = r->client->geometry.x;
		ay = r->client->geometry.y;
		aw = r->client->geometry.width + bw2;
		ah = r->client->geometry.height + bw2;
		what = "client";
		id = NONULL(r->client->name);
	} else if (r->type == CLAY_ELEM_DRAWIN) {
		if (!r->drawin)
			return;
		ax = r->drawin->x;
		ay = r->drawin->y;
		aw = r->drawin->width;
		ah = r->drawin->height;
		what = "drawin";
	} else {
		/* WIDGET / WORKAREA / any future type: no scene geometry to check. */
		return;
	}

	int sx = (int)(r->x + cs->offset_x);
	int sy = (int)(r->y + cs->offset_y);
	int sw = (int)r->w;
	int sh = (int)r->h;

	if (abs(sx - ax) <= 1 && abs(sy - ay) <= 1 &&
	    abs(sw - aw) <= 1 && abs(sh - ah) <= 1)
		return;

	if (clay_assert_node_allowed(L, r))
		return;

	warn("clay tree!=scene: %s '%s' solved %dx%d+%d+%d != scene %dx%d+%d+%d",
	     what, id, sw, sh, sx, sy, aw, ah, ax, ay);

	if (clay_tree_assert_mode == CLAY_TREE_ASSERT_ABORT)
		abort();
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
				if (client_is_managed(r->client)) {
					int bw2 = r->client->border_width * 2;
					area_t geo = {
						.x = x,
						.y = y,
						.width  = MAX(1, w - bw2),
						.height = MAX(1, h - bw2),
					};
					/* Assert tree == scene only when the resize was
					 * actually applied; a declined resize leaves stale
					 * geometry that is not a solve mismatch. */
					if (client_resize(r->client, geo, false, true))
						clay_assert_node(L, cs, r);
				}
				/* else: stale (client unmanaged between end_layout
				 * and here); skip apply, fall through to unref. */
			} else if (r->type == CLAY_ELEM_DRAWIN) {
				if (luaA_drawin_set_geometry(L, r->drawin, x, y, w, h))
					clay_assert_node(L, cs, r);
			}
			/* CLAY_ELEM_WORKAREA and CLAY_ELEM_WIDGET: not applied by C */

			if (r->lua_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, r->lua_ref);
		}
		cs->results_count = 0;
		cs->has_pending = false;
	}
}

/* Recompute one screen's layout via Lua (awful.layout._recompute_screen, exposed
 * as _somewm_clay.recompute_screen). Mirrors clay_assert_node_allowed's lookup; a
 * missing function or a Lua error is swallowed (warned) so one screen's failure
 * cannot abort the drain or block the other screens. */
static void
clay_call_recompute_screen(lua_State *L, screen_t *s)
{
	if (!L || !s)
		return;
	lua_getglobal(L, "_somewm_clay");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return;
	}
	lua_getfield(L, -1, "recompute_screen");
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 2);
		return;
	}
	luaA_screen_push(L, s);
	if (lua_pcall(L, 1, 0, 0) != 0) {
		const char *err = lua_tostring(L, -1);
		warn("clay drain: recompute_screen failed: %s", err ? err : "?");
		lua_pop(L, 1);  /* error message */
	}
	lua_pop(L, 1);  /* _somewm_clay */
}

/* Drain every screen marked layout_stale: recompute its layout once, this refresh.
 *
 * Re-entrancy contract (decided 2026-06-13): a mark set DURING the drain is left
 * for the NEXT refresh, not chased to a fixpoint. Clearing each flag before its
 * recompute already yields next-tick semantics for a self-re-mark, so this single
 * pass is the least-code path and is inherently bounded: no re-scan, no iteration
 * cap, no runaway re-solve. The one-frame (~16ms) latency for a mid-drain mark is
 * invisible and matches the deferred-refresh model this replaces.
 *
 * Iterates the authoritative screen list (luaA_screen_get_all), not Clay's lazy
 * per-screen array, so a never-solved cold-start screen is still drained. A
 * recompute can remove its own screen (e.g. an output unplug from a Lua handler);
 * screen userdata survives until GC, so the top-of-loop s->valid check safely skips
 * any screen invalidated by an earlier iteration, and _recompute_screen re-checks
 * screen.valid before its post-solve emit so a screen removed during its own
 * recompute is not touched. */
void
clay_drain_stale_screens(void)
{
	lua_State *L = globalconf_get_lua_State();
	if (!L)
		return;

	screen_t *list[MAX_SCREENS];
	int count = MAX_SCREENS;
	luaA_screen_get_all(L, list, &count);

	for (int i = 0; i < count; i++) {
		screen_t *s = list[i];
		if (!s || !s->valid || !s->layout_stale)
			continue;
		/* Clear before recompute so a self-re-mark during the recompute re-arms
		 * the flag for the next refresh instead of looping here. */
		s->layout_stale = false;
		clay_call_recompute_screen(L, s);
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
		free(screens[i].name_pool);
		if (screens[i].debug_overlay)
			wlr_scene_node_destroy(&screens[i].debug_overlay->node);
		if (screens[i].debug_surface)
			cairo_surface_destroy(screens[i].debug_surface);
	}
	memset(screens, 0, sizeof(screens));
	screen_count = 0;
	active_screen = NULL;

	/* Debug-view teardown. The dedicated overlay tree is C-side (survives
	 * a Lua hot-reload otherwise), so drop it for a clean slate; debug starts
	 * off after a reload. Do NOT luaL_unref the resolver: the Lua state is
	 * being abandoned, so just drop the ref like the rest of this function. */
	if (clay_debug_tree) {
		wlr_scene_node_destroy(&clay_debug_tree->node);
		clay_debug_tree = NULL;
	}
	if (clay_debug_scratch_cr) {
		cairo_destroy(clay_debug_scratch_cr);
		clay_debug_scratch_cr = NULL;
	}
	if (clay_debug_scratch_surface) {
		cairo_surface_destroy(clay_debug_scratch_surface);
		clay_debug_scratch_surface = NULL;
	}
	clay_debug_enabled = false;
	clay_debug_dirty = false;
	clay_debug_reflow_pending = false;
	clay_debug_resolver_ref = LUA_NOREF;

	/* Clean up widget context */
	free(widget_ctx.results);
	free(widget_ctx.arena_memory);
	free(widget_ctx.name_pool);
	memset(&widget_ctx, 0, sizeof(widget_ctx));

	/* Clean up frame context */
	free(frame_arena_memory);
	frame_arena_memory = NULL;
	frame_ctx = NULL;

	/* Clear Clay's global context pointer so Clay_MinMemorySize() doesn't
	 * dereference the freed arena on the next clay_get_screen() call. */
	Clay_SetCurrentContext(NULL);
}

static inline Clay_SizingAxis
frame_grow(void)
{
	return (Clay_SizingAxis){ .type = CLAY__SIZING_TYPE_GROW };
}

static inline Clay_SizingAxis
frame_fixed(float v)
{
	return (Clay_SizingAxis){
		.type = CLAY__SIZING_TYPE_FIXED,
		.size.minMax = { v, v },
	};
}

static inline void
frame_open_container(uint32_t id, Clay_LayoutDirection dir, uint16_t pad)
{
	Clay__OpenElementWithId((Clay_ElementId){ .id = id });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = {
			.layoutDirection = dir,
			.sizing = { .width = frame_grow(), .height = frame_grow() },
			.padding = { pad, pad, pad, pad },
		},
	});
}

static inline void
frame_leaf(uint32_t id, intptr_t cd, Clay_SizingAxis w, Clay_SizingAxis h)
{
	Clay__OpenElementWithId((Clay_ElementId){ .id = id });
	Clay__ConfigureOpenElement((Clay_ElementDeclaration){
		.layout = { .sizing = { .width = w, .height = h } },
		.custom = { .customData = (void *)cd },
	});
	Clay__CloseElement();
}

/* Visibility was pre-set for all four titlebars; only writes position when
 * the titlebar is visible. */
static inline void
frame_apply_titlebar_pos(client_t *c, client_titlebar_t bar, int x, int y, bool fs)
{
	if (c->titlebar[bar].scene_buffer
	    && c->titlebar[bar].size > 0 && !fs) {
		wlr_scene_node_set_position(
			&c->titlebar[bar].scene_buffer->node, x, y);
	}
}

/* Emit the frame sub-tree: body column (padded by the border width) {
 * titlebar_top; surface row { tb_left, surface, tb_right }; titlebar_bottom }.
 * The border is not an element: the column's padding insets its children by
 * `fbw`, exactly as the four border leaves used to, and the border rects are
 * positioned by arithmetic in frame_apply_boxes(). `idx` is the owning client's
 * result index in the merged solve (0 for the isolated frame_ctx solve). Element
 * ids and leaf customData are derived from idx so many clients' frame trees stay
 * unique within one solve. */
static void
emit_frame_tree(uint32_t *idc, int idx, float fbw,
                     float ftt, float ftr, float ftb, float ftl)
{
	/* Element ids come from *idc (the merged solve passes its per-solve
	 * element_id_counter so frame ids never collide with client/widget/
	 * container ids; the isolated frame_ctx solve passes a local counter).
	 * Leaf customData carries idx|role for end_layout routing, decoupled from
	 * the id. */
#define FCONT(dir, pad)   frame_open_container(++(*idc), (dir), (pad))
#define FLEAF(role, w, h) frame_leaf(++(*idc), frame_cd(idx, (role)), (w), (h))
	FCONT(CLAY_TOP_TO_BOTTOM, (uint16_t)fbw);           /* body column (border pad) */
		FLEAF(CFRAME_TITLEBAR_TOP, frame_grow(), frame_fixed(ftt));
		FCONT(CLAY_LEFT_TO_RIGHT, 0);                   /* surface row */
			FLEAF(CFRAME_TITLEBAR_LEFT,  frame_fixed(ftl), frame_grow());
			FLEAF(CFRAME_SURFACE,        frame_grow(),     frame_grow());
			FLEAF(CFRAME_TITLEBAR_RIGHT, frame_fixed(ftr), frame_grow());
		Clay__CloseElement();                           /* surface row */
		FLEAF(CFRAME_TITLEBAR_BOTTOM, frame_grow(), frame_fixed(ftb));
	Clay__CloseElement();                               /* body column */
#undef FLEAF
#undef FCONT
}

/* Pre-set titlebar scene-buffer visibility from size + fullscreen. Runs on
 * every frame apply (the solve path and the merged-consume path), outside
 * any cache, so a late scene_buffer init still gets enabled when geometry is
 * unchanged. */
static inline void
frame_preset_titlebars(client_t *c, bool fs)
{
	for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP;
	     bar < CLIENT_TITLEBAR_COUNT; bar++) {
		if (c->titlebar[bar].scene_buffer) {
			bool visible = c->titlebar[bar].size > 0 && !fs;
			wlr_scene_node_set_enabled(
				&c->titlebar[bar].scene_buffer->node, visible);
		}
	}
}

/* Apply frame boxes (frame-relative, indexed by CFRAME_* role) to the client's
 * scene nodes: the 4 titlebar buffers, the surface offset, and the shadow. The 4
 * border rects are positioned by arithmetic from c->geometry + `bw` (the outer
 * ring of c->geometry, the same formula border_width_callback uses), which equals
 * the boxes the border leaves used to solve. Returns the surface inner size
 * (clamped >= 1). Shared by the per-client solve and the merged-solve consume path
 * so both write the scene identically (any drift would flood configures, see
 * window.c). `bw` is c->border_width on the consume path, c->bw on the fallback
 * (zero on fullscreen). */
static void
frame_apply_boxes(client_t *c, const struct frame_box *box, bool fs, int bw,
                  int *out_inner_w, int *out_inner_h)
{
	/* Border ring on c->geometry's perimeter. border[0..3] = TOP, BOTTOM, LEFT,
	 * RIGHT; top/bottom are full-width bw-tall bars, left/right fill between them. */
	int gw = MAX(0, c->geometry.width), gh = MAX(0, c->geometry.height);
	int side_h = MAX(0, gh - 2 * bw);
	wlr_scene_rect_set_size(c->border[0], gw, bw);
	wlr_scene_node_set_position(&c->border[0]->node, 0, 0);
	wlr_scene_rect_set_size(c->border[1], gw, bw);
	wlr_scene_node_set_position(&c->border[1]->node, 0, MAX(0, gh - bw));
	wlr_scene_rect_set_size(c->border[2], bw, side_h);
	wlr_scene_node_set_position(&c->border[2]->node, 0, bw);
	wlr_scene_rect_set_size(c->border[3], bw, side_h);
	wlr_scene_node_set_position(&c->border[3]->node, MAX(0, gw - bw), bw);
	frame_apply_titlebar_pos(c, CLIENT_TITLEBAR_TOP,
		box[CFRAME_TITLEBAR_TOP].x, box[CFRAME_TITLEBAR_TOP].y, fs);
	frame_apply_titlebar_pos(c, CLIENT_TITLEBAR_RIGHT,
		box[CFRAME_TITLEBAR_RIGHT].x, box[CFRAME_TITLEBAR_RIGHT].y, fs);
	frame_apply_titlebar_pos(c, CLIENT_TITLEBAR_BOTTOM,
		box[CFRAME_TITLEBAR_BOTTOM].x, box[CFRAME_TITLEBAR_BOTTOM].y, fs);
	frame_apply_titlebar_pos(c, CLIENT_TITLEBAR_LEFT,
		box[CFRAME_TITLEBAR_LEFT].x, box[CFRAME_TITLEBAR_LEFT].y, fs);

	wlr_scene_node_set_position(&c->scene_surface->node,
		box[CFRAME_SURFACE].x, box[CFRAME_SURFACE].y);
	int iw = box[CFRAME_SURFACE].w < 1 ? 1 : box[CFRAME_SURFACE].w;
	int ih = box[CFRAME_SURFACE].h < 1 ? 1 : box[CFRAME_SURFACE].h;
	if (out_inner_w) *out_inner_w = iw;
	if (out_inner_h) *out_inner_h = ih;

	/* Shadow: 9-slice with signed offsets, stays in shadow.c. */
	const shadow_config_t *shadow_config = shadow_get_effective_config(
		c->shadow_config, false);
	if (shadow_config && shadow_config->enabled) {
		if (c->shadow.tree)
			shadow_update_geometry(&c->shadow, shadow_config,
				c->geometry.width, c->geometry.height);
		else
			shadow_create(c->scene, &c->shadow, shadow_config,
				c->geometry.width, c->geometry.height);
	}
}

void
clay_apply_client_frame(client_t *c, int *out_inner_w, int *out_inner_h)
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

	frame_preset_titlebars(c, fs);

	/* Frame cache: skip the Clay solve and the scene-graph mutations when
	 * nothing the tree depends on has changed. The scene positions from the
	 * last solve are still valid (no other path touches the border/titlebar/
	 * surface child positions inside c->scene). */
	if (c->frame_cache.valid
	    && c->frame_cache.width      == geo_w
	    && c->frame_cache.height     == geo_h
	    && c->frame_cache.bw         == bw_i
	    && c->frame_cache.fullscreen == fs
	    && memcmp(c->frame_cache.titlebar_size, ts, sizeof(ts)) == 0) {
		if (out_inner_w) *out_inner_w = c->frame_cache.inner_w;
		if (out_inner_h) *out_inner_h = c->frame_cache.inner_h;
		return;
	}

	if (!frame_ctx) {
		uint32_t mem_size = Clay_MinMemorySize();
		frame_arena_memory = malloc(mem_size);
		Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
			mem_size, frame_arena_memory);
		frame_ctx = Clay_Initialize(
			arena,
			(Clay_Dimensions){ (float)geo_w, (float)geo_h },
			(Clay_ErrorHandler){ clay_error_handler, NULL });
		Clay_SetCurrentContext(frame_ctx);
		Clay_SetMeasureTextFunction(clay_measure_text, NULL);
	}

	Clay_SetCurrentContext(frame_ctx);
	Clay_SetLayoutDimensions((Clay_Dimensions){ (float)geo_w, (float)geo_h });
	Clay_BeginLayout();
	/* Per-client fallback frame solve; counted as "decoration" -- the stable
	 * get_solve_counts() proof key for clients not in the merged tree. */
	solve_counters.decoration++;
	solve_counters.total++;

	uint32_t didc = 0; /* local id counter for the isolated frame_ctx solve */
	emit_frame_tree(&didc, 0, fbw, ftt, ftr, ftb, ftl);

	Clay_RenderCommandArray commands = Clay_EndLayout();

	/* Collect frame boxes by role. emit_frame_tree packs the role into
	 * the customData high bits (frame_cd, idx == 0 on this isolated solve), so
	 * decode it the same way end_layout does. */
	struct frame_box box[6] = { 0 };
	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM)
			continue;
		uint32_t cd = (uint32_t)(intptr_t)cmd->renderData.custom.customData;
		int role = (int)(cd >> CLAY_FRAME_ROLE_SHIFT);
		if (role < CFRAME_TITLEBAR_TOP || role > CFRAME_SURFACE)
			continue;
		box[role] = (struct frame_box){
			(int)cmd->boundingBox.x, (int)cmd->boundingBox.y,
			(int)cmd->boundingBox.width, (int)cmd->boundingBox.height,
		};
	}

	int final_inner_w = 0, final_inner_h = 0;
	frame_apply_boxes(c, box, fs, bw_i, &final_inner_w, &final_inner_h);
	if (out_inner_w) *out_inner_w = final_inner_w;
	if (out_inner_h) *out_inner_h = final_inner_h;

	/* Stamp the cache so the next call with the same inputs short-circuits. */
	c->frame_cache.width      = geo_w;
	c->frame_cache.height     = geo_h;
	c->frame_cache.bw         = bw_i;
	c->frame_cache.fullscreen = fs;
	memcpy(c->frame_cache.titlebar_size, ts, sizeof(ts));
	c->frame_cache.inner_w    = final_inner_w;
	c->frame_cache.inner_h    = final_inner_h;
	c->frame_cache.valid      = true;
}

/* Apply frame boxes computed by the merged screen solve (stored in
 * c->merged_frame by end_layout) instead of running the per-client frame
 * solve. Returns false when the scratch is missing or stale for the live client
 * state, so the caller falls back to clay_apply_client_frame(). Like that
 * function it pre-sets titlebar visibility on every call (outside the key check)
 * so a late scene_buffer init still gets enabled. */
bool
clay_consume_merged_frame(client_t *c, int *out_inner_w, int *out_inner_h)
{
	bool fs = c->fullscreen;

	if (!c->merged_frame.valid
	    || c->merged_frame.geo_w      != c->geometry.width
	    || c->merged_frame.geo_h      != c->geometry.height
	    || c->merged_frame.bw         != (int)c->border_width
	    || c->merged_frame.fullscreen != fs)
		return false;
	for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP;
	     bar < CLIENT_TITLEBAR_COUNT; bar++) {
		if (c->merged_frame.titlebar_size[bar] != c->titlebar[bar].size)
			return false;
	}

	/* Preset runs only on the consuming path; the fallback presets itself.
	 * Either way it runs once per call (the late-scene_buffer-init invariant). */
	frame_preset_titlebars(c, fs);
	frame_apply_boxes(c, c->merged_frame.box, fs, (int)c->border_width,
	                  out_inner_w, out_inner_h);
	return true;
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
			.sizing = { .width = frame_grow(), .height = frame_grow() },
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
					.width  = frame_fixed((float)target_w),
					.height = frame_fixed((float)target_h),
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
