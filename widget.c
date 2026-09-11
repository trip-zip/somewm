/*
 * widget.c - the widget tree lua/wibox/clay.lua compiles
 *
 * lua/wibox/clay.lua walks a drawable's widget tree and describes what Clay
 * can solve as a tree of nodes. This file reads the description off the Lua
 * stack, stores it on the owner, and references image surfaces. It holds no Clay:
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
#include "render_text.h"
#include "objects/drawable.h"
#include "objects/drawin.h"
#include "objects/client.h"
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
 * the wrong type. Refusing rather than raising lets the caller clear the
 * malformed tree and report its state without unwinding the redraw. */
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

/* One axis of sizing, as Clay names it: "fit" or absent for
 * CLAY_SIZING_FIT, Clay's default (README, clay.h:290), "grow" for
 * CLAY_SIZING_GROW, a number for CLAY_SIZING_FIXED, or { percent = p }
 * for CLAY_SIZING_PERCENT (third_party/clay.h:72,294-295). */
static bool
read_sizing(lua_State *L, int idx, const char *name, uint8_t *sizing,
	float *size)
{
	const char *s;
	bool ok = true;

	lua_getfield(L, idx, name);
	if (lua_type(L, -1) == LUA_TNUMBER) {
		*sizing = WIDGET_SIZING_FIXED;
		*size = (float)lua_tonumber(L, -1);
		ok = *size >= 0;
	} else if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "percent");
		double p = lua_tonumber(L, -1);

		/* Reject outside 0-1 before Clay's error (third_party/clay.h:2030-2033). */
		ok = lua_type(L, -1) == LUA_TNUMBER && p >= 0 && p <= 1;
		*sizing = WIDGET_SIZING_PERCENT;
		*size = (float)p;
		lua_pop(L, 1);
	} else if (lua_isnil(L, -1)) {
		*sizing = WIDGET_SIZING_FIT;
	} else if ((s = lua_tostring(L, -1)) && strcmp(s, "fit") == 0) {
		*sizing = WIDGET_SIZING_FIT;
	} else if (s && strcmp(s, "grow") == 0) {
		*sizing = WIDGET_SIZING_GROW;
	} else {
		ok = false;
	}
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

/* The class names seen so far, interned so a node holds a stable pointer and
 * the tree still compares by memcmp. A config names a couple of dozen widget
 * classes and never frees one, so the table only grows, by a pointer each. */
static const char *
intern_class(const char *name)
{
	static const char **names;
	static size_t len, cap;

	for (size_t i = 0; i < len; i++)
		if (strcmp(names[i], name) == 0)
			return names[i];
	if (len == cap) {
		cap = cap ? cap * 2 : 32;
		p_realloc(&names, cap);
	}
	return names[len++] = a_strdup(name);
}

/* One of a small set of words, as the index of the Clay enumerator it names,
 * false for any other value. */
static bool
read_word(lua_State *L, int idx, const char *name, const char *const *words,
	size_t count, uint8_t *out)
{
	const char *s;
	bool ok = false;

	lua_getfield(L, idx, name);
	s = lua_tostring(L, -1);
	for (size_t i = 0; s && i < count; i++) {
		if (strcmp(s, words[i]) == 0) {
			*out = (uint8_t)i;
			ok = true;
		}
	}
	lua_pop(L, 1);
	return ok;
}

/* The scratch text buffer a tree is read into, alongside the scratch nodes:
 * a redraw reads into both and usually finds the stored tree unchanged. */
static char text_buf[WIDGET_TEXT_MAX];
static size_t text_len;

/* A text node: the run, appended to the scratch text, and its config, in
 * Clay's own words (Clay_TextElementConfigWrapMode, Clay_TextAlignment). */
static bool
read_text(lua_State *L, int idx, struct widget_node *n)
{
	static const char *const wraps[] = { "words", "newlines", "none" };
	static const char *const aligns[] = { "left", "center", "right" };
	size_t len;
	const char *text;
	float font = 0;
	bool ok;

	lua_getfield(L, idx, "text");
	text = lua_tolstring(L, -1, &len);
	if (!text || len > WIDGET_TEXT_MAX - text_len) {
		lua_pop(L, 1);
		return false;
	}
	memcpy(text_buf + text_len, text, len);
	n->text = true;
	n->text_off = (uint32_t)text_len;
	n->text_len = (uint32_t)len;
	text_len += len;
	lua_pop(L, 1);

	ok = read_number(L, idx, "font", 0, UINT16_MAX, &font)
		&& read_quad(L, idx, "color", n->fg)
		&& read_word(L, idx, "wrap", wraps, 3, &n->wrap)
		&& read_word(L, idx, "halign", aligns, 3, &n->text_align);
	n->font = (uint16_t)font;
	lua_getfield(L, idx, "ellipsize");
	n->ellipsize = lua_toboolean(L, -1);
	lua_pop(L, 1);
	return ok;
}

