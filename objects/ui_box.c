#include "ui_box.h"
#include "node_face.h"
#include "drawin.h"
#include "screen.h"
#include "../declare.h"
#include "../luaa.h"
#include "../globalconf.h"
#include "../render_text.h"
#include "../clay_impl.h"
#include "key.h"
#include "common/luaobject.h"
#include "common/lualib.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int
bad_word(lua_State *L, const char *word, int index)
{
	const char *value = lua_tostring(L, index);
	if (!value) value = lua_isboolean(L, index)
		? (lua_toboolean(L, index) ? "true" : "false") : luaL_typename(L, index);
	return luaL_error(L, "ui.box %s: invalid value %s", word, value);
}

static float
number(lua_State *L, int index, const char *word, float low, float high)
{
	double value = lua_tonumber(L, index);
	if (lua_type(L, index) != LUA_TNUMBER || !isfinite(value) || value < low || value > high)
		bad_word(L, word, index);
	return value;
}

static uint16_t
integer_word(lua_State *L, int index, const char *word)
{
	double value = lua_tonumber(L, index);
	if (lua_type(L, index) != LUA_TNUMBER || !isfinite(value)
			|| value < 0 || value > UINT16_MAX || floor(value) != value)
		bad_word(L, word, index);
	return value;
}

/* Words are stored as floats. A whole value returns as an integer, so Lua 5.3
 * prints 10 rather than 10.0, as drawin geometry does. */
static void
push_word(lua_State *L, float value)
{
	if (value == floorf(value) && fabsf(value) < 1e9f)
		lua_pushinteger(L, (lua_Integer)value);
	else
		lua_pushnumber(L, value);
}

static void
ui_box_color(lua_State *L, int index, const char *word, float color[4])
{
	int top = lua_gettop(L);
	index = luaA_absindex(L, index);
	lua_getglobal(L, "require");
	lua_pushliteral(L, "wibox.clay");
	lua_call(L, 1, 1);
	lua_getfield(L, -1, "solid_rgba");
	lua_pushvalue(L, index);
	if (lua_pcall(L, 1, 1, 0) || !lua_istable(L, -1)) {
		lua_settop(L, top);
		const char *value = lua_tostring(L, index);
		luaL_error(L, "ui.box %s: invalid solid color %s (gradients require step 4)",
			word, value ? value : luaL_typename(L, index));
	}
	for (int i = 0; i < 4; i++) {
		lua_rawgeti(L, -1, i + 1);
		color[i] = lua_tonumber(L, -1);
		lua_pop(L, 1);
	}
	lua_settop(L, top);
}

static void
array_word(lua_State *L, int index, const char *word, size_t count)
{
	lua_pushnil(L);
	while (lua_next(L, index)) {
		double key = lua_tonumber(L, -2);
		if (lua_type(L, -2) != LUA_TNUMBER || key < 1 || key > count || floor(key) != key)
			bad_word(L, word, index);
		lua_pop(L, 1);
	}
}

static void
size_word(lua_State *L, int index, const char *word, struct node_words *w, int axis)
{
	w->size[axis] = w->min[axis] = w->max[axis] = 0;
	w->plain_grow &= ~(1 << axis);
	if (lua_isnil(L, index)) {
		w->size_words &= ~(1 << axis);
		w->sizing[axis] = WIDGET_SIZING_FIT;
		return;
	}
	w->size_words |= 1 << axis;
	if (lua_type(L, index) == LUA_TNUMBER) {
		w->size[axis] = number(L, index, word, 0, 1e9);
		w->sizing[axis] = WIDGET_SIZING_FIXED;
		return;
	}
	if (lua_istable(L, index)) {
		if (luaA_rawlen(L, index) != 3) bad_word(L, word, index);
		array_word(L, index, word, 3);
		lua_rawgeti(L, index, 1);
		const char *kind = lua_tostring(L, -1);
		if (!kind || (strcmp(kind, "fit") && strcmp(kind, "grow"))) bad_word(L, word, index);
		w->sizing[axis] = !strcmp(kind, "grow") ? WIDGET_SIZING_GROW : WIDGET_SIZING_FIT;
		lua_pop(L, 1);
		lua_rawgeti(L, index, 2);
		w->min[axis] = number(L, -1, word, 0, 1e9);
		lua_pop(L, 1);
		lua_rawgeti(L, index, 3);
		w->max[axis] = number(L, -1, word, 0, 1e9);
		lua_pop(L, 1);
		if (w->max[axis] && w->max[axis] < w->min[axis]) bad_word(L, word, index);
		return;
	}
	const char *value = lua_tostring(L, index);
	if (value && (!strcmp(value, "fit") || !strcmp(value, "grow"))) {
		w->sizing[axis] = !strcmp(value, "fit") ? WIDGET_SIZING_FIT : WIDGET_SIZING_GROW;
		if (!strcmp(value, "grow")) w->plain_grow |= 1 << axis;
		return;
	}
	char *end;
	double percent = value ? strtod(value, &end) : -1;
	if (!value || end == value || strcmp(end, "%") || !isfinite(percent) || percent < 0 || percent > 100)
		bad_word(L, word, index);
	w->sizing[axis] = WIDGET_SIZING_PERCENT;
	w->size[axis] = percent / 100;
}

