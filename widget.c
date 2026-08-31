/*
 * widget.c - the widget-tree-to-Clay compile step's C half
 *
 * lua/wibox/clay.lua walks a drawable's widget tree and describes the front
 * of it as a chain of containers Clay can solve. This file stores that
 * description on the drawin, declares it into the output's tree, and answers
 * the test readback. It never draws and never measures: a node is pure
 * description, and what the chain does not reach stays on the drawable's own
 * surface, declared as the chain's innermost leaf.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <lauxlib.h>

#include "luaa.h"

#include "clay.h"
#include "widget.h"
#include "common/util.h"
#include "declare.h"
#include "monitor.h"
#include "objects/drawin.h"
#include "objects/screen.h"

/* somewm colors are straight-alpha 0-1 floats; Clay_Color is 0-255. */
static Clay_Color
clay_color(const float rgba[4])
{
	return (Clay_Color) {
		rgba[0] * 255.0f, rgba[1] * 255.0f,
		rgba[2] * 255.0f, rgba[3] * 255.0f,
	};
}

/* --- reading a chain off the Lua stack --- */

/* A four-number array field (pad, bw, bg, border), or all zeroes when the
 * field is absent. False for a field that is present but not four numbers,
 * which is a compile-step bug rather than a config the walk should ride out. */
static bool
read_quad(lua_State *L, int idx, const char *name, float *out)
{
	bool ok = true;

	lua_getfield(L, idx, name);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return true;
	}
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return false;
	}
	for (int i = 0; i < 4; i++) {
		lua_rawgeti(L, -1, i + 1);
		if (lua_isnumber(L, -1))
			out[i] = (float)lua_tonumber(L, -1);
		else
			ok = false;
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return ok;
}

static bool
read_node(lua_State *L, int idx, struct widget_node *n)
{
	float pad[4] = { 0 }, bw[4] = { 0 };

	if (!lua_istable(L, idx))
		return false;
	if (!read_quad(L, idx, "pad", pad) || !read_quad(L, idx, "bw", bw)
			|| !read_quad(L, idx, "bg", n->bg)
			|| !read_quad(L, idx, "border", n->border))
		return false;
	for (int i = 0; i < 4; i++) {
		if (pad[i] < 0 || pad[i] > UINT16_MAX
				|| bw[i] < 0 || bw[i] > UINT16_MAX)
			return false;
		n->pad[i] = (uint16_t)pad[i];
		n->bw[i] = (uint16_t)bw[i];
	}

	lua_getfield(L, idx, "radius");
	n->radius = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : 0.0f;
	lua_pop(L, 1);

	lua_getfield(L, idx, "raster");
	n->raster = lua_toboolean(L, -1);
	lua_pop(L, 1);

	return n->radius >= 0;
}

void
widget_nodes_clear(drawin_t *d)
{
	p_delete(&d->widget_nodes);
	d->widget_nodes_len = 0;
}

size_t
widget_nodes_len(const drawin_t *d)
{
	return d->widget_nodes_len;
}

bool
widget_nodes_set(lua_State *L, drawin_t *d, int idx)
{
	struct widget_node nodes[WIDGET_NODES_MAX];
	size_t len;

	/* A shape is applied to the drawable's own pixels, and a converted
	 * container is no longer among them. */
	if (d->shape_bounding || d->shape_clip || d->shape_input) {
		widget_nodes_clear(d);
		return false;
	}

	if (idx < 0)
		idx = lua_gettop(L) + 1 + idx;
	if (!lua_istable(L, idx)) {
		widget_nodes_clear(d);
		return false;
	}

	len = luaA_rawlen(L, idx);
	if (len < 2 || len > WIDGET_NODES_MAX) {
		widget_nodes_clear(d);
		return false;
	}

	memset(nodes, 0, sizeof(nodes));
	for (size_t i = 0; i < len; i++) {
		bool ok;

		lua_rawgeti(L, idx, (int)i + 1);
		ok = read_node(L, lua_gettop(L), &nodes[i]);
		lua_pop(L, 1);
		if (!ok) {
			widget_nodes_clear(d);
			return false;
		}
	}
	/* The leaf is the chain's whole point: without it the drawable's
	 * pixels would have nowhere to land. */
	if (!nodes[len - 1].raster) {
		widget_nodes_clear(d);
		return false;
	}

	if (d->widget_nodes_len == len
			&& memcmp(d->widget_nodes, nodes, len * sizeof(*nodes)) == 0)
		return true;

	widget_nodes_clear(d);
	d->widget_nodes = p_new(struct widget_node, len);
	memcpy(d->widget_nodes, nodes, len * sizeof(*nodes));
	d->widget_nodes_len = len;
	/* A container's color or margin can change with no pixel in the
	 * drawable's surface changing, so the chain has to wake the frame path
	 * on its own; drawable:refresh() only speaks for the leaf. */
	if (d->screen && d->screen->monitor && d->screen->monitor->declare)
		declare_output_mark_dirty(d->screen->monitor->declare);
	return true;
}

