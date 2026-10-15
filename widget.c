/*
 * widget.c - the widget tree lua/wibox/clay.lua compiles
 *
 * lua/wibox/clay.lua walks a drawable's widget tree and describes what Clay
 * can solve as a tree of nodes. This file reads the description off the Lua
 * stack, stores it on the owner, and references image sources. It holds no Clay:
 * declaring the tree is declare.c's and drawing it is the renderer's, so a
 * node here is nothing but the numbers Lua handed over.
 */

#include <string.h>
#include <math.h>

#include <lauxlib.h>

#include "luaa.h"

#include "widget.h"
#include "clay_impl.h"
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

/* Every field a tree is read by. widget_nodes_set keeps their interned
 * strings in an array in the registry, and a read indexes it: lua_getfield
 * would intern the name again for every field of every node each frame. */
#define KEYS(X) X(name) X(spacer) X(identity) X(occurrence) X(transform) \
	X(shape) X(text) X(fill) X(stops) X(linear) X(radial) X(stroke) \
	X(stroke_width) X(pad) X(bw) X(bg) X(border) X(radius) X(radii) X(x) X(y) \
	X(gap) X(wmin) X(hmin) X(wmax) X(hmax) X(w) X(h) X(percent) X(wsrc) X(hsrc) \
	X(align) X(dir) X(float) X(parent) X(own) X(passthrough) X(vector) X(image) \
	X(aspect) X(image_width) X(image_height) X(filter) X(natural) X(track) \
	X(thumb) X(scroll) X(transition) X(duration) X(properties) X(exit_order) \
    X(exit_duration) X(tag_exit) X(tag_duration) \
	X(enter) X(exit) X(x11_configure_serial) X(client) X(surface) X(host) X(opacity) X(probe) X(attrs) \
	X(font) X(color) X(wrap) X(halign) X(ellipsize) X(bindings) X(item) X(id) \
	X(next) X(_attach) X(clip) X(children)

enum key {
#define KEY_ENUM(k) KEY_##k,
	KEYS(KEY_ENUM)
#undef KEY_ENUM
};

static const char *const key_names[] = {
#define KEY_NAME(k) #k,
	KEYS(KEY_NAME)
#undef KEY_NAME
};

/* The stack index of that array while a tree is read. */
static int keys;

/* lua_getfield(L, idx, key_names[k]). */
static void
getfield(lua_State *L, int idx, enum key k)
{
	if (idx < 0 && idx > LUA_REGISTRYINDEX)
		idx = lua_gettop(L) + idx + 1;
	if (!keys) { lua_getfield(L, idx, key_names[k]); return; }
	lua_rawgeti(L, keys, k + 1);
	lua_gettable(L, idx);
}

/* A four-number array field (pad, bw, bg, border), left at zero when the
 * field is absent. False for a field that is present but not four numbers,
 * which is a compile-step bug rather than a config to ride out. */