static void
quad_word(lua_State *L, int index, const char *word, uint16_t *out,
	uint16_t *between)
{
	uint8_t seen = 0;
	if (lua_type(L, index) == LUA_TNUMBER) {
		uint16_t value = integer_word(L, index, word);
		for (int i = 0; i < 4; i++) out[i] = value;
		if (between) *between = 0;
		return;
	}
	if (!lua_istable(L, index)) bad_word(L, word, index);
	memset(out, 0, 4 * sizeof(*out));
	if (between) *between = 0;
	size_t len = luaA_rawlen(L, index);
	if (len) {
		if (len != 4 && len != (between ? 5 : 2)) bad_word(L, word, index);
		array_word(L, index, word, len);
		for (size_t i = 0; i < len; i++) {
			lua_rawgeti(L, index, i + 1);
			uint16_t value = integer_word(L, -1, word);
			lua_pop(L, 1);
			if (len == 2) out[i * 2] = out[i * 2 + 1] = value;
			else if (i < 4) out[i] = value;
			else *between = value;
		}
		return;
	}
	lua_pushnil(L);
	while (lua_next(L, index)) {
		const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : NULL;
		int side = -1;
		for (int i = 0; key && i < (between ? 5 : 4); i++)
			if (!strcmp(key, drawin_sides[i])) side = i;
		if (!between && key && (!strcmp(key, "x") || !strcmp(key, "y"))) {
			int axis = !strcmp(key, "x") ? 0 : 1;
			if (seen & 15) bad_word(L, word, index);
			out[axis * 2] = out[axis * 2 + 1] = integer_word(L, -1, word);
			seen |= 16 << axis;
		} else if (side >= 0) {
			if (!between && (seen & 48)) bad_word(L, word, index);
			uint16_t value = integer_word(L, -1, word);
			if (side < 4) out[side] = value;
			else *between = value;
			seen |= 1 << side;
		} else bad_word(L, word, index);
		lua_pop(L, 1);
	}
}

static void
ui_function(lua_State *L, const char *name)
{
	lua_getglobal(L, "require");
	lua_pushliteral(L, "ui");
	lua_call(L, 1, 1);
	lua_getfield(L, -1, name);
	lua_remove(L, -2);
}

static void
ui_helper(lua_State *L, const char *name, int index)
{
	index = luaA_absindex(L, index);
	ui_function(L, name);
	lua_pushvalue(L, index);
	lua_call(L, 1, 1);
}

static uint16_t
font_word(lua_State *L, int index)
{
	if (lua_type(L, index) != LUA_TSTRING) bad_word(L, "font", index);
	ui_helper(L, "_font", index);
	int32_t id = render_font_intern(luaL_checkstring(L, -1));
	lua_pop(L, 1);
	if (id < 0) luaL_error(L, "ui.box font: cannot intern font");
	return id;
}

static enum node_layer
layer_word(lua_State *L, int index)
{
	static const char *const names[] = {
		"background", "bottom", "below", "normal", "above", "fullscreen", "ontop", "top", "overlay"
	};
	/* Desktop, plain and ontop wiboxes use WIBOX_DESKTOP, WIBOX and
	 * WIBOX_ONTOP. The other names select their public band's first slot. */
	static const enum node_layer bands[] = {
		LAYER_WIBOX_DESKTOP, LAYER_BOTTOM, LAYER_BELOW, LAYER_WIBOX,
		LAYER_ABOVE, LAYER_FULLSCREEN, LAYER_ONTOP, LAYER_WIBOX_ONTOP, LAYER_OVERLAY
	};
	const char *name = lua_tostring(L, index);
	for (size_t i = 0; name && i < countof(names); i++)
		if (!strcmp(name, names[i])) return bands[i];
	bad_word(L, "layer", index);
	return LAYER_WIBOX;
}

static void
content_check(lua_State *L, const struct node_words *w, bool children)
{
	if (w->text && w->image) luaL_error(L, "ui.box: text and image cannot both be set");
	if (children && (w->text || w->image))
		luaL_error(L, "a box with %s cannot have children", w->text ? "text" : "image");
}

/* Validation borrows strings and holds decoded images on the Lua stack.
 * Only a successful write transfers them into the node's owned words. */
static void
words_own(lua_State *L, struct node_words *next, const struct node_words *old, int pending)
{
	if (next->cursor != old->cursor) {
		next->cursor = next->cursor ? strdup(next->cursor) : NULL;
		free(old->cursor);
	}
	if (next->attachment.set != old->attachment.set || next->attachment.to != old->attachment.to) {
		luaL_unref(L, LUA_REGISTRYINDEX, old->attachment_ref);
		lua_getfield(L, pending, "attachment_to");
		next->attachment_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	}
	if (next->text != old->text) {
		next->text = next->text ? p_dup(next->text, next->text_len + 1) : NULL;
		free(old->text);
	}
	if (next->font_name != old->font_name) {
		next->font_name = next->font_name ? strdup(next->font_name) : NULL;
		free(old->font_name);
	}
	if (next->image != old->image) {
		luaL_unref(L, LUA_REGISTRYINDEX, old->image_ref);
		lua_getfield(L, pending, "image");
		next->image_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	}
}

static void
animation_word(lua_State *L, struct node_words *w, int index, int pending,
	bool screen)
{
	ui_helper(L, "_animation_policy", index);
	w->animation_disabled = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
	w->transition = (struct widget_transition){0};
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "visible");
		if (!lua_isnil(L, -1) && !screen)
			luaL_error(L, "ui.box animation.visible on a nested box requires the renderer in step 4");
		lua_newtable(L);
		lua_pushvalue(L, -2);
		lua_setfield(L, -2, "transition");
		if (!widget_read_transition(L, lua_gettop(L), &w->transition))
			luaL_error(L, "ui.box animation.visible has an invalid transition");
		lua_pop(L, 2);
	}
	lua_setfield(L, pending, "animation");
}

