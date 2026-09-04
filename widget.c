/*
 * widget.c - the widget tree lua/wibox/clay.lua compiles
 *
 * lua/wibox/clay.lua walks a drawable's widget tree and describes what Clay
 * can solve as a tree of nodes, with every subtree it cannot express as a
 * raster leaf. This file reads that description off the Lua stack, stores it
 * on the drawin, and owns the leaf surfaces Lua draws into. It holds no Clay:
 * declaring the tree is declare.c's and drawing it is the renderer's, so a
 * node here is nothing but the numbers Lua handed over.
 */

#include <string.h>

#include <lauxlib.h>

#include "luaa.h"

#include "widget.h"
#include "common/util.h"
#include "declare.h"
#include "globalconf.h"
#include "monitor.h"
#include "render.h"
#include "objects/drawable.h"
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

/* An optional number field inside a range, false for one outside it or of
 * the wrong type. Refusing rather than raising is what lets a malformed
 * tree fall back to painting whole: an error here unwinds through the
 * redraw that already dropped its dirty region, leaving the last tree
 * declared and nothing repainting it. */
static bool
read_number(lua_State *L, int idx, const char *name, double min, double max,
	float *out)
{
	bool ok;

	lua_getfield(L, idx, name);
	if (lua_isnumber(L, -1)) {
		double v = lua_tonumber(L, -1);

		ok = v >= min && v <= max;
		*out = (float)v;
	} else {
		ok = lua_isnil(L, -1);
	}
	lua_pop(L, 1);
	return ok;
}

/* One axis of sizing: a number for a fixed size, absent to grow, which is
 * what a container's only child does. */
static bool
read_sizing(lua_State *L, int idx, const char *name, bool *fixed, float *size)
{
	bool ok;

	lua_getfield(L, idx, name);
	*fixed = lua_type(L, -1) == LUA_TNUMBER;
	*size = *fixed ? (float)lua_tonumber(L, -1) : 0.0f;
	ok = lua_isnil(L, -1) || (*fixed && *size >= 0);
	lua_pop(L, 1);
	return ok;
}

/* Child alignment on one axis, named as wibox.container.place names it, as
 * Clay's own enum value: Clay_LayoutAlignmentX and Y both order their
 * enumerators start, end, center. */
static bool
read_align(lua_State *L, int idx, const char *name, uint8_t *out)
{
	const char *s;
	bool ok = true;

	lua_getfield(L, idx, name);
	s = lua_tostring(L, -1);
	if (!s || strcmp(s, "left") == 0 || strcmp(s, "top") == 0)
		*out = 0;
	else if (strcmp(s, "right") == 0 || strcmp(s, "bottom") == 0)
		*out = 1;
	else if (strcmp(s, "center") == 0)
		*out = 2;
	else
		ok = false;
	lua_pop(L, 1);
	return ok;
}

static bool
read_node(lua_State *L, int idx, struct widget_node *n)
{
	float pad[4] = { 0 }, bw[4] = { 0 }, gap = 0;
	const char *dir;
	bool ok;

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

	if (!read_number(L, idx, "radius", 0, 1e6, &n->radius)
			|| !read_number(L, idx, "gap", 0, UINT16_MAX, &gap)
			|| !read_number(L, idx, "wmax", 0, 1e6, &n->max[0])
			|| !read_number(L, idx, "hmax", 0, 1e6, &n->max[1]))
		return false;
	n->gap = (uint16_t)gap;
	if (!read_sizing(L, idx, "w", &n->fixed[0], &n->size[0])
			|| !read_sizing(L, idx, "h", &n->fixed[1], &n->size[1]))
		return false;

	lua_getfield(L, idx, "align");
	ok = lua_isnil(L, -1) || (lua_istable(L, -1)
		&& read_align(L, lua_gettop(L), "x", &n->align[0])
		&& read_align(L, lua_gettop(L), "y", &n->align[1]));
	lua_pop(L, 1);

	lua_getfield(L, idx, "dir");
	dir = lua_tostring(L, -1);
	n->vertical = dir && strcmp(dir, "y") == 0;
	lua_pop(L, 1);

	lua_getfield(L, idx, "float");
	n->floating = lua_toboolean(L, -1);
	lua_pop(L, 1);
	lua_getfield(L, idx, "raster");
	n->raster = lua_toboolean(L, -1);
	lua_pop(L, 1);
	lua_getfield(L, idx, "spacer");
	n->widget = !lua_toboolean(L, -1);
	lua_pop(L, 1);

	return ok;
}

/* The subtree rooted at the table at idx, in preorder, into nodes. A leaf
 * has no children; anything else lists them under `children`. */
