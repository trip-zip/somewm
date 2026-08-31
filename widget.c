/*
 * widget.c - the widget chain lua/wibox/clay.lua compiles
 *
 * lua/wibox/clay.lua walks a drawable's widget tree and describes the front
 * of it as a chain of containers Clay can solve. This file reads that
 * description off the Lua stack and stores it on the drawin. It holds no
 * Clay: declaring the chain is declare.c's and drawing it is the renderer's,
 * so a node here is nothing but the numbers Lua handed over.
 */

#include <string.h>

#include <lauxlib.h>

#include "luaa.h"

#include "widget.h"
#include "common/util.h"
#include "declare.h"
#include "monitor.h"
#include "objects/drawin.h"
#include "objects/screen.h"

/* A four-number array field (pad, bw, bg, border), left at zero when the
 * field is absent. False for a field that is present but not four numbers,
 * which is a compile-step bug rather than a config to ride out. */
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

/* The whole array at idx into nodes, or false for anything that is not a
 * chain: a chain holds at least a root and the raster leaf that carries the
 * drawable's own pixels, and the leaf is always last. */
static bool
read_chain(lua_State *L, int idx, struct widget_node *nodes, size_t *out_len)
{
	size_t len;

	if (!lua_istable(L, idx))
		return false;

	len = luaA_rawlen(L, idx);
	if (len < 2 || len > WIDGET_NODES_MAX)
		return false;

	memset(nodes, 0, len * sizeof(*nodes));
	for (size_t i = 0; i < len; i++) {
		bool ok;

		lua_rawgeti(L, idx, (int)i + 1);
		ok = read_node(L, lua_gettop(L), &nodes[i]);
		lua_pop(L, 1);
		if (!ok)
			return false;
	}
	if (!nodes[len - 1].raster)
		return false;

	*out_len = len;
	return true;
}

void
widget_nodes_clear(drawin_t *d)
{
	p_delete(&d->widget_nodes);
	d->widget_nodes_len = 0;
	d->widget_nodes_declared = false;
}

bool
widget_nodes_set(lua_State *L, drawin_t *d, int idx)
{
	struct widget_node nodes[WIDGET_NODES_MAX];
	size_t len;

	/* A shape is applied to the drawable's own pixels, and a converted
	 * container is no longer among them. */
	if (d->shape_bounding || d->shape_clip || d->shape_input
			|| !read_chain(L, idx, nodes, &len)) {
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