void
ui_box_transition(lua_State *L, struct node *box, bool off,
	struct widget_transition *out)
{
	int top = lua_gettop(L);
	lua_newtable(L);
	node_face_push(L, box);
	lua_setfield(L, -2, "box");
	lua_pushboolean(L, off);
	lua_setfield(L, -2, "off");
	ui_helper(L, "_animation_word", -1);
	if (!widget_read_transition(L, lua_gettop(L), out))
		luaL_error(L, "ui.box animation: invalid transition");
	lua_getfield(L, -1, "x");
	if (!lua_toboolean(L, -1)) out->properties &= ~CLAY_TRANSITION_PROPERTY_X;
	lua_pop(L, 1);
	lua_getfield(L, -1, "y");
	if (!lua_toboolean(L, -1)) out->properties &= ~CLAY_TRANSITION_PROPERTY_Y;
	lua_pop(L, 1);
	const struct widget_transition *visible = &box->words.transition;
	if (visible->enabled) {
		out->enabled = true;
		out->properties |= visible->properties;
		out->duration = fmaxf(out->duration, visible->duration);
		out->enter_state = visible->enter_state;
		out->exit_state = visible->exit_state;
		out->tag_exit = visible->tag_exit;
		out->exit_order = visible->exit_order;
	}
	if (off) out->duration = 0;
	lua_settop(L, top);
}

static const char *const edges[] = {NULL, "top", "bottom", "left", "right"};
static const char *const anchors[] = {
	"top_left", "left", "bottom_left", "top", "center", "bottom",
	"top_right", "right", "bottom_right"
};

static void
table_keys(lua_State *L, int index, const char *word, const char *const *keys, size_t len)
{
	luaL_checktype(L, index, LUA_TTABLE);
	lua_pushnil(L);
	while (lua_next(L, index)) {
		const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : NULL;
		bool known = false;
		for (size_t i = 0; key && i < len; i++) known |= !strcmp(key, keys[i]);
		if (!known) {
			lua_pushvalue(L, -2);
			luaL_error(L, "ui.box %s: unknown key %s", word,
				lua_isstring(L, -1) ? lua_tostring(L, -1) : luaL_typename(L, -1));
		}
		lua_pop(L, 1);
	}
}

static uint8_t
anchor_word(lua_State *L, int index)
{
	if (lua_isnil(L, index)) return 0;
	const char *name = lua_type(L, index) == LUA_TSTRING ? lua_tostring(L, index) : NULL;
	for (size_t i = 0; name && i < countof(anchors); i++)
		if (!strcmp(name, anchors[i])) return i;
	bad_word(L, "attachment anchor", index);
	return 0;
}