static bool
read_fill(lua_State *L, int idx, struct widget_node *n)
{
	struct render_gradient *g = &n->gradient;
	memset(g, 0, sizeof(*g));
	lua_getfield(L, idx, "fill");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return read_quad(L, idx, "fill", n->fill);
	}
	lua_getfield(L, -1, "stops");
	if (lua_isnil(L, -1)) {
		lua_pop(L, 2);
		return read_quad(L, idx, "fill", n->fill);
	}
	bool ok = lua_istable(L, -1);
	size_t count = ok ? luaA_rawlen(L, -1) : 0;
	ok = ok && count <= 16;
	g->count = (int)count;
	for (size_t i = 0; ok && i < count; i++) {
		lua_rawgeti(L, -1, i + 1);
		ok = lua_istable(L, -1);
		for (int j = 0; ok && j < 5; j++) {
			lua_rawgeti(L, -1, j + 1);
			ok = lua_type(L, -1) == LUA_TNUMBER;
			g->stops[i][j] = (float)lua_tonumber(L, -1);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	lua_getfield(L, -1, "linear");
	g->kind = 1;
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_getfield(L, -1, "radial");
		g->kind = 2;
	}
	ok = ok && lua_istable(L, -1);
	for (int i = 0; ok && i < (g->kind == 1 ? 4 : 6); i++) {
		lua_rawgeti(L, -1, i + 1);
		ok = lua_type(L, -1) == LUA_TNUMBER;
		g->points[i] = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);
	}
	lua_pop(L, 2);
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
	lua_getfield(L, idx, "class");
	if (lua_isstring(L, -1))
		n->cls = intern_class(lua_tostring(L, -1));
	lua_pop(L, 1);
	lua_getfield(L, idx, "shape");
	ok = lua_isnil(L, -1) || lua_isfunction(L, -1);
	n->shape = lua_isfunction(L, -1) ? 1 : 0;
	lua_pop(L, 1);
	if (!ok)
		return false;
	lua_getfield(L, idx, "text");
	ok = lua_isnil(L, -1);
	lua_pop(L, 1);
	if (!ok)
		return !n->shape && read_text(L, idx, n);
	if (!read_fill(L, idx, n)
			|| !read_quad(L, idx, "stroke", n->stroke)
			|| !read_number(L, idx, "stroke_width", 0, 1e6, &n->stroke_width))
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
			|| !read_number(L, idx, "x", -1e6, 1e6, &n->offset[0])
			|| !read_number(L, idx, "y", -1e6, 1e6, &n->offset[1])
			|| !read_number(L, idx, "gap", 0, UINT16_MAX, &gap)
			|| !read_number(L, idx, "wmin", 0, 1e6, &n->min[0])
			|| !read_number(L, idx, "hmin", 0, 1e6, &n->min[1])
			|| !read_number(L, idx, "wmax", 0, 1e6, &n->max[0])
			|| !read_number(L, idx, "hmax", 0, 1e6, &n->max[1]))
		return false;
	n->gap = (uint16_t)gap;
	if (!read_sizing(L, idx, "w", &n->sizing[0], &n->size[0])
			|| !read_sizing(L, idx, "h", &n->sizing[1], &n->size[1]))
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
	lua_getfield(L, idx, "image");
	if (lua_islightuserdata(L, -1)) {
		n->image = lua_touserdata(L, -1);
	} else if (!lua_isnil(L, -1)) {
		ok = false;
	}
	lua_pop(L, 1);
	if (n->image) {
		static const char *const filters[] = {
			"fast", "good", "best", "nearest", "bilinear"
		};

		lua_getfield(L, idx, "filter");
		bool has_filter = !lua_isnil(L, -1);
		lua_pop(L, 1);
		if (has_filter) {
			if (read_word(L, idx, "filter", filters, 5, &n->filter))
				n->filter++;
			else
				ok = false;
		}
		lua_getfield(L, idx, "natural");
		n->natural = lua_toboolean(L, -1);
		lua_pop(L, 1);
	}
	lua_getfield(L, idx, "scroll");
	bool has_scroll = !lua_isnil(L, -1);
	lua_pop(L, 1);
	if (has_scroll) {
		static const char *const axes[] = { "x", "y" };

		if (!read_word(L, idx, "scroll", axes, 2, &n->scroll)
				|| !read_number(L, idx, "scrolled", 0, 1e6, &n->scrolled))
			return false;
		n->scroll++;
	}
	lua_getfield(L, idx, "spacer");
	n->widget = !lua_toboolean(L, -1);
	lua_pop(L, 1);

	return ok;
}