static bool
read_quad(lua_State *L, int idx, enum key name, float *out)
{
	bool ok = true;

	getfield(L, idx, name);
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
read_number(lua_State *L, int idx, enum key name, double min, double max,
	float *out)
{
	bool ok;

	getfield(L, idx, name);
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
read_sizing(lua_State *L, int idx, enum key name, uint8_t *sizing,
	float *size)
{
	const char *s;
	bool ok = true;

	getfield(L, idx, name);
	if (lua_type(L, -1) == LUA_TNUMBER) {
		*sizing = WIDGET_SIZING_FIXED;
		*size = (float)lua_tonumber(L, -1);
		ok = *size >= 0;
	} else if (lua_istable(L, -1)) {
		getfield(L, -1, KEY_percent);
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
read_align(lua_State *L, int idx, enum key name, uint8_t *out)
{
	const char *s;
	bool ok = true;

	getfield(L, idx, name);
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

/* Intern node names for the program's lifetime so element id strings stay
 * valid and tree nodes compare by memcmp. */
static const char *
intern_name(const char *name)
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
read_word(lua_State *L, int idx, enum key name, const char *const *words,
	size_t count, uint8_t *out)
{
	const char *s;
	bool ok = false;

	getfield(L, idx, name);
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

/* A word field that may be absent, which leaves *out at its default. */
static bool
read_option(lua_State *L, int idx, enum key name, const char *const *words,
	size_t count, uint8_t *out)
{
	getfield(L, idx, name);
	bool absent = lua_isnil(L, -1);
	lua_pop(L, 1);
	return absent || read_word(L, idx, name, words, count, out);
}

static bool
read_transition_property(lua_State *L, int idx, uint16_t *out)
{
    static const char *const words[] = {
        "box", "position", "size", "width", "height", "background",
        "border_color", "border_width", "border" };
    static const uint16_t bits[] = {
        CLAY_TRANSITION_PROPERTY_BOUNDING_BOX, CLAY_TRANSITION_PROPERTY_POSITION,
        CLAY_TRANSITION_PROPERTY_DIMENSIONS, CLAY_TRANSITION_PROPERTY_WIDTH,
        CLAY_TRANSITION_PROPERTY_HEIGHT, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR,
        CLAY_TRANSITION_PROPERTY_BORDER_COLOR, CLAY_TRANSITION_PROPERTY_BORDER_WIDTH,
        CLAY_TRANSITION_PROPERTY_BORDER };
    const char *word = lua_type(L, idx) == LUA_TSTRING ? lua_tostring(L, idx) : NULL;
    for (size_t i = 0; word && i < sizeof(bits) / sizeof(bits[0]); i++) {
        if (!strcmp(word, words[i])) {
            *out |= bits[i];
            return true;
        }
    }
    if (word && !strcmp(word, "corner_radius")) {
        static bool warned;
        if (!warned) {
            luaA_warn(L, "transition.properties: corner_radius is unsupported by Clay; radius changes snap");
            warned = true;
        }
        return true;
    }
    return false;
}

static bool
read_transition_properties(lua_State *L, int idx, uint16_t *out)
{
    getfield(L, idx, KEY_properties);
    bool ok = true;
    *out = 0;
    if (lua_isnil(L, -1)) {
        *out = CLAY_TRANSITION_PROPERTY_BOUNDING_BOX;
    } else if (lua_istable(L, -1)) {
        size_t count = luaA_rawlen(L, -1);
        ok = count > 0;
        for (size_t i = 1; ok && i <= count; i++) {
            lua_rawgeti(L, -1, i);
            ok = read_transition_property(L, -1, out);
            lua_pop(L, 1);
        }
    } else {
        ok = read_transition_property(L, -1, out);
    }
    lua_pop(L, 1);
    return ok;
}

static bool
read_transition_state(lua_State *L, int idx, enum key key, uint8_t *out)
{
    static const char *const words[] = {
        "none", "grow", "slide_left", "slide_right", "slide_up", "slide_down", "fade", "collapse" };
    bool ok = read_option(L, idx, key, words, 8, out);
    if (*out == 7) *out = WIDGET_TRANSITION_GROW;
    return ok;
}

/* A layout node's own transition, Clay's config in Lua words: what to
 * interpolate, for how long, and whether it collapses on the way in and on
 * the way out. An exiting node is drawn where it stood and holds no space
 * (third_party/clay.h:2557). */
static bool
read_transition(lua_State *L, int idx, struct widget_node *n)
{
    static const char *const orders[] = { "underneath", "natural", "above" };
    bool ok;

    getfield(L, idx, KEY_transition);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return true;
    }
    int t = lua_gettop(L);
    n->transition.enabled = true;
    n->transition.exit_order = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER;
    ok = lua_istable(L, t)
        && read_number(L, t, KEY_duration, 0, 1e6, &n->transition.duration)
        && read_transition_properties(L, t, &n->transition.properties)
        && read_option(L, t, KEY_exit_order, orders, 3, &n->transition.exit_order)
        && read_transition_state(L, t, KEY_enter, &n->transition.enter_state)
        && read_transition_state(L, t, KEY_exit, &n->transition.exit_state)
        && read_transition_state(L, t, KEY_tag_exit, &n->transition.tag_exit);
    n->transition.exit_duration = n->transition.tag_duration = n->transition.duration;
    ok = ok && read_number(L, t, KEY_exit_duration, 0, 1e6, &n->transition.exit_duration)
        && read_number(L, t, KEY_tag_duration, 0, 1e6, &n->transition.tag_duration);
    getfield(L, t, KEY_properties);
    bool implicit = lua_isnil(L, -1);
    lua_pop(L, 1);
    if (implicit && (n->transition.enter_state || n->transition.exit_state)) n->transition.properties = 0;
    if ((n->transition.enter_state >= WIDGET_TRANSITION_SLIDE_LEFT && n->transition.enter_state <= WIDGET_TRANSITION_SLIDE_DOWN)
            || (n->transition.exit_state >= WIDGET_TRANSITION_SLIDE_LEFT && n->transition.exit_state <= WIDGET_TRANSITION_SLIDE_DOWN))
        n->transition.properties |= CLAY_TRANSITION_PROPERTY_POSITION;
    if (implicit && (n->transition.enter_state == WIDGET_TRANSITION_GROW || n->transition.exit_state == WIDGET_TRANSITION_GROW))
        n->transition.properties |= CLAY_TRANSITION_PROPERTY_DIMENSIONS;
    if (n->transition.enter_state == WIDGET_TRANSITION_FADE || n->transition.exit_state == WIDGET_TRANSITION_FADE)
        n->transition.properties |= CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR;
    lua_pop(L, 1);
    return ok;
}

bool
widget_read_transition(lua_State *L, int idx, struct widget_transition *transition)
{
    struct widget_node node = {0};
    int saved_keys = keys;
    keys = 0;
    bool ok = read_transition(L, idx, &node);
    keys = saved_keys;
    *transition = node.transition;
    return ok;
}

/* A client composite's root (client) and its pixels leaf (surface), kept as
 * the client's declare handle. A client that has gone keeps a handle no
 * client answers to, so the frame skips it. */
static bool
read_client(lua_State *L, int idx, enum key name, uint64_t *out)
{
	getfield(L, idx, name);
	client_t *c = lua_isnil(L, -1) ? NULL : luaA_toudata(L, -1, &client_class);
	bool ok = lua_isnil(L, -1) || c;
	lua_pop(L, 1);
	if (c)
		*out = c->scene ? declare_handle_for(c, DECLARE_KIND_CLIENT)
			: (uint64_t)DECLARE_KIND_CLIENT << 32;
	return ok;
}

/* A composite's titlebar host, kept as its drawable's declare handle. */
static bool
read_host(lua_State *L, int idx, struct widget_node *n)
{
	getfield(L, idx, KEY_host);
	drawable_t *d = lua_isnil(L, -1) ? NULL : luaA_toudata(L, -1, &drawable_class);
	bool ok = lua_isnil(L, -1) || d;
	lua_pop(L, 1);
	if (d)
		n->host = declare_handle_for(d, DECLARE_KIND_TITLEBAR);
	return ok;
}

static bool
read_composite(lua_State *L, int idx, struct widget_node *n)
{
	n->opacity = 1;
	getfield(L, idx, KEY_x11_configure_serial);
	double serial = lua_isnil(L, -1) ? 0 : lua_tonumber(L, -1);
	bool valid_serial = lua_isnil(L, -1) || (lua_isnumber(L, -1)
		&& serial >= 0 && serial <= UINT32_MAX && serial == floor(serial));
	lua_pop(L, 1);
	if (!valid_serial) return false;
	n->x11_configure_serial = (uint32_t)serial;
	if (!read_client(L, idx, KEY_client, &n->client)
			|| !read_client(L, idx, KEY_surface, &n->surface)
			|| !read_host(L, idx, n)
			|| !read_number(L, idx, KEY_opacity, 0, 1, &n->opacity))
		return false;
	getfield(L, idx, KEY_probe);
	n->probe = n->surface && lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (n->client || n->surface || n->host)
		n->widget = false;
	return true;
}

/* The scratch text buffer a tree is read into, alongside the scratch nodes:
 * a redraw reads into both and usually finds the stored tree unchanged. */
static char text_buf[WIDGET_TEXT_MAX];
static size_t text_len;
static struct render_text_attr text_attrs_buf[WIDGET_TEXT_MAX];
static size_t text_attrs_len;

static bool
read_text_attrs(lua_State *L, int idx, struct widget_node *n)
{
    getfield(L, idx, KEY_attrs);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return true;
    }
    bool ok = lua_istable(L, -1);
    size_t count = ok ? luaA_rawlen(L, -1) : 0;
    ok = ok && count % 7 == 0 && count / 7 <= WIDGET_TEXT_MAX - text_attrs_len;
    n->attr_off = (uint32_t)text_attrs_len;
    n->attr_len = (uint32_t)(count / 7);
    for (size_t i = 0; ok && i < count; i += 7) {
        double v[7];
        for (int k = 0; k < 7; k++) {
            lua_rawgeti(L, -1, i + k + 1);
            v[k] = lua_tonumber(L, -1);
            ok = ok && lua_type(L, -1) == LUA_TNUMBER && isfinite(v[k]);
            lua_pop(L, 1);
        }
        ok = ok && v[0] >= 0 && v[0] <= v[1] && v[1] <= n->text_len
            && v[0] == floor(v[0]) && v[1] == floor(v[1])
            && v[2] >= RENDER_TEXT_FOREGROUND && v[2] <= RENDER_TEXT_STRIKETHROUGH
            && v[2] == floor(v[2]);
        for (int k = 3; ok && k < 7; k++) {
            double max = k == 3 && v[2] == RENDER_TEXT_UNDERLINE
                ? PANGO_UNDERLINE_ERROR_LINE : 1;
            ok = v[k] >= 0 && v[k] <= max;
        }
        if (!ok) break;
        struct render_text_attr *attr = &text_attrs_buf[text_attrs_len++];
        memset(attr, 0, sizeof(*attr));
        attr->start = (uint32_t)v[0];
        attr->end = (uint32_t)v[1];
        attr->kind = (uint8_t)v[2];
        for (int k = 0; k < 4; k++) attr->value[k] = (float)v[k + 3];
    }
    lua_pop(L, 1);
    return ok;
}

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

	getfield(L, idx, KEY_text);
	text = lua_tolstring(L, -1, &len);
	if (!text || len + 1 > WIDGET_TEXT_MAX - text_len) {
		lua_pop(L, 1);
		return false;
	}
	memcpy(text_buf + text_len, text, len);
	text_buf[text_len + len] = 0;
	n->text = true;
	n->widget = false;
	n->identity = n->occurrence = 0;
	n->text_off = (uint32_t)text_len;
	n->text_len = (uint32_t)len;
	text_len += len + 1;
	lua_pop(L, 1);

	ok = read_text_attrs(L, idx, n)
		&& read_number(L, idx, KEY_font, 0, UINT16_MAX, &font)
		&& read_quad(L, idx, KEY_color, n->fg)
		&& read_word(L, idx, KEY_wrap, wraps, 3, &n->wrap)
		&& read_word(L, idx, KEY_halign, aligns, 3, &n->text_align);
	n->font = (uint16_t)font;
	getfield(L, idx, KEY_ellipsize);
	n->ellipsize = lua_toboolean(L, -1);
	lua_pop(L, 1);
	return ok;
}

static bool
read_fill(lua_State *L, int idx, struct widget_node *n)
{
	struct render_gradient *g = &n->gradient;
	memset(g, 0, sizeof(*g));
	getfield(L, idx, KEY_fill);
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return read_quad(L, idx, KEY_fill, n->fill);
	}
	getfield(L, -1, KEY_stops);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 2);
		return read_quad(L, idx, KEY_fill, n->fill);
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
	getfield(L, -1, KEY_linear);
	g->kind = 1;
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		getfield(L, -1, KEY_radial);
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
	getfield(L, idx, KEY_name);
	if (lua_isstring(L, -1))
		n->name = intern_name(lua_tostring(L, -1));
	lua_pop(L, 1);
	getfield(L, idx, KEY_spacer);
	n->widget = !lua_toboolean(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_identity);
	n->identity = (uint32_t)lua_tointeger(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_occurrence);
	n->occurrence = (uint32_t)lua_tointeger(L, -1);
	lua_pop(L, 1);
	static const char *const transforms[] = {
		"normal", "90", "180", "270",
		"flipped", "flipped-90", "flipped-180", "flipped-270",
	};
	if (!read_option(L, idx, KEY_transform, transforms, 8, &n->transform))
		return false;
	getfield(L, idx, KEY_shape);
	ok = lua_isnil(L, -1) || lua_isfunction(L, -1);
	n->shape = lua_isfunction(L, -1) ? 1 : 0;
	lua_pop(L, 1);
	if (!ok)
		return false;
	getfield(L, idx, KEY_text);
	ok = lua_isnil(L, -1);
	lua_pop(L, 1);
	if (!ok)
		return !n->shape && read_text(L, idx, n);
	if (!read_fill(L, idx, n)
			|| !read_quad(L, idx, KEY_stroke, n->stroke)
			|| !read_number(L, idx, KEY_stroke_width, 0, 1e6, &n->stroke_width))
		return false;
	if (!read_quad(L, idx, KEY_pad, pad) || !read_quad(L, idx, KEY_bw, bw)
			|| !read_quad(L, idx, KEY_bg, n->bg)
			|| !read_quad(L, idx, KEY_border, n->border))
		return false;
	for (int i = 0; i < 4; i++) {
		if (pad[i] < 0 || pad[i] > UINT16_MAX
				|| bw[i] < 0 || bw[i] > UINT16_MAX)
			return false;
		n->pad[i] = (uint16_t)pad[i];
		n->bw[i] = (uint16_t)bw[i];
	}

	if (!read_number(L, idx, KEY_radius, 0, 1e6, &n->radius)
			|| !read_quad(L, idx, KEY_radii, n->radii)
			|| !read_number(L, idx, KEY_x, -1e6, 1e6, &n->offset[0])
			|| !read_number(L, idx, KEY_y, -1e6, 1e6, &n->offset[1])
			|| !read_number(L, idx, KEY_gap, 0, UINT16_MAX, &gap)
			|| !read_number(L, idx, KEY_wmin, 0, 1e6, &n->min[0])
			|| !read_number(L, idx, KEY_hmin, 0, 1e6, &n->min[1])
			|| !read_number(L, idx, KEY_wmax, 0, 1e6, &n->max[0])
			|| !read_number(L, idx, KEY_hmax, 0, 1e6, &n->max[1]))
		return false;
	n->gap = (uint16_t)gap;
	if (!read_sizing(L, idx, KEY_w, &n->sizing[0], &n->size[0])
			|| !read_sizing(L, idx, KEY_h, &n->sizing[1], &n->size[1]))
		return false;
	/* A word belongs to an axis that carries a number (spec D060). */
	for (int axis = 0; axis < 2; axis++) {
		if (n->sizing[axis] < WIDGET_SIZING_FIXED && n->min[axis] <= 0 && n->max[axis] <= 0)
			continue;
		getfield(L, idx, axis ? KEY_hsrc : KEY_wsrc);
		n->src[axis] = declare_src_parse(lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	getfield(L, idx, KEY_align);
	ok = lua_isnil(L, -1) || (lua_istable(L, -1)
		&& read_align(L, lua_gettop(L), KEY_x, &n->align[0])
		&& read_align(L, lua_gettop(L), KEY_y, &n->align[1]));
	lua_pop(L, 1);

	getfield(L, idx, KEY_dir);
	dir = lua_tostring(L, -1);
	n->vertical = dir && strcmp(dir, "y") == 0;
	lua_pop(L, 1);

	getfield(L, idx, KEY_float);
	n->floating = lua_toboolean(L, -1);
	lua_pop(L, 1);
	float parent = 0, own = 0;
	if (!read_number(L, idx, KEY_parent, 0, 8, &parent)
			|| !read_number(L, idx, KEY_own, 0, 8, &own)
			|| parent != floorf(parent) || own != floorf(own))
		return false;
	n->parent = parent;
	n->own = own;
	getfield(L, idx, KEY_passthrough);
	ok = ok && (lua_isnil(L, -1) || lua_isboolean(L, -1));
	n->passthrough = lua_isnil(L, -1) || lua_toboolean(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_vector);
	ok = ok && (lua_isnil(L, -1) || lua_isboolean(L, -1));
	n->vector = lua_toboolean(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_image);
	if (lua_islightuserdata(L, -1)) {
		n->image = lua_touserdata(L, -1);
	} else if (!lua_isnil(L, -1)) {
		ok = false;
	}
	lua_pop(L, 1);
	if (n->image) {
		if (!read_number(L, idx, KEY_aspect, 0, 1e6, &n->aspect)
				|| !read_number(L, idx, KEY_image_width, 0, 1e6, &n->image_size[0])
				|| !read_number(L, idx, KEY_image_height, 0, 1e6, &n->image_size[1]))
			return false;
		if (!n->vector && n->aspect > 0 && (n->image_size[0] <= 0 || n->image_size[1] <= 0)) {
			n->image_size[0] = cairo_image_surface_get_width((cairo_surface_t *)n->image);
			n->image_size[1] = cairo_image_surface_get_height((cairo_surface_t *)n->image);
		}
		static const char *const filters[] = {
			"fast", "good", "best", "nearest", "bilinear"
		};

		getfield(L, idx, KEY_filter);
		bool has_filter = !lua_isnil(L, -1);
		lua_pop(L, 1);
		if (has_filter) {
			if (read_word(L, idx, KEY_filter, filters, 5, &n->filter))
				n->filter++;
			else
				ok = false;
		}
		getfield(L, idx, KEY_natural);
		n->natural = lua_toboolean(L, -1);
		lua_pop(L, 1);
	}
	getfield(L, idx, KEY_track);
	n->track = lua_toboolean(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_thumb);
	n->thumb = lua_toboolean(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_scroll);
	bool has_scroll = !lua_isnil(L, -1);
	lua_pop(L, 1);
	if (has_scroll) {
		static const char *const axes[] = { "x", "y", "both" };

		if (!read_word(L, idx, KEY_scroll, axes, 3, &n->scroll))
			return false;
		n->scroll++;
	}
	return ok && read_transition(L, idx, n) && read_composite(L, idx, n);
}

/* The subtree rooted at the table at idx, in preorder, into nodes. A leaf
 * has no children; anything else lists them under `children`. clip_by is
 * the scope the subtree sits in, and clips counts the scopes opened so far
 * (widget.h clip_opens): the root opens one, and so does a rounded node
 * with children. Past WIDGET_CLIPS_MAX, clips is left one over and the tree
 * is refused. */
static struct widget_binding binding_buf[WIDGET_BINDINGS_MAX];
static size_t binding_len;

static bool
read_bindings(lua_State *L, int idx, struct widget_node *n)
{
	n->binding_start = (uint32_t)binding_len;
	getfield(L, idx, KEY_bindings);
	while (lua_istable(L, -1)) {
		if (binding_len == WIDGET_BINDINGS_MAX) {
			lua_pop(L, 1);
			return false;
		}
		getfield(L, -1, KEY_item);
		if (!lua_istable(L, -1)) {
			lua_pop(L, 2);
			return false;
		}
		getfield(L, -1, KEY_identity);
		uint32_t identity = (uint32_t)lua_tointeger(L, -1);
		lua_pop(L, 1);
		getfield(L, -1, KEY_id);
		uint32_t occurrence = (uint32_t)lua_tointeger(L, -1);
		lua_pop(L, 2);
		binding_buf[binding_len++] = (struct widget_binding) {identity, occurrence};
		n->binding_count++;
		getfield(L, -1, KEY_next);
		lua_remove(L, -2);
	}
	bool ok = lua_isnil(L, -1);
	lua_pop(L, 1);
	return ok;
}

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
	if (*len == WIDGET_NODES_MAX || !lua_checkstack(L, 8))
		return false;
	n = &nodes[(*len)++];
	memset(n, 0, sizeof(*n));
	if (!read_node(L, idx, n) || (!n->text && !read_bindings(L, idx, n)))
		return false;
	/* "output" attaches a float to the screen's root. */
	getfield(L, idx, KEY__attach);
	if (!lua_isnil(L, -1)) {
		bool output = lua_type(L, -1) == LUA_TSTRING && !strcmp(lua_tostring(L, -1), "output");
		lua_pop(L, 1);
		if (!output || n->text || !n->floating)
			return false;
		n->attach = WIDGET_ATTACH_OUTPUT;
	} else {
		lua_pop(L, 1);
	}
	if (n->shape) {
		if (n->image)
			return false;
		n->shape = (uint16_t)luaA_rawlen(L, shapes) + 1;
		getfield(L, idx, KEY_shape);
		lua_rawseti(L, shapes, n->shape);
	}
	if (n->image)
		(*leaves)++;
	n->clip_by = (uint8_t)clip_by;

	getfield(L, idx, KEY_clip);
	bool shape_clip = n->shape && lua_toboolean(L, -1);
	lua_pop(L, 1);
	getfield(L, idx, KEY_children);
	ok = lua_isnil(L, -1) || (lua_istable(L, -1) && !n->text);
	count = ok ? luaA_rawlen(L, -1) : 0;
	n->children = (uint16_t)count;
	if (n->client && !count)
		ok = false;
	if (ok && (*len == 1 || ((n->radius > 0 || shape_clip) && count > 0))) {
		if (*clips == WIDGET_CLIPS_MAX)
			ok = false;
		n->clip_opens = (uint8_t)++*clips;
		clip_by = n->clip_opens;
	}
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
		if (entry->transform != n->transform) {
			entry->transform = n->transform;
			entry->gen++;
		}
		if (n->vector) {
			if (entry->vector != n->image) {
				image_entry_set(entry, NULL);
				entry->vector = g_object_ref((void *)n->image);
				entry->width = n->image_size[0];
				entry->height = n->image_size[1];
				entry->gen++;
			}
		} else if (entry->native != n->image) {
			image_entry_set(entry, cairo_surface_reference((cairo_surface_t *)n->image));
		}
	}
}

struct widget_storage {
    unsigned references;
    struct widget_tree payload;
};

static void storage_release(struct widget_storage *storage)
{
    if (!storage || --storage->references) return;
    widget_nodes_clear(&storage->payload);
    free(storage);
}

struct widget_tree *widget_tree_hold(struct widget_tree *d)
{
    struct widget_tree *copy = malloc(sizeof(*copy));
    uint32_t *ids = d->nodes_len ? malloc(d->nodes_len * sizeof(*ids)) : NULL;
    if (!copy || (d->nodes_len && !ids)) { free(copy); free(ids); return NULL; }
    if (!d->storage) {
        d->storage = malloc(sizeof(*d->storage));
        if (!d->storage) { free(copy); free(ids); return NULL; }
        *d->storage = (struct widget_storage) { .references = 1, .payload = *d };
        d->storage->payload.storage = NULL;
        d->storage->payload.ids = NULL;
    }
    *copy = *d;
    copy->ids = ids;
    if (ids) memcpy(ids, d->ids, d->nodes_len * sizeof(*ids));
    copy->storage->references++;
    return copy;
}

size_t widget_tree_bytes(const struct widget_tree *d)
{
    return sizeof(*d) + d->nodes_len * (sizeof(*d->nodes) + sizeof(*d->ids))
        + d->bindings_len * sizeof(*d->bindings) + d->text_len
        + d->text_attrs_len * sizeof(*d->text_attrs)
        + d->leaves_len * sizeof(*d->leaves) + d->shapes_len * sizeof(*d->shapes);
}

bool widget_tree_referenced(const struct widget_tree *d)
{
    return clay_references_memory(d->text, d->text_len, UINTPTR_MAX)
        || clay_references_memory(d->leaves, d->leaves_len * sizeof(*d->leaves), UINTPTR_MAX)
        || clay_references_memory(d->shapes, d->shapes_len * sizeof(*d->shapes), ~(uintptr_t)RENDER_SHAPE_TAG);
}

void widget_tree_release(struct widget_tree *d)
{
    if (!d) return;
    widget_nodes_clear(d);
    free(d);
}

/* Only changed input payloads copy. Declaration writes IDs and root metadata,
 * which the retained view already owns separately from these shared arrays. */
static bool widget_writable(struct widget_tree *d)
{
    if (!d->storage) return true;
    struct widget_tree copy = *d;
#define DUP(field, count) do { \
    copy.field = d->count ? malloc(d->count * sizeof(*d->field)) : NULL; \
    if (copy.field) memcpy(copy.field, d->field, d->count * sizeof(*d->field)); \
} while (0)
    DUP(nodes, nodes_len); DUP(bindings, bindings_len); DUP(text, text_len);
    DUP(text_attrs, text_attrs_len);
    DUP(leaves, leaves_len); DUP(shapes, shapes_len);
#undef DUP
    if ((d->nodes_len && !copy.nodes) || (d->bindings_len && !copy.bindings)
            || (d->text_len && !copy.text) || (d->leaves_len && !copy.leaves)
            || (d->shapes_len && !copy.shapes)
            || (d->text_attrs_len && !copy.text_attrs)) {
        free(copy.text_attrs);
        free(copy.nodes); free(copy.bindings); free(copy.text); free(copy.leaves); free(copy.shapes);
        return false;
    }
    for (size_t i = 0; i < copy.leaves_len; i++) {
        if (copy.leaves[i].native) cairo_surface_reference(copy.leaves[i].native);
        if (copy.leaves[i].vector) g_object_ref(copy.leaves[i].vector);
    }
    for (size_t i = 0; i < copy.shapes_len; i++) {
        lua_rawgeti(globalconf.L, LUA_REGISTRYINDEX, copy.shapes[i].ref);
        copy.shapes[i].ref = luaL_ref(globalconf.L, LUA_REGISTRYINDEX);
    }
    storage_release(d->storage);
    copy.storage = NULL;
    *d = copy;
    return true;
}