static void
attachment_word(lua_State *L, struct node_words *w, int index, int pending, struct node *parent)
{
	w->attachment = (typeof(w->attachment)){0};
	if (lua_isnil(L, index)) return;
	if (parent->kind != NODE_SCREEN)
		luaL_error(L, "ui.box attachment applies to a screen box");
	static const char *const keys[] = {"to", "anchor", "offset"};
	table_keys(L, index, "attachment", keys, countof(keys));
	w->attachment.set = true;
	lua_getfield(L, index, "to");
	if (lua_isnil(L, -1)) { lua_pop(L, 1); node_owner_push(L, parent); }
	screen_t *screen = luaA_toscreen(L, -1);
	struct node *target = screen ? screen->node : node_face_check(L, -1);
	if (!target || (!screen && !target->ui_box)) bad_word(L, "attachment to", -1);
	w->attachment.to = target->id;
	struct node *host = target;
	if (!screen) {
		while (host->parent && host->parent->ui_box) host = host->parent;
		if (host->parent != parent)
			luaL_error(L, "ui.box attachment: target is on another screen");
		w->attachment.target = target->id;
		/* A box host contains no Lua widgets, so matching its host prevents
		 * collisions between box IDs and Lua widget identities. */
		w->attachment.host = (uint32_t)node_handle(host);
	} else if (target != parent)
		luaL_error(L, "ui.box attachment: target is on another screen");
	lua_setfield(L, pending, "attachment_to");
	lua_getfield(L, index, "anchor");
	if (lua_istable(L, -1)) {
		static const char *const anchor_keys[] = {"target", "self"};
		table_keys(L, lua_gettop(L), "attachment anchor", anchor_keys, countof(anchor_keys));
		lua_getfield(L, -1, "target"); w->attachment.parent = anchor_word(L, -1); lua_pop(L, 1);
		lua_getfield(L, -1, "self"); w->attachment.own = anchor_word(L, -1); lua_pop(L, 1);
	} else w->attachment.parent = anchor_word(L, -1);
	lua_pop(L, 1);
	lua_getfield(L, index, "offset");
	if (!lua_isnil(L, -1)) {
		static const char *const offset_keys[] = {"x", "y"};
		table_keys(L, lua_gettop(L), "attachment offset", offset_keys, countof(offset_keys));
		lua_getfield(L, -1, "x");
		if (!lua_isnil(L, -1)) w->attachment.x = number(L, -1, "attachment offset x", -1e9, 1e9);
		lua_pop(L, 1);
		lua_getfield(L, -1, "y");
		if (!lua_isnil(L, -1)) w->attachment.y = number(L, -1, "attachment offset y", -1e9, 1e9);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
}

static void
word_set(lua_State *L, struct node_words *w, bool *hidden, const char **label,
	const char *word, int index, int pending, struct node *parent)
{
	if (!strcmp(word, "width") || !strcmp(word, "height")) {
		size_word(L, index, word, w, !strcmp(word, "height"));
	} else if (!strcmp(word, "position")) {
		w->edge = 0;
		if (lua_isnil(L, index)) { w->restrict_set = false; w->no_reserve = false; }
		else {
			const char *value = lua_type(L, index) == LUA_TSTRING ? lua_tostring(L, index) : NULL;
			for (size_t i = 1; value && i < countof(edges); i++)
				if (!strcmp(value, edges[i])) w->edge = i;
			if (!w->edge) bad_word(L, word, index);
		}
	} else if (!strcmp(word, "restrict_workarea") || !strcmp(word, "input_passthrough")) {
		if (!lua_isnil(L, index) && !lua_isboolean(L, index)) bad_word(L, word, index);
		if (!strcmp(word, "restrict_workarea")) {
			w->restrict_set = !lua_isnil(L, index);
			w->no_reserve = w->restrict_set && !lua_toboolean(L, index);
		} else w->input_passthrough = lua_toboolean(L, index);
	} else if (!strcmp(word, "cursor")) {
		if (!lua_isnil(L, index) && lua_type(L, index) != LUA_TSTRING) bad_word(L, word, index);
		const char *value = lua_tostring(L, index);
		if (!value || !w->cursor || strcmp(value, w->cursor)) w->cursor = (char *)value;
	} else if (!strcmp(word, "attachment")) {
		attachment_word(L, w, index, pending, parent);
	} else if (!strcmp(word, "aspect_ratio")) w->aspect = number(L, index, word, 0, 1e9);
	else if (!strcmp(word, "gap")) w->gap = integer_word(L, index, word);
	else if (!strcmp(word, "radius")) {
		if (lua_istable(L, index)) luaL_error(L, "ui.box radius: value table requires step 4");
		w->radius = number(L, index, word, 0, 1e9);
	} else if (!strcmp(word, "direction")) {
		const char *v = lua_tostring(L, index);
		if (!v || (strcmp(v, "row") && strcmp(v, "column"))) bad_word(L, word, index);
		w->vertical = !strcmp(v, "column");
	} else if (!strcmp(word, "padding")) {
		quad_word(L, index, word, w->pad, NULL);
	} else if (!strcmp(word, "border_width")) {
		quad_word(L, index, word, w->bw, &w->between);
	} else if (!strcmp(word, "align")) {
		w->align[0] = w->align[1] = 0;
		if (lua_istable(L, index)) {
			lua_pushnil(L);
			while (lua_next(L, index)) {
				const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : NULL;
				if (!key || (strcmp(key, "x") && strcmp(key, "y"))) bad_word(L, word, index);
				int axis = !strcmp(key, "y");
				const char *value = lua_tostring(L, -1);
				int align = !value ? -1 : !strcmp(value, "center") ? 2
					: !strcmp(value, drawin_sides[axis * 2]) ? 0
					: !strcmp(value, drawin_sides[axis * 2 + 1]) ? 1 : -1;
				if (align < 0) bad_word(L, word, -1);
				w->align[axis] = align;
				lua_pop(L, 1);
			}
		} else {
			const char *value = lua_tostring(L, index);
			if (!value) bad_word(L, word, index);
			if (!strcmp(value, "center")) w->align[0] = w->align[1] = 2;
			else if (!strcmp(value, "right")) w->align[0] = 1;
			else if (!strcmp(value, "bottom")) w->align[1] = 1;
			else if (strcmp(value, "left") && strcmp(value, "top")) bad_word(L, word, index);
		}
	} else if (!strcmp(word, "clip")) {
		if (lua_isboolean(L, index)) w->cut = lua_toboolean(L, index) ? 3 : 0;
		else {
			const char *v = lua_tostring(L, index);
			if (!v || (strcmp(v, widget_axes[0]) && strcmp(v, widget_axes[1]))) bad_word(L, word, index);
			w->cut = !strcmp(v, widget_axes[0]) ? 1 : 2;
		}
	} else if (!strcmp(word, "x") || !strcmp(word, "y")) {
		int axis = !strcmp(word, "y");
		w->position[axis] = lua_isnil(L, index) ? 0 : number(L, index, word, -1e9, 1e9);
		if (lua_isnil(L, index)) w->placed &= ~(1 << axis);
		else w->placed |= 1 << axis;
	} else if (!strcmp(word, "bg") || !strcmp(word, "border_color")) {
		float *color = !strcmp(word, "bg") ? w->bg : w->border;
		if (lua_isnil(L, index)) { memset(color, 0, 4 * sizeof(*color)); color[3] = -1; }
		else ui_box_color(L, index, word, color);
	} else if (!strcmp(word, "fg")) {
		if (lua_isnil(L, index)) { memset(w->fg, 0, sizeof(w->fg)); w->fg[3] = -1; }
		else ui_box_color(L, index, word, w->fg);
	} else if (!strcmp(word, "opacity")) w->opacity = number(L, index, word, 0, 1);
	else if (!strcmp(word, "font")) {
		if (!lua_isnil(L, index) && lua_type(L, index) != LUA_TSTRING) bad_word(L, word, index);
		const char *value = lua_isnil(L, index) ? NULL : lua_tostring(L, index);
		w->font = lua_isnil(L, index) ? 0 : font_word(L, index);
		if (!value || !w->font_name || strcmp(value, w->font_name)) w->font_name = (char *)value;
	} else if (!strcmp(word, "text")) {
		if (!lua_isnil(L, index) && lua_type(L, index) != LUA_TSTRING) bad_word(L, word, index);
		size_t len = 0;
		const char *value = lua_tolstring(L, index, &len);
		if (len >= WIDGET_TEXT_MAX) bad_word(L, word, index);
		if (!value || !w->text || len != w->text_len || memcmp(value, w->text, len))
			w->text = (char *)value;
		w->text_len = len;
	} else if (!strcmp(word, "wrap")) {
		static const char *const wraps[] = {"words", "newlines", "none"};
		const char *value = lua_tostring(L, index);
		int wrap = -1;
		for (int i = 0; value && i < 3; i++) if (!strcmp(value, wraps[i])) wrap = i;
		if (wrap < 0) bad_word(L, word, index);
		w->wrap = wrap;
	} else if (!strcmp(word, "ellipsize")) {
		if (!lua_isboolean(L, index)) bad_word(L, word, index);
		w->ellipsize = lua_toboolean(L, index);
	} else if (!strcmp(word, "image")) {
		w->image = NULL;
		w->vector = false;
		memset(w->image_size, 0, sizeof(w->image_size));
		if (!lua_isnil(L, index)) {
			ui_helper(L, "_image", index);
			lua_getfield(L, -1, "native");
			if (!lua_islightuserdata(L, -1)) bad_word(L, word, index);
			w->image = lua_touserdata(L, -1); lua_pop(L, 1);
			lua_getfield(L, -1, "vector"); w->vector = lua_toboolean(L, -1); lua_pop(L, 1);
			lua_getfield(L, -1, "width"); w->image_size[0] = number(L, -1, word, 1, 1e6); lua_pop(L, 1);
			lua_getfield(L, -1, "height"); w->image_size[1] = number(L, -1, word, 1, 1e6); lua_pop(L, 1);
			lua_getfield(L, -1, "object"); lua_setfield(L, pending, "image");
			lua_pop(L, 1);
		}
	} else if (!strcmp(word, "shape") || !strcmp(word, "shadow")
		|| !strcmp(word, "rotation") || !strcmp(word, "mirror")
		|| !strcmp(word, "image_color") || !strcmp(word, "line_height")) {
		luaL_error(L, "ui.box %s requires the renderer in step 4", word);
	} else if (!strcmp(word, "visible")) {
		if (!lua_isboolean(L, index)) bad_word(L, word, index);
		*hidden = !lua_toboolean(L, index);
	} else if (!strcmp(word, "label")) {
		if (!lua_isnil(L, index) && lua_type(L, index) != LUA_TSTRING) bad_word(L, word, index);
		*label = lua_tostring(L, index);
	} else luaL_error(L, "ui.box: unknown word %s", word);
}

static void
check_placement(lua_State *L, struct node_words *w, struct node *parent)
{
	if (w->edge) {
		if (parent->kind != NODE_SCREEN)
			luaL_error(L, "ui.box position under a box is reserved");
		if (w->placed || w->attachment.set)
			luaL_error(L, "ui.box position cannot be combined with %s",
				w->placed & 1 ? "x" : w->placed & 2 ? "y" : "attachment");
		int thickness = w->edge == DRAWIN_EDGE_TOP || w->edge == DRAWIN_EDGE_BOTTOM ? 1 : 0;
		if (w->sizing[thickness] != WIDGET_SIZING_FIXED)
			luaL_error(L, "ui.box position: %s must be a number on a %s bar",
				thickness ? "height" : "width", edges[w->edge]);
		int length = 1 - thickness;
		if ((w->size_words & (1 << length)) && !(w->plain_grow & (1 << length)))
			luaL_error(L, "ui.box position: %s must be grow or absent on a %s bar",
				length ? "height" : "width", edges[w->edge]);
	} else if (w->restrict_set) luaL_error(L, "ui.box restrict_workarea requires position");
	if (w->attachment.set) {
		if (parent->kind != NODE_SCREEN) luaL_error(L, "ui.box attachment applies to a screen box");
		if (w->placed) luaL_error(L, "ui.box attachment cannot be combined with %s", w->placed & 1 ? "x" : "y");
	}
	if (!w->placed) return;
	if (parent->kind != NODE_SCREEN || w->sizing[0] != WIDGET_SIZING_FIXED
			|| w->sizing[1] != WIDGET_SIZING_FIXED)
		luaL_error(L, "ui.box x/y require a screen parent and numeric width and height");
}

void
ui_box_dirty(struct node *n)
{
	while (n->parent && n->parent->ui_box) n = n->parent;
	if (n->owner_kind == DECLARE_KIND_DRAWIN) {
		drawin_t *d = n->owner;
		const struct node_words *w = &n->words;
		d->bar = (typeof(d->bar)){.edge = w->edge, .reserve = w->edge && !w->no_reserve,
			.stretch = w->edge != 0};
		if (w->edge) {
			if (w->edge == DRAWIN_EDGE_TOP || w->edge == DRAWIN_EDGE_BOTTOM) d->height = w->size[1];
			else d->width = w->size[0];
		}
		d->attachment = (typeof(d->attachment)){.kind = w->attachment.set ? 1 : 0,
			.target = w->attachment.target, .occurrence = w->attachment.target,
			.host = w->attachment.host, .parent = w->attachment.parent, .own = w->attachment.own,
			.x = w->attachment.x, .y = w->attachment.y};
		d->input_passthrough = w->input_passthrough;
		if ((!d->cursor != !w->cursor) || (d->cursor && w->cursor && strcmp(d->cursor, w->cursor))) {
			free(d->cursor);
			d->cursor = w->cursor ? strdup(w->cursor) : NULL;
		}
		d->ui_dirty = true;
		drawin_mark_dirty(d);
	}
}

static int
animate_once(lua_State *L)
{
	node_face_check(L, 1);
	ui_function(L, "_animate");
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_call(L, 2, 0);
	/* Consume the request even when every setter kept its current value. */
	ui_box_dirty(node_face_check(L, 1));
	return 0;
}

bool
ui_box_get(lua_State *L, struct node *n, const char *word)
{
	struct node_words *w = &n->words;
	if (!strcmp(word, "position")) lua_pushstring(L, edges[w->edge]);
	else if (!strcmp(word, "restrict_workarea")) lua_pushboolean(L, !w->no_reserve);
	else if (!strcmp(word, "input_passthrough")) lua_pushboolean(L, w->input_passthrough);
	else if (!strcmp(word, "cursor")) lua_pushstring(L, w->cursor);
	else if (!strcmp(word, "attachment")) {
		if (!w->attachment.set) lua_pushnil(L);
		else {
			lua_newtable(L);
			lua_rawgeti(L, LUA_REGISTRYINDEX, w->attachment_ref); lua_setfield(L, -2, "to");
			lua_newtable(L);
			lua_pushstring(L, anchors[w->attachment.parent]); lua_setfield(L, -2, "target");
			lua_pushstring(L, anchors[w->attachment.own]); lua_setfield(L, -2, "self");
			lua_setfield(L, -2, "anchor");
			lua_newtable(L);
			push_word(L, w->attachment.x); lua_setfield(L, -2, "x");
			push_word(L, w->attachment.y); lua_setfield(L, -2, "y");
			lua_setfield(L, -2, "offset");
		}
	} else if (!strcmp(word, "animation")) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, w->animation_ref);
		ui_helper(L, "_animation_copy", -1);
		lua_remove(L, -2);
	} else if (!strcmp(word, "animate")) lua_pushcfunction(L, animate_once);
	else if (!strcmp(word, "get_animation") || !strcmp(word, "set_animation")) {
		ui_function(L, !strcmp(word, "get_animation") ? "_get_animation" : "_set_animation");
	} else if (!strcmp(word, "width") || !strcmp(word, "height")) {
		int axis = !strcmp(word, "height");
		if (w->sizing[axis] == WIDGET_SIZING_FIXED) push_word(L, w->size[axis]);
		else if (w->sizing[axis] == WIDGET_SIZING_PERCENT) {
			char value[40]; snprintf(value, sizeof(value), "%g%%", w->size[axis] * 100);
			lua_pushstring(L, value);
		} else {
			const char *kind = w->sizing[axis] == WIDGET_SIZING_GROW ? "grow" : "fit";
			if (!w->min[axis] && !w->max[axis]) lua_pushstring(L, kind);
			else {
				lua_createtable(L, 3, 0);
				lua_pushstring(L, kind); lua_rawseti(L, -2, 1);
				push_word(L, w->min[axis]); lua_rawseti(L, -2, 2);
				push_word(L, w->max[axis]); lua_rawseti(L, -2, 3);
			}
		}
	} else if (!strcmp(word, "aspect_ratio")) lua_pushnumber(L, w->aspect);
	else if (!strcmp(word, "gap")) push_word(L, w->gap);
	else if (!strcmp(word, "radius")) push_word(L, w->radius);
	else if (!strcmp(word, "direction")) lua_pushstring(L, w->vertical ? "column" : "row");
	else if (!strcmp(word, "padding") || !strcmp(word, "border_width")) {
		bool border = !strcmp(word, "border_width");
		const uint16_t *v = border ? w->bw : w->pad;
		if (v[0] == v[1] && v[0] == v[2] && v[0] == v[3] && (!border || !w->between))
			lua_pushinteger(L, v[0]);
		else {
			lua_newtable(L);
			for (int i = 0; i < (border ? 5 : 4); i++) {
				lua_pushinteger(L, i == 4 ? w->between : v[i]);
				lua_setfield(L, -2, drawin_sides[i]);
			}
		}
	} else if (!strcmp(word, "align")) {
		lua_newtable(L);
		for (int a = 0; a < 2; a++) {
			lua_pushstring(L, w->align[a] == 2 ? "center" : drawin_sides[a * 2 + w->align[a]]);
			lua_setfield(L, -2, widget_axes[a]);
		}
	} else if (!strcmp(word, "clip")) {
		if (w->cut == 1 || w->cut == 2) lua_pushstring(L, widget_axes[w->cut - 1]);
		else lua_pushboolean(L, w->cut == 3);
	} else if (!strcmp(word, "bg") || !strcmp(word, "border_color") || !strcmp(word, "fg")) {
		const float *c = !strcmp(word, "bg") ? w->bg : !strcmp(word, "fg") ? w->fg : w->border;
		if (c[3] < 0) lua_pushnil(L);
		else {
			char value[10];
			snprintf(value, sizeof(value), "#%02x%02x%02x%02x", (unsigned)lroundf(c[0] * 255),
				(unsigned)lroundf(c[1] * 255), (unsigned)lroundf(c[2] * 255), (unsigned)lroundf(c[3] * 255));
			lua_pushstring(L, value);
		}
	} else if (!strcmp(word, "text")) {
		if (w->text) lua_pushlstring(L, w->text, w->text_len); else lua_pushnil(L);
	} else if (!strcmp(word, "font")) lua_pushstring(L, w->font_name);
	else if (!strcmp(word, "image")) lua_rawgeti(L, LUA_REGISTRYINDEX, w->image_ref);
	else if (!strcmp(word, "opacity")) lua_pushnumber(L, w->opacity);
	else if (!strcmp(word, "ellipsize")) lua_pushboolean(L, w->ellipsize);
	else if (!strcmp(word, "wrap")) {
		static const char *const wraps[] = {"words", "newlines", "none"};
		lua_pushstring(L, wraps[w->wrap]);
	} else if (!strcmp(word, "visible")) lua_pushboolean(L, !n->hidden);
	else if (!strcmp(word, "x") || !strcmp(word, "y")) push_word(L, w->position[!strcmp(word, "y")]);
	else return false;
	return true;
}

