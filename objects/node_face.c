#include "node_face.h"
#include "ui_box.h"
#include "../node.h"
#include "../ewmh.h"
#include "../declare.h"
#include "drawable.h"
#include "common/luaobject.h"

#include <stdio.h>
#include <string.h>

static lua_class_t node_class;
static const char faces_key;
static const char boxes_key;

typedef struct {
	LUA_OBJECT_HEADER
	uint32_t id;
} node_face_t;

LUA_CLASS_FUNCS(node, node_class)

struct node *
node_face_check(lua_State *L, int index)
{
	node_face_t *face = luaA_checkudata(L, index, &node_class);
	struct node *n = node_by_id(face->id);
	if (!n) {
		char message[64];
		snprintf(message, sizeof(message), "node %u no longer exists", (unsigned)face->id);
		luaL_error(L, "%s", message);
	}
	return n;
}

int
node_face_push(lua_State *L, struct node *n)
{
	if (!n || n->kind == NODE_OUTPUT) {
		lua_pushnil(L);
		return 1;
	}
	lua_pushlightuserdata(L, (void *)&faces_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	lua_pushnumber(L, n->id);
	lua_rawget(L, -2);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		node_face_t *face = lua_newuserdata(L, sizeof(*face));
		*face = (node_face_t){ .id = n->id };
		node_class.instances++;
		luaA_settype(L, &node_class);
		lua_newtable(L);
		lua_newtable(L);
		lua_setmetatable(L, -2);
		lua_newtable(L);
		lua_setfield(L, -2, "data");
		luaA_setuservalue(L, -2);
		lua_pushnumber(L, n->id);
		lua_pushvalue(L, -2);
		lua_rawset(L, -4);
		if (n->ui_box) {
			lua_pushlightuserdata(L, (void *)&boxes_key);
			lua_rawget(L, LUA_REGISTRYINDEX);
			lua_pushnumber(L, n->id);
			lua_pushvalue(L, -3);
			lua_rawset(L, -3);
			lua_pop(L, 1);
		}
	}
	lua_remove(L, -2);
	return 1;
}

int
node_owner_push(lua_State *L, struct node *n)
{
	return n->ui_box ? node_face_push(L, n) : luaA_object_push(L, n->owner);
}