static bool
read_tree(lua_State *L, int idx, struct widget_node *nodes, size_t *len,
	size_t *leaves)
{
	struct widget_node *n;
	size_t count;
	bool ok;

	/* Two slots per level are live across the recursion (the children
	 * table and the child), plus what read_node needs at the bottom; a C
	 * function is only guaranteed LUA_MINSTACK. */
	if (*len == WIDGET_NODES_MAX || !lua_checkstack(L, 4))
		return false;
	n = &nodes[(*len)++];
	memset(n, 0, sizeof(*n));
	if (!read_node(L, idx, n))
		return false;
	if (n->raster)
		(*leaves)++;

	lua_getfield(L, idx, "children");
	ok = lua_isnil(L, -1) || (lua_istable(L, -1) && !n->raster);
	count = ok ? luaA_rawlen(L, -1) : 0;
	n->children = (uint16_t)count;
	for (size_t i = 0; ok && i < count; i++) {
		lua_rawgeti(L, -1, (int)i + 1);
		ok = read_tree(L, lua_gettop(L), nodes, len, leaves);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return ok;
}

/* Size each leaf's surface for its box, in device pixels rounded at both
 * edges the way the renderer sizes its buffers. The two cannot always agree
 * to the pixel: the renderer rounds against the box's output-local origin
 * and the solver may place the box a fraction from where the layout engine
 * did, so the entry is marked exact and the renderer places it one to one
 * rather than resampling it into whatever it solved. A surface whose device
 * size did not change is kept. */
static bool
leaves_set(lua_State *L, drawin_t *d, int idx, size_t count, float scale)
{
	if (!lua_istable(L, idx) || luaA_rawlen(L, idx) != count)
		return false;

	if (count != d->widget_leaves_len) {
		for (size_t i = count; i < d->widget_leaves_len; i++)
			drawin_entry_set(&d->widget_leaves[i], NULL);
		p_realloc(&d->widget_leaves, count);
		if (count > d->widget_leaves_len)
			memset(&d->widget_leaves[d->widget_leaves_len], 0,
				(count - d->widget_leaves_len)
					* sizeof(*d->widget_leaves));
		d->widget_leaves_len = count;
	}

	for (size_t i = 0; i < count; i++) {
		struct image_entry *leaf = &d->widget_leaves[i];
		float box[4] = { 0 };
		bool ok;
		int w, h;

		lua_rawgeti(L, idx, (int)i + 1);
		ok = lua_istable(L, -1)
			&& read_number(L, -1, "x", -1e6, 1e6, &box[0])
			&& read_number(L, -1, "y", -1e6, 1e6, &box[1])
			&& read_number(L, -1, "width", 0, 1e6, &box[2])
			&& read_number(L, -1, "height", 0, 1e6, &box[3]);
		lua_pop(L, 1);
		if (!ok)
			return false;
		leaf->exact = true;
		w = MAX(1, render_device_len((int)box[0], (int)box[2], scale));
		h = MAX(1, render_device_len((int)box[1], (int)box[3], scale));
		if (leaf->native && leaf->width == w && leaf->height == h)
			continue;
		drawin_entry_set(leaf, cairo_image_surface_create(
			CAIRO_FORMAT_ARGB32, w, h));
	}
	return true;
}

void
widget_nodes_clear(drawin_t *d)
{
	for (size_t i = 0; i < d->widget_leaves_len; i++)
		drawin_entry_set(&d->widget_leaves[i], NULL);
	p_delete(&d->widget_leaves);
	d->widget_leaves_len = 0;
	p_delete(&d->widget_nodes);
	d->widget_nodes_len = 0;
	d->widget_nodes_declared = false;
}

bool
widget_nodes_refused(drawin_t *d)
{
	return d->shape_bounding || d->shape_clip || d->shape_input
		|| (d->opacity >= 0 && d->opacity < 1)
		|| d == globalconf.systray.parent;
}

void
widget_nodes_gate(lua_State *L, drawin_t *d, int udx)
{
	bool refused = widget_nodes_refused(d);

	if (refused == d->widget_nodes_refused)
		return;
	d->widget_nodes_refused = refused;
	if (refused)
		widget_nodes_clear(d);
	/* The drawable is an item of the drawin's own env table, so reaching it
	 * needs the drawin already on the stack. The object registry does not
	 * hold a wibox's drawin, so looking it up there answers nil. A caller
	 * with no index (the tray's previous host) leaves the repaint to the
	 * next redraw, which sees the converted state change either way. */
	if (udx != 0 && d->drawable) {
		luaA_object_push_item(L, udx, d->drawable);
		luaA_object_emit_signal(L, -1, "property::surface", 0);
		lua_pop(L, 1);
	}
}

bool
widget_nodes_set(lua_State *L, drawin_t *d, int idx, int leaves_idx,
	float scale)
{
	/* One scratch tree for every drawin: a redraw reads into it and
	 * usually finds the stored tree unchanged. */
	static struct widget_node nodes[WIDGET_NODES_MAX];
	size_t len = 0, leaves = 0;

	d->widget_nodes_refused = widget_nodes_refused(d);
	if (d->widget_nodes_refused || !lua_istable(L, idx)
			|| !read_tree(L, idx, nodes, &len, &leaves)
			|| !leaves_set(L, d, leaves_idx, leaves, scale)) {
		widget_nodes_clear(d);
		return false;
	}

	if (d->widget_nodes_len == len
			&& memcmp(d->widget_nodes, nodes, len * sizeof(*nodes)) == 0)
		return true;

	p_delete(&d->widget_nodes);
	d->widget_nodes = p_new(struct widget_node, len);
	memcpy(d->widget_nodes, nodes, len * sizeof(*nodes));
	d->widget_nodes_len = len;
	d->widget_nodes_declared = false;
	/* A container's color or margin can change with no pixel in any leaf
	 * changing, so the tree has to wake the frame path on its own;
	 * drawable:refresh() only speaks for the pixels. */
	drawin_mark_dirty(d);
	return true;
}

cairo_surface_t *
widget_leaf_surface(drawin_t *d, size_t i)
{
	if (i >= d->widget_leaves_len)
		return NULL;
	return cairo_surface_reference(d->widget_leaves[i].native);
}

void
widget_leaves_drawn(lua_State *L, drawin_t *d, int idx)
{
	bool any = false;

	for (size_t i = 0; i < d->widget_leaves_len; i++) {
		lua_rawgeti(L, idx, (int)i + 1);
		if (lua_toboolean(L, -1)) {
			cairo_surface_flush(d->widget_leaves[i].native);
			d->widget_leaves[i].gen++;
			any = true;
		}
		lua_pop(L, 1);
	}
	if (any)
		drawin_mark_dirty(d);
}