void
widget_nodes_clear(struct widget_tree *d)
{
    if (d->storage) {
        uint64_t generation = d->shape_generation;
        storage_release(d->storage);
        free(d->ids);
        *d = (struct widget_tree) { .shape_generation = generation };
        return;
    }
	for (size_t i = 0; i < d->shapes_len; i++)
		luaL_unref(globalconf.L, LUA_REGISTRYINDEX, d->shapes[i].ref);
	p_delete(&d->shapes);
	d->shapes_len = 0;
	for (size_t i = 0; i < d->leaves_len; i++)
		image_entry_set(&d->leaves[i], NULL);
	p_delete(&d->leaves);
	d->leaves_len = 0;
	p_delete(&d->nodes);
	p_delete(&d->ids);
	d->nodes_len = 0;
	p_delete(&d->bindings);
	d->bindings_len = 0;
	d->scrolls = 0;
	p_delete(&d->text);
	d->text_len = 0;
	p_delete(&d->text_attrs);
	d->text_attrs_len = 0;
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
 * exhaust the context and abandon the frame. */
static bool
over_budget(struct widget_tree *d, Monitor *m, size_t len, size_t scrolls)
{
	size_t total = len;

	if (!m)
		return false;
	foreach(item, globalconf.drawins) {
		drawin_t *other = *item;

		if (&other->widgets != d && other->screen
				&& luaA_monitor_get_by_screen(globalconf_L, other->screen) == m) {
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
	int count = 0;
	luaA_screen_get_all(globalconf_L, NULL, &count);
	screen_t *screens[count ? count : 1];
	luaA_screen_get_all(globalconf_L, screens, &count);
	for (int i = 0; i < count; i++) {
		if (&screens[i]->layout != d
				&& luaA_monitor_get_by_screen(globalconf_L, screens[i]) == m) {
			total += screens[i]->layout.nodes_len;
			scrolls += screens[i]->layout.scrolls;
		}
	}
	/* Inspector clips share this native budget; declare.c
	 * reserves their records before it admits any host sizing clips. */
	return total > declare_widget_budget(m->declare) || scrolls > WIDGET_SCROLLS_OUTPUT_MAX;
}

bool
widget_nodes_set(lua_State *L, struct widget_tree *d, Monitor *m, int idx)
{
	if (declare_in_frame())
		luaL_error(L, "widget tree changed from inside a frame");
    if (!widget_writable(d)) {
        declare_output_resource_failure(m ? m->declare : NULL);
        return false;
    }
	/* One scratch tree for every drawin: a redraw reads into it before
	 * the stored tree is replaced. */
	static struct widget_node nodes[WIDGET_NODES_MAX];
	size_t len = 0, leaves = 0;
	unsigned clips = 0;

	text_len = 0;
	text_attrs_len = 0;
	binding_len = 0;
	if (!lua_istable(L, idx))
		return nodes_drop(d, WIDGET_NODES_NONE);
	/* read_tree refuses a tree of its own cap's size before reading a node
	 * of it, so a full scratch tree and a tree past the clip scopes are
	 * the two failures that are a size and not a malformed table. */
	lua_pushlightuserdata(L, &keys);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_createtable(L, countof(key_names), 0);
		for (int i = 0; i < countof(key_names); i++) {
			lua_pushstring(L, key_names[i]);
			lua_rawseti(L, -2, i + 1);
		}
		lua_pushlightuserdata(L, &keys);
		lua_pushvalue(L, -2);
		lua_rawset(L, LUA_REGISTRYINDEX);
	}
	keys = lua_gettop(L);
	lua_newtable(L);
	int shapes = lua_gettop(L);
	bool ok = read_tree(L, idx, nodes, &len, &leaves, 0, &clips, shapes);
	size_t scrolls = 0;
	for (size_t i = 0; i < len; i++)
		scrolls += nodes[i].scroll != 0;
	if (!ok || over_budget(d, m, len, scrolls)) {
		lua_pop(L, 2);
		enum widget_nodes_state why = ok ? WIDGET_NODES_OVER_BUDGET
			: len == WIDGET_NODES_MAX || binding_len == WIDGET_BINDINGS_MAX || clips > WIDGET_CLIPS_MAX
			? WIDGET_NODES_OVER_BUDGET : WIDGET_NODES_MALFORMED;
		if (why != d->state)
			warn("widget tree %s, showing nothing", why == WIDGET_NODES_OVER_BUDGET
				? "over the output's element budget" : "malformed");
		return nodes_drop(d, why);
	}
	leaves_count(d, leaves);
	size_t count = luaA_rawlen(L, shapes);
	if (count != d->shapes_len) {
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
			/* A measurement declaration can remove every shape and recreate
			 * these slots before reconciliation. Never reuse the old generation
			 * for a new path at an otherwise identical command ID and box. */
			slot->shape.gen = ++d->shape_generation;
		}
		slot->shape.gradient = n->gradient;
		memcpy(slot->shape.fill, n->fill, sizeof(n->fill));
		memcpy(slot->shape.stroke, n->stroke, sizeof(n->stroke));
		slot->shape.stroke_width = n->stroke_width;
		if (slot->shape.transform != n->transform) {
			slot->shape.transform = n->transform;
			slot->shape.gen = ++d->shape_generation;
		}
	}
	lua_pop(L, 2);

	d->state = WIDGET_NODES_CONVERTED;
	p_delete(&d->nodes);
	d->nodes = p_new(struct widget_node, len);
	memcpy(d->nodes, nodes, len * sizeof(*nodes));
	d->nodes_len = len;
	p_realloc(&d->ids, len);
	p_delete(&d->bindings);
	d->bindings = binding_len ? p_dup(binding_buf, binding_len) : NULL;
	d->bindings_len = binding_len;
	d->scrolls = scrolls;
	p_delete(&d->text);
	d->text = text_len ? p_dup(text_buf, text_len) : NULL;
	d->text_len = text_len;
	p_delete(&d->text_attrs);
	d->text_attrs = text_attrs_len ? p_dup(text_attrs_buf, text_attrs_len) : NULL;
	d->text_attrs_len = text_attrs_len;
	d->declared = false;
	return true;
}