void
node_face_forget(lua_State *L, struct node *n)
{
	lua_pushlightuserdata(L, (void *)&boxes_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (lua_istable(L, -1)) {
		lua_pushnumber(L, n->id);
		lua_pushnil(L);
		lua_rawset(L, -3);
	}
	lua_pop(L, 1);
}

int
node_face_children(lua_State *L, struct node *n)
{
	lua_newtable(L);
	if (n) {
		struct node *child;
		wl_list_for_each(child, &n->children, link) {
			node_face_push(L, child);
			lua_rawseti(L, -2, luaA_rawlen(L, -2) + 1);
		}
	}
	return 1;
}

static bool
face_protected(struct node *n)
{
	/* C can move screen roots between outputs as their hosting changes. */
	return n->protected || n->kind == NODE_SCREEN;
}

static int
face_property(lua_State *L, lua_object_t *unused)
{
	(void)unused;
	struct node *n = node_face_check(L, 1);
	const char *key = lua_tostring(L, 2);
	static const char *const kinds[] = {
		[NODE_SCREEN] = "screen", [NODE_CLIENT] = "client",
		[NODE_WIBOX] = "box", [NODE_SURFACE] = "surface",
		[NODE_BRANCH] = "branch",
	};
	/* Each band reads the highest public layer at or below it in declare.c's z table. */
	static const char *const layers[] = {
		[LAYER_INHERIT] = NULL,
		[LAYER_BACKGROUND] = "background",
		[LAYER_DESKTOP] = "background",
		[LAYER_WIBOX_DESKTOP] = "background",
		[LAYER_BOTTOM] = "bottom",
		[LAYER_BELOW] = "below",
		[LAYER_NORMAL] = "normal",
		[LAYER_WIBOX] = "normal",
		[LAYER_ABOVE] = "above",
		[LAYER_FULLSCREEN] = "fullscreen",
		[LAYER_ONTOP] = "ontop",
		[LAYER_BAR_ONTOP] = "ontop",
		[LAYER_TOP] = "top",
		[LAYER_WIBOX_ONTOP] = "top",
		[LAYER_NOTIFICATION] = "top",
		[LAYER_OVERLAY] = "overlay",
		[LAYER_UNMANAGED] = "overlay",
		[LAYER_CURSOR] = "overlay",
	};
	if (!strcmp(key, "id")) lua_pushnumber(L, n->id);
	else if (!strcmp(key, "kind")) lua_pushstring(L, kinds[n->kind]);
	else if (!strcmp(key, "layer")) lua_pushstring(L, layers[n->layer]);
	else if (!strcmp(key, "label")) lua_pushstring(L, n->label);
	else if (!strcmp(key, "protected")) lua_pushboolean(L, face_protected(n));
	else if (!strcmp(key, "parent")) return node_face_push(L, n->parent);
	else if (!strcmp(key, "children")) return node_face_children(L, n);
	else if (!strcmp(key, "root")) {
		while (n->parent && n->parent->kind != NODE_OUTPUT)
			n = n->parent;
		return node_face_push(L, n);
	} else if (!strcmp(key, "first_child") || !strcmp(key, "last_child")) {
		struct node *child = NULL;
		if (!wl_list_empty(&n->children)) {
			struct wl_list *link = !strcmp(key, "first_child")
				? n->children.next : n->children.prev;
			child = wl_container_of(link, child, link);
		}
		return node_face_push(L, child);
	} else if (!strcmp(key, "next_sibling") || !strcmp(key, "previous_sibling")) {
		struct node *sibling = NULL;
		struct wl_list *link = !strcmp(key, "next_sibling")
			? n->link.next : n->link.prev;
		if (n->parent && n->parent->kind != NODE_OUTPUT && link != &n->parent->children)
			sibling = wl_container_of(link, sibling, link);
		return node_face_push(L, sibling);
	} else if (!strcmp(key, "object")) {
		if (n->ui_box || n->kind == NODE_SURFACE || n->kind == NODE_BRANCH || !n->owner)
			lua_pushnil(L);
		else if (n->owner_kind == DECLARE_KIND_TITLEBAR)
			return drawable_push(L, n->owner);
		else
			return luaA_object_push(L, n->owner);
	}
	return 1;
}

static int
face_readonly(lua_State *L, lua_object_t *unused)
{
	(void)unused;
	struct node *n = node_face_check(L, 1);
	char name[32];
	snprintf(name, sizeof(name), "node %u", (unsigned)n->id);
	return luaL_error(L, "%s: %s is read-only", name, lua_tostring(L, 2));
}

static int
face_index(lua_State *L)
{
	struct node *n = node_face_check(L, 1);
	const char *key = lua_tostring(L, 2);
	if (n->ui_box && key && ui_box_get(L, n, key)) return 1;
	return luaA_class_index(L);
}

static int
face_newindex(lua_State *L)
{
	struct node *n = node_face_check(L, 1);
	const char *key = lua_tostring(L, 2);
	if (n->ui_box) {
		if (!key) return luaL_error(L, "ui.box: unknown word (non-string key)");
		return ui_box_set(L, n, key, 3);
	}
	return luaA_class_newindex(L);
}

static int
face_refuse(lua_State *L, struct node *a, struct node *b, const char *reason)
{
	char names[64];
	snprintf(names, sizeof(names), "node %u and node %u", (unsigned)a->id,
		(unsigned)(b ? b->id : a->id));
	return luaL_error(L, "%s: %s", names, reason);
}

static size_t
face_sibling_index(struct node *n)
{
	size_t index = 0;
	for (struct wl_list *link = n->link.prev; link != &n->parent->children; link = link->prev)
		index++;
	return index;
}

enum face_move { FACE_APPEND, FACE_PUSH, FACE_BEFORE, FACE_AFTER, FACE_SWAP };

static bool
node_reorderable(struct node *n)
{
	return n->kind == NODE_CLIENT || n->ui_box;
}

static int
face_move(lua_State *L, enum face_move move)
{
	struct node *a = node_face_check(L, 1), *b = node_face_check(L, 2);
	struct node *parent = move == FACE_APPEND || move == FACE_PUSH ? a : b->parent;
	struct node *child = move == FACE_APPEND || move == FACE_PUSH ? b : a;
	if (parent && parent->ui_box && (parent->words.text || parent->words.image))
		return luaL_error(L, "a box with %s cannot have children", parent->words.text ? "text" : "image");
	/* drawin_widget_host restores a drawin's screen parent on refresh.
	 * client_node_attach also owns the client parent. Lua only reorders. */
	if (child->parent != parent)
		return face_refuse(L, a, b, "changing parents is not in 2.2");
	if (!parent || parent->kind == NODE_OUTPUT)
		return face_refuse(L, a, b, "protected root");
	if (!node_reorderable(child)
		|| (move == FACE_SWAP && (!node_reorderable(b) || child->kind != b->kind)))
		return face_refuse(L, a, b, "reordering a box is not in 2.2");
	if (a == b)
		return face_refuse(L, a, b, "cannot move a node relative to itself");
	struct node *nodes[] = { child, b };
	size_t count = move == FACE_SWAP ? 2 : 1;
	size_t before[2];
	uint32_t ids[2];
	const char *signals[2];
	for (size_t i = 0; i < count; i++) {
		before[i] = face_sibling_index(nodes[i]);
		ids[i] = nodes[i]->id;
	}
	bool moved = move == FACE_APPEND ? node_append(a, b)
		: move == FACE_PUSH ? node_push(a, b)
		: move == FACE_BEFORE ? node_insert_before(b, a)
		: move == FACE_AFTER ? node_insert_after(b, a) : node_swap(a, b);
	if (!moved)
		return face_refuse(L, a, b, "tree refused the reorder");
	if (child->ui_box) ui_box_dirty(child);
	if (parent->kind == NODE_SCREEN) {
		declare_mark_all_dirty();
		ewmh_stacking_changed();
	}
	/* Snapshot both directions before callbacks can reorder or destroy nodes. */
	for (size_t i = 0; i < count; i++) {
		size_t after = face_sibling_index(nodes[i]);
		signals[i] = after > before[i] ? "raised" : after < before[i] ? "lowered" : NULL;
	}
	for (size_t i = 0; i < count; i++) {
		struct node *n = node_by_id(ids[i]);
		if (!signals[i] || !n)
			continue;
		node_owner_push(L, n);
		luaA_object_emit_signal(L, -1, signals[i], 0);
		lua_pop(L, 1);
	}
	return 0;
}

static int face_append(lua_State *L) { return face_move(L, FACE_APPEND); }
static int face_push(lua_State *L) { return face_move(L, FACE_PUSH); }
static int face_before(lua_State *L) { return face_move(L, FACE_BEFORE); }
static int face_after(lua_State *L) { return face_move(L, FACE_AFTER); }
static int face_swap(lua_State *L) { return face_move(L, FACE_SWAP); }

static int
face_detach(lua_State *L)
{
	struct node *n = node_face_check(L, 1);
	if (n->ui_box) { ui_box_detach(L, n); return 0; }
	return face_refuse(L, n, n->parent && n->parent->kind != NODE_OUTPUT ? n->parent : n,
		face_protected(n) ? "protected root: detach is not in 2.2" : "detach is not in 2.2");
}

void
node_face_class_setup(lua_State *L)
{
	static const struct luaL_Reg methods[] = {
		LUA_CLASS_METHODS(node)
		{ "_box", ui_box_new },
		{ NULL, NULL }
	};
	static const struct luaL_Reg meta[] = {
		LUA_OBJECT_META(node)
		LUA_CLASS_META
		{ "__index", face_index },
		{ "__newindex", face_newindex },
		{ "append", face_append }, { "push", face_push },
		{ "move_before", face_before }, { "move_after", face_after },
		{ "swap", face_swap }, { "detach", face_detach },
		{ NULL, NULL }
	};
	luaA_class_setup(L, &node_class, "node", NULL, NULL, NULL, NULL,
		NULL, face_readonly, methods, meta);
	static const char *const properties[] = {
		"id", "kind", "layer", "label", "protected", "parent", "first_child",
		"last_child", "next_sibling", "previous_sibling", "root", "children", "object",
	};
	for (size_t i = 0; i < countof(properties); i++)
		luaA_class_add_property(&node_class, properties[i], NULL, face_property, face_readonly);
	lua_pushlightuserdata(L, (void *)&boxes_key);
	lua_newtable(L);
	lua_rawset(L, LUA_REGISTRYINDEX);
	/* Reuse faces while Lua holds them without retaining unused userdata. */
	lua_pushlightuserdata(L, (void *)&faces_key);
	lua_newtable(L);
	lua_newtable(L);
	lua_pushliteral(L, "v");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}