int
ui_box_set(lua_State *L, struct node *n, const char *word, int index)
{
	index = luaA_absindex(L, index);
	if (declare_in_frame()) return luaL_error(L, "ui.box words changed from inside a frame");
	struct node_words next = n->words;
	bool hidden = n->hidden;
	const char *label = n->label;
	lua_newtable(L);
	int pending = lua_gettop(L);
	enum node_layer layer = n->layer;
	if (!strcmp(word, "layer")) {
		if (!n->parent || n->parent->kind != NODE_SCREEN)
			return luaL_error(L, "layer applies to a screen box");
		layer = layer_word(L, index);
	} else if (!strcmp(word, "animation"))
		animation_word(L, &next, index, pending, n->parent && n->parent->kind == NODE_SCREEN);
	else word_set(L, &next, &hidden, &label, word, index, pending, n->parent);
	content_check(L, &next, !wl_list_empty(&n->children));
	check_placement(L, &next, n->parent);
	bool relabel = (!label != !n->label) || (label && n->label && strcmp(label, n->label));
	bool changed = !strcmp(word, "animation") || layer != n->layer || relabel || hidden != n->hidden || memcmp(&next, &n->words, sizeof(next));
	if (changed) {
		if (!strcmp(word, "animation")) {
			lua_getfield(L, pending, "animation");
			int ref = luaL_ref(L, LUA_REGISTRYINDEX);
			luaL_unref(L, LUA_REGISTRYINDEX, n->words.animation_ref);
			next.animation_ref = ref;
		}
		words_own(L, &next, &n->words, pending);
		n->words = next;
		if (layer != n->layer) { n->layer = layer; declare_mark_all_dirty(); }
		n->hidden = hidden;
		if (relabel) node_set_label(n, label);
		ui_box_dirty(n);
		char signal[80]; snprintf(signal, sizeof(signal), "property::%s", word);
		node_face_push(L, n);
		luaA_object_emit_signal(L, -1, signal, 0);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return 0;
}

void
ui_box_detach(lua_State *L, struct node *n)
{
	drawin_t *d = n->owner_kind == DECLARE_KIND_DRAWIN ? n->owner : NULL;
	ui_box_dirty(n);
	node_destroy(n);
	if (d) drawin_ui_release(L, d);
}

void
ui_box_release(struct node *n)
{
	if (!n->ui_box) return;
	if (n->owner_kind == DECLARE_KIND_DRAWIN) {
		drawin_t *d = n->owner;
		free(d->cursor);
		d->cursor = NULL;
		d->node = NULL;
	}
	lua_State *L = globalconf_get_lua_State();
	free(n->words.text);
	free(n->words.font_name);
	free(n->words.cursor);
	if (!L) return;
	luaL_unref(L, LUA_REGISTRYINDEX, n->words.image_ref);
	luaL_unref(L, LUA_REGISTRYINDEX, n->words.animation_ref);
	luaL_unref(L, LUA_REGISTRYINDEX, n->words.attachment_ref);
	node_face_forget(L, n);
}

int
ui_box_new(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_getfield(L, 1, "parent");
	if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushvalue(L, 2); }
	if (!luaA_toscreen(L, -1) && !lua_isuserdata(L, -1))
		return luaL_error(L, "ui.box parent: expected screen or box");
	screen_t *screen = luaA_toscreen(L, -1);
	struct node *parent = screen ? screen->node : node_face_check(L, -1);
	if (!parent || (!screen && !parent->ui_box)) return luaL_error(L, "ui.box parent: expected screen or box");
	lua_pop(L, 1);
	struct node_words words = {.opacity = 1, .bg = {0, 0, 0, -1}, .border = {0, 0, 0, -1},
		.fg = {0, 0, 0, -1}, .default_fg = {1, 1, 1, 1}, .ellipsize = true,
		.image_ref = LUA_NOREF, .animation_ref = LUA_NOREF, .attachment_ref = LUA_NOREF};
	if (lua_istable(L, 3)) {
		lua_getfield(L, 3, "fg");
		if (!lua_isnil(L, -1)) ui_box_color(L, -1, "fg", words.default_fg);
		lua_pop(L, 1);
		lua_getfield(L, 3, "font");
		if (!lua_isnil(L, -1)) words.default_font = font_word(L, -1);
		lua_pop(L, 1);
	}
	lua_newtable(L);
	int pending = lua_gettop(L);
	enum node_layer layer = LAYER_WIBOX;
	bool hidden = false;
	const char *label = NULL;
	/* Validate the entire constructor before adopting any child. */
	size_t count = 0;
	lua_pushnil(L);
	while (lua_next(L, 1)) {
		if (lua_type(L, -2) == LUA_TSTRING) {
			const char *key = lua_tostring(L, -2);
			if (!strcmp(key, "layer")) {
				if (!screen) return luaL_error(L, "layer applies to a screen box");
				layer = layer_word(L, -1);
			} else if (!strcmp(key, "animation"))
				animation_word(L, &words, lua_gettop(L), pending, screen != NULL);
			else if (strcmp(key, "parent")) word_set(L, &words, &hidden, &label, key, lua_gettop(L), pending, parent);
		} else count++;
		lua_pop(L, 1);
	}
	if (count != luaA_rawlen(L, 1)) return luaL_error(L, "ui.box: invalid child index");
	check_placement(L, &words, parent);
	content_check(L, &words, count != 0);
	if (parent->ui_box) content_check(L, &parent->words, true);
	for (size_t i = 1; i <= count; i++) {
		lua_rawgeti(L, 1, i);
		struct node *child = node_face_check(L, -1);
		if (!child->ui_box || child == parent) return luaL_error(L, "ui.box: invalid child");
		if (child->words.transition.enabled) return luaL_error(L,
			"ui.box animation.visible on a nested box requires the renderer in step 4");
		if (child->words.placed) return luaL_error(L,
			"ui.box %s: placed child cannot have a box parent",
			child->words.placed & 1 ? "x" : "y");
		if (child->words.edge) return luaL_error(L, "ui.box position under a box is reserved");
		if (child->words.attachment.set) return luaL_error(L, "ui.box attachment applies to a screen box");
		for (struct node *p = parent; p; p = p->parent)
			if (p == child) return luaL_error(L, "ui.box: child would create a cycle");
		for (size_t j = 1; j < i; j++) {
			lua_rawgeti(L, 1, j);
			if (lua_rawequal(L, -1, -2)) return luaL_error(L, "ui.box: duplicate child");
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
	}
	struct node *n;
	if (screen) {
		drawin_t *d = drawin_ui_create(L, screen);
		n = d->node;
		lua_pop(L, 1);
	} else {
		n = node_create(parent->tree, NODE_WIBOX);
		n->ui_box = true;
		n->owner_kind = DECLARE_KIND_UI_BOX;
		node_append(parent, n);
	}
	lua_getfield(L, pending, "animation");
	words.animation_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	words_own(L, &words, &(struct node_words){.image_ref = LUA_NOREF, .attachment_ref = LUA_NOREF}, pending);
	n->words = words;
	n->layer = screen ? layer : LAYER_INHERIT;
	n->hidden = hidden;
	if (label) node_set_label(n, label);
	for (size_t i = 1; i <= count; i++) {
		lua_rawgeti(L, 1, i);
		struct node *child = node_face_check(L, -1);
		ui_box_dirty(child);
		if (child->owner_kind == DECLARE_KIND_DRAWIN) {
			drawin_t *d = child->owner;
			free(d->cursor);
			d->cursor = NULL;
			drawin_ui_release(L, d);
			child->owner = NULL;
			child->owner_kind = DECLARE_KIND_UI_BOX;
		}
		node_append(n, child);
		lua_pop(L, 1);
	}
	ui_box_dirty(n);
	if (!screen) declare_mark_all_dirty();
	return node_face_push(L, n);
}

struct box_hit { uint32_t id; int x, y; };
static struct box_hit hovered[WIDGET_NODES_MAX];
static int hovered_len;
static uint32_t cursor_box;

static int
box_hits(drawin_t *d, int x, int y, struct box_hit *out)
{
	struct widget_host host;
	int hits[WIDGET_NODES_MAX];
	if (!d->node || d->input_passthrough || !drawin_widget_host(d, &host)) return 0;
	int count = declare_widget_hits(&host, x, y, hits, WIDGET_NODES_MAX), len = 0;
	for (int i = count - 1; i >= 0; i--) {
		int origin[2];
		uint32_t id = declare_widget_identity(&host, hits[i], origin);
		struct node *n = node_by_id(id);
		if (n && n->ui_box && !n->words.input_passthrough)
			out[len++] = (struct box_hit){id, x - origin[0], y - origin[1]};
	}
	return len;
}

static void
box_emit(lua_State *L, struct box_hit hit, const char *signal, uint32_t button, uint32_t mods)
{
	struct node *n = node_by_id(hit.id);
	if (!n || !n->ui_box || n->words.input_passthrough) return;
	struct node *host = n;
	while (host->parent && host->parent->ui_box) host = host->parent;
	if (host->words.input_passthrough) return;
	node_face_push(L, n);
	lua_pushinteger(L, hit.x);
	lua_pushinteger(L, hit.y);
	int nargs = 2;
	if (button) {
		lua_pushinteger(L, button);
		luaA_pushmodifiers(L, mods);
		nargs += 2;
	}
	luaA_object_emit_signal(L, -nargs - 1, signal, nargs);
	lua_pop(L, 1);
}

static bool
hit_contains(const struct box_hit *hits, int len, uint32_t id)
{
	for (int i = 0; i < len; i++) if (hits[i].id == id) return true;
	return false;
}

void
ui_box_pointer_leave(lua_State *L)
{
	struct box_hit previous[WIDGET_NODES_MAX];
	int count = hovered_len;
	memcpy(previous, hovered, count * sizeof(*previous));
	hovered_len = 0;
	cursor_box = 0;
	for (int i = 0; i < count; i++) box_emit(L, previous[i], "mouse::leave", 0, 0);
}

void
ui_box_pointer_move(lua_State *L, drawin_t *d, int x, int y)
{
	struct box_hit hits[WIDGET_NODES_MAX], previous[WIDGET_NODES_MAX];
	int count = box_hits(d, x, y, hits), old_count = hovered_len;
	memcpy(previous, hovered, old_count * sizeof(*previous));
	memcpy(hovered, hits, count * sizeof(*hits));
	hovered_len = count;
	for (int i = 0; i < old_count; i++)
		if (!hit_contains(hits, count, previous[i].id)) box_emit(L, previous[i], "mouse::leave", 0, 0);
	for (int i = 0; i < count; i++)
		if (!hit_contains(previous, old_count, hits[i].id)) box_emit(L, hits[i], "mouse::enter", 0, 0);
	for (int i = 0; i < count; i++) box_emit(L, hits[i], "mouse::move", 0, 0);
	cursor_box = 0;
	for (int i = 0; i < count; i++) {
		struct node *n = node_by_id(hits[i].id);
		if (n && n->words.cursor && !n->words.input_passthrough) {
			cursor_box = n->id;
			break;
		}
	}
}

const char *
ui_box_pointer_cursor(drawin_t *d)
{
	struct node *n = node_by_id(cursor_box), *host = n;
	while (host && host->parent && host->parent->ui_box) host = host->parent;
	return n && host == d->node && !n->words.input_passthrough && n->words.cursor
		? n->words.cursor : d->cursor;
}

void
ui_box_button(lua_State *L, drawin_t *d, int x, int y, uint32_t button, uint32_t mods, bool press)
{
	struct box_hit hits[WIDGET_NODES_MAX];
	int count = box_hits(d, x, y, hits);
	for (int i = 0; i < count; i++)
		box_emit(L, hits[i], press ? "button::press" : "button::release", button, mods);
}