/* The subtree rooted at the table at idx, in preorder, into nodes. A leaf
 * has no children; anything else lists them under `children`. clip_by is
 * the scope the subtree sits in, and clips counts the scopes opened so far
 * (widget.h clip_opens): the root opens one, and so does a rounded node
 * with children. Past WIDGET_CLIPS_MAX, clips is left one over and the tree
 * is refused. */
static bool
read_tree(lua_State *L, int idx, struct widget_node *nodes, size_t *len,
	size_t *leaves, unsigned clip_by, unsigned *clips, int shapes)
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
	if (n->shape) {
		if (n->image)
			return false;
		n->shape = (uint16_t)luaA_rawlen(L, shapes) + 1;
		lua_getfield(L, idx, "shape");
		lua_rawseti(L, shapes, n->shape);
	}
	if (n->image)
		(*leaves)++;
	n->clip_by = (uint8_t)clip_by;

	lua_getfield(L, idx, "children");
	ok = lua_isnil(L, -1) || (lua_istable(L, -1) && !n->text);
	count = ok ? luaA_rawlen(L, -1) : 0;
	n->children = (uint16_t)count;
	if (ok && (*len == 1 || (n->radius > 0 && count > 0))) {
		if (*clips == WIDGET_CLIPS_MAX)
			ok = false;
		n->clip_opens = (uint8_t)++*clips;
		clip_by = n->clip_opens;
	}
	if (n->shape && count > 0 && n->clip_opens)
		ok = false;
	for (size_t i = 0; ok && i < count; i++) {
		lua_rawgeti(L, -1, (int)i + 1);
		ok = read_tree(L, lua_gettop(L), nodes, len, leaves, clip_by, clips, shapes);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return ok;
}

/* The leaf array at the tree's leaf count, surfaces kept where the index
 * survives: a leaf keeps its surface by its index in the tree, and
 * widget_leaves_set references the image surfaces. */
static void
leaves_count(struct widget_tree *d, size_t count)
{
	if (count == d->leaves_len)
		return;
	for (size_t i = count; i < d->leaves_len; i++)
		image_entry_set(&d->leaves[i], NULL);
	p_realloc(&d->leaves, count);
	if (count > d->leaves_len)
		memset(&d->leaves[d->leaves_len], 0,
			(count - d->leaves_len) * sizeof(*d->leaves));
	d->leaves_len = count;
}

void
widget_leaves_set(struct widget_tree *d)
{
	size_t leaf = 0;

	for (size_t i = 0; i < d->nodes_len; i++) {
		const struct widget_node *n = &d->nodes[i];
		struct image_entry *entry;

		if (!n->image)
			continue;
		entry = &d->leaves[leaf++];
		if (entry->filter != n->filter) {
			entry->filter = n->filter;
			entry->gen++;
		}
		if (entry->natural != n->natural) {
			entry->natural = n->natural;
			entry->gen++;
		}
		/* The widget's own surface: referenced, and a new reference only
		 * when it is another surface, so its generation moves with it. */
		cairo_surface_t *surface = (cairo_surface_t *)n->image;

		if (entry->native != surface)
			image_entry_set(entry, cairo_surface_reference(surface));
	}
}

void
widget_nodes_clear(struct widget_tree *d)
{
	for (size_t i = 0; i < d->shapes_len; i++)
		luaL_unref(globalconf.L, LUA_REGISTRYINDEX, d->shapes[i].ref);
	p_delete(&d->shapes);
	d->shapes_len = 0;
	for (size_t i = 0; i < d->leaves_len; i++)
		image_entry_set(&d->leaves[i], NULL);
	p_delete(&d->leaves);
	d->leaves_len = 0;
	p_delete(&d->nodes);
	d->nodes_len = 0;
	d->scrolls = 0;
	p_delete(&d->text);
	d->text_len = 0;
	d->declared = false;
}

/* Drop the stored tree and record the result for Lua and the tree dump. */
static bool
nodes_drop(struct widget_tree *d, enum widget_nodes_state why)
{
	widget_nodes_clear(d);
	d->state = why;
	return false;
}

/* Whether len more nodes would take this drawin's output past the budget
 * every converted tree on it shares (widget.h). The drawin's own stored tree
 * is the one being replaced, so it does not count against the new one, and a
 * drawin with no screen declares nowhere and is not counted at all.
 *
 * A hidden drawin's tree is counted, though it declares nothing: visibility
 * flips without a redraw, so a tree admitted while its drawin was hidden
 * would reach Clay unchecked. Counting it can refuse a tree the output had
 * room for, which costs one drawable its conversion; not counting it can
 * exhaust the context, which aborts. */