/* --- declaring the chain --- */

/* The parts every node shares. The id mixes the drawin's registry id with
 * the node's depth, so a chain that grows or shrinks renames nothing above
 * the change and the reconciler keeps the nodes it already has. */
static Clay_ElementDeclaration
node_decl(const struct widget_node *n, uint32_t id, size_t depth)
{
	Clay_ElementDeclaration e = {
		.id = Clay__HashString(CLAY_STRING("drawin.widget"), id,
			(uint32_t)depth),
		.layout = {
			.sizing = {
				.width = CLAY_SIZING_GROW(0),
				.height = CLAY_SIZING_GROW(0),
			},
			.padding = { n->pad[0], n->pad[1], n->pad[2], n->pad[3] },
		},
		.cornerRadius = { n->radius, n->radius, n->radius, n->radius },
	};

	if (n->bg[3] > 0)
		e.backgroundColor = clay_color(n->bg);
	if (n->border[3] > 0) {
		e.border.color = clay_color(n->border);
		e.border.width = (Clay_BorderWidth) {
			n->bw[0], n->bw[1], n->bw[2], n->bw[3], 0 };
	}
	return e;
}

/* Open every node, then close them all: the chain is a list, so each node is
 * the previous one's only child. */
void
widget_declare(drawin_t *d, uint32_t id, int16_t z, int x, int y,
	void *leaf_userdata)
{
	size_t len = d->widget_nodes_len;

	for (size_t i = 0; i < len; i++) {
		const struct widget_node *n = &d->widget_nodes[i];
		Clay_ElementDeclaration e = node_decl(n, id, i);

		if (i == 0) {
			/* The drawin's box is somewm's, not Clay's: a fixed
			 * floating leaf at the geometry rc.lua set, so Clay
			 * places the chain without solving for it. */
			e.layout.sizing.width = CLAY_SIZING_FIXED(d->width);
			e.layout.sizing.height = CLAY_SIZING_FIXED(d->height);
			e.floating.offset = (Clay_Vector2) { x, y };
			e.floating.attachTo = CLAY_ATTACH_TO_ROOT;
			e.floating.zIndex = z;
		}
		if (n->raster) {
			e.image.imageData = &d->content_entry;
			e.userData = leaf_userdata;
		}
		Clay__OpenElement();
		Clay__ConfigureOpenElementPtr(&e);
	}
	while (len-- > 0)
		Clay__CloseElement();
}

/* --- the test readback --- */

static void
solve_error(Clay_ErrorData error)
{
	fatal("clay error %d: %.*s", error.errorType, error.errorText.length,
		error.errorText.chars);
}

int
widget_solve_boxes(drawin_t *d, int (*boxes)[4], int cap)
{
	Clay_Context *previous = Clay_GetCurrentContext();
	uint32_t arena_size = Clay_MinMemorySize();
	void *arena = p_new(char, arena_size);
	int n = 0;

	Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(arena_size, arena),
		(Clay_Dimensions) { d->width, d->height },
		(Clay_ErrorHandler) { .errorHandlerFunction = solve_error });
	Clay_SetCullingEnabled(false);

	Clay_BeginLayout();
	widget_declare(d, 1, 0, 0, 0, NULL);
	Clay_EndLayout();

	for (size_t i = 0; i < d->widget_nodes_len && n < cap; i++) {
		Clay_ElementData data = Clay_GetElementData(
			Clay__HashString(CLAY_STRING("drawin.widget"), 1,
				(uint32_t)i));

		if (!data.found)
			continue;
		/* Clay solves float32; round here so a box crossing into Lua
		 * is the whole pixel the old layout would have placed. */
		boxes[n][0] = (int)floorf(data.boundingBox.x + 0.5f);
		boxes[n][1] = (int)floorf(data.boundingBox.y + 0.5f);
		boxes[n][2] = (int)floorf(data.boundingBox.width + 0.5f);
		boxes[n][3] = (int)floorf(data.boundingBox.height + 0.5f);
		n++;
	}

	Clay_SetCurrentContext(previous);
	p_delete(&arena);
	return n;
}