static bool
over_budget(struct widget_tree *d, Monitor *m, size_t len, size_t scrolls)
{
	size_t total = len;

	if (!m)
		return false;
	foreach(item, globalconf.drawins) {
		drawin_t *other = *item;

		if (&other->widgets != d && other->screen
				&& other->screen->monitor == m) {
			total += other->widgets.nodes_len;
			scrolls += other->widgets.scrolls;
		}
	}
	foreach(item, globalconf.clients) {
		client_t *c = *item;

		if (c->mon != m)
			continue;
		for (int bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++) {
			struct widget_tree *other = &c->titlebar[bar].widgets;

			if (other == d)
				continue;
			total += other->nodes_len;
			scrolls += other->scrolls;
		}
	}
	return total > WIDGET_NODES_OUTPUT_MAX || scrolls > WIDGET_SCROLLS_OUTPUT_MAX;
}

bool
widget_nodes_set(lua_State *L, struct widget_tree *d, Monitor *m, int idx)
{
	if (declare_in_frame())
		luaL_error(L, "widget tree changed from inside a frame");
	/* One scratch tree for every drawin: a redraw reads into it before
	 * the stored tree is replaced. */
	static struct widget_node nodes[WIDGET_NODES_MAX];
	size_t len = 0, leaves = 0;
	unsigned clips = 0;

	text_len = 0;
	if (!lua_istable(L, idx))
		return nodes_drop(d, WIDGET_NODES_NONE);
	/* read_tree refuses a tree of its own cap's size before reading a node
	 * of it, so a full scratch tree and a tree past the clip scopes are
	 * the two failures that are a size and not a malformed table. */
	lua_newtable(L);
	int shapes = lua_gettop(L);
	bool ok = read_tree(L, idx, nodes, &len, &leaves, 0, &clips, shapes);
	size_t scrolls = 0;
	for (size_t i = 0; i < len; i++)
		scrolls += nodes[i].scroll != 0;
	if (!ok || over_budget(d, m, len, scrolls)) {
		lua_pop(L, 1);
		enum widget_nodes_state why = ok ? WIDGET_NODES_OVER_BUDGET
			: len == WIDGET_NODES_MAX || clips > WIDGET_CLIPS_MAX
			? WIDGET_NODES_OVER_BUDGET : WIDGET_NODES_MALFORMED;
		if (why != d->state)
			warn("widget tree %s, showing nothing", why == WIDGET_NODES_OVER_BUDGET
				? "over the output's element budget" : "malformed");
		return nodes_drop(d, why);
	}
	leaves_count(d, leaves);
	size_t count = luaA_rawlen(L, shapes);
	bool shapes_changed = count != d->shapes_len;
	if (shapes_changed) {
		for (size_t i = count; i < d->shapes_len; i++)
			luaL_unref(L, LUA_REGISTRYINDEX, d->shapes[i].ref);
		p_realloc(&d->shapes, count);
		for (size_t i = d->shapes_len; i < count; i++)
			d->shapes[i] = (struct widget_shape) { .ref = LUA_NOREF };
		d->shapes_len = count;
	}
	for (size_t i = 0; i < len; i++) {
		struct widget_node *n = &nodes[i];
		if (!n->shape)
			continue;
		struct widget_shape *slot = &d->shapes[n->shape - 1];
		lua_rawgeti(L, shapes, n->shape);
		lua_rawgeti(L, LUA_REGISTRYINDEX, slot->ref);
		bool same = lua_rawequal(L, -1, -2);
		lua_pop(L, 1);
		if (same) {
			lua_pop(L, 1);
		} else {
			luaL_unref(L, LUA_REGISTRYINDEX, slot->ref);
			slot->ref = luaL_ref(L, LUA_REGISTRYINDEX);
			slot->shape.gen++;
			shapes_changed = true;
		}
		slot->shape.gradient = n->gradient;
		memcpy(slot->shape.fill, n->fill, sizeof(n->fill));
		memcpy(slot->shape.stroke, n->stroke, sizeof(n->stroke));
		slot->shape.stroke_width = n->stroke_width;
	}
	lua_pop(L, 1);
	if (shapes_changed && m && m->declare)
		declare_output_mark_dirty(m->declare);

	d->state = WIDGET_NODES_CONVERTED;
	p_delete(&d->nodes);
	d->nodes = p_new(struct widget_node, len);
	memcpy(d->nodes, nodes, len * sizeof(*nodes));
	d->nodes_len = len;
	d->scrolls = scrolls;
	p_delete(&d->text);
	d->text = text_len ? p_dup(text_buf, text_len) : NULL;
	d->text_len = text_len;
	d->declared = false;
	/* Every stored tree change wakes the frame path. */
	if (m && m->declare)
		declare_output_mark_dirty(m->declare);
	return true;
}
