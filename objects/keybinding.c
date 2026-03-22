#include "keybinding.h"
#include "key.h"
#include "screen.h"
#include "luaa.h"
#include "client.h"
#include "common/luaobject.h"
#include "signal.h"
#include "../somewm_api.h"
#include "../globalconf.h"
#include <stdlib.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

/* Storage for Lua keybindings */
typedef struct {
	uint32_t modifiers;
	xkb_keysym_t keysym;
	int lua_func_ref;  /* Reference to Lua function in registry */
	char *description;
	char *group;
} LuaKeybinding;

static LuaKeybinding *lua_keybindings = NULL;
static size_t lua_keybindings_count = 0;
static size_t lua_keybindings_capacity = 0;

/* Lua state - stored globally for keypress callback */
static lua_State *global_L = NULL;

/* Modifier name to bitmask mapping */
typedef struct {
	const char *name;
	uint32_t mask;
} ModifierMap;

static const ModifierMap modifier_map[] = {
	{ "Shift",   WLR_MODIFIER_SHIFT },
	{ "Control", WLR_MODIFIER_CTRL },
	{ "Ctrl",    WLR_MODIFIER_CTRL },
	{ "Mod1",    WLR_MODIFIER_ALT },
	{ "Alt",     WLR_MODIFIER_ALT },
	{ "Mod4",    WLR_MODIFIER_LOGO },
	{ "Super",   WLR_MODIFIER_LOGO },
	{ "Mod5",    WLR_MODIFIER_MOD5 },
	{ NULL, 0 }
};

/** Parse modifier string to bitmask
 */
static uint32_t
parse_modifier(const char *mod)
{
	for (const ModifierMap *m = modifier_map; m->name; m++) {
		if (strcmp(mod, m->name) == 0)
			return m->mask;
	}
	return 0;
}

/** Convert modifier bitmask to table of modifier names
 */
static void
push_modifier_table(lua_State *L, uint32_t modifiers)
{
	int idx = 1;
	lua_newtable(L);
	for (const ModifierMap *m = modifier_map; m->name; m++) {
		if (modifiers & m->mask) {
			/* Use canonical names (first in list for each mask) */
			if ((m->mask == WLR_MODIFIER_CTRL && strcmp(m->name, "Control") == 0) ||
			    (m->mask == WLR_MODIFIER_ALT && strcmp(m->name, "Mod1") == 0) ||
			    (m->mask == WLR_MODIFIER_LOGO && strcmp(m->name, "Mod4") == 0) ||
			    (m->mask == WLR_MODIFIER_SHIFT) ||
			    (m->mask == WLR_MODIFIER_MOD5)) {
				lua_pushstring(L, m->name);
				lua_rawseti(L, -2, idx++);
			}
		}
	}
}

/** key.get_all()
 * Get all registered keybindings
 *
 * \return Table of keybindings with structure:
 *   { { modifiers={...}, key="j", description="...", group="..." }, ... }
 */
static int
luaA_key_get_all(lua_State *L)
{
	char keysym_name[64];

	lua_newtable(L);  /* Main result table */

	for (size_t i = 0; i < lua_keybindings_count; i++) {
		LuaKeybinding *kb = &lua_keybindings[i];

		lua_newtable(L);  /* Individual keybinding table */

		/* modifiers field */
		push_modifier_table(L, kb->modifiers);
		lua_setfield(L, -2, "modifiers");

		/* key field */
		xkb_keysym_get_name(kb->keysym, keysym_name, sizeof(keysym_name));
		lua_pushstring(L, keysym_name);
		lua_setfield(L, -2, "key");

		/* description field */
		if (kb->description) {
			lua_pushstring(L, kb->description);
			lua_setfield(L, -2, "description");
		}

		/* group field */
		if (kb->group) {
			lua_pushstring(L, kb->group);
			lua_setfield(L, -2, "group");
		}

		/* Add to result table (1-indexed) */
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

/** Convert X11 keycode to keysym
 * X11 keycodes use # prefix (e.g. "#10" for the 1 key)
 * X11 keycode = Linux keycode + 8
 */
static xkb_keysym_t
keycode_to_keysym(int keycode)
{
	/* Numrow keys: #10-19 map to 1-0 */
	static const xkb_keysym_t numrow_syms[] = {
		XKB_KEY_1, XKB_KEY_2, XKB_KEY_3, XKB_KEY_4, XKB_KEY_5,
		XKB_KEY_6, XKB_KEY_7, XKB_KEY_8, XKB_KEY_9, XKB_KEY_0
	};

	/* Numpad keys: common X11 keycodes */
	static const struct {
		int keycode;
		xkb_keysym_t keysym;
	} numpad_map[] = {
		{ 87, XKB_KEY_KP_1 }, { 88, XKB_KEY_KP_2 }, { 89, XKB_KEY_KP_3 },
		{ 83, XKB_KEY_KP_4 }, { 84, XKB_KEY_KP_5 }, { 85, XKB_KEY_KP_6 },
		{ 79, XKB_KEY_KP_7 }, { 80, XKB_KEY_KP_8 }, { 81, XKB_KEY_KP_9 },
		{ 90, XKB_KEY_KP_0 },
		{ 0, XKB_KEY_NoSymbol }
	};

	/* Check numrow range */
	if (keycode >= 10 && keycode <= 19) {
		return numrow_syms[keycode - 10];
	}

	/* Check numpad */
	for (int i = 0; numpad_map[i].keycode != 0; i++) {
		if (numpad_map[i].keycode == keycode) {
			return numpad_map[i].keysym;
		}
	}

	return XKB_KEY_NoSymbol;
}

/** key.bind(modifiers, key, callback, description, group)
 * Register a Lua keybinding
 *
 * \param modifiers Table of modifier strings {"Mod4", "Shift"}
 * \param key Key string (e.g. "j", "Return", "XF86AudioRaiseVolume")
 *   or X11 keycode (e.g. "#10" for the 1 key)
 * \param callback Lua function to call
 * \param description Optional description
 * \param group Optional group name
 */
static int
luaA_keybind(lua_State *L)
{
	uint32_t modifiers = 0;
	xkb_keysym_t keysym;
	int func_ref;
	const char *description = NULL;
	const char *group = NULL;
	const char *key_str;
	LuaKeybinding *kb;

	/* Parse modifiers table */
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_pushnil(L);
	while (lua_next(L, 1)) {
		if (lua_type(L, -1) == LUA_TSTRING) {
			const char *mod = lua_tostring(L, -1);
			modifiers |= parse_modifier(mod);
		}
		lua_pop(L, 1);
	}

	/* Parse key */
	key_str = luaL_checkstring(L, 2);

	/* Check for X11 keycode syntax (#num) */
	if (key_str[0] == '#') {
		int keycode = atoi(key_str + 1);
		keysym = keycode_to_keysym(keycode);
		if (keysym == XKB_KEY_NoSymbol) {
			fprintf(stderr, "WARNING: Invalid key code '%s', skipping keybinding\n", key_str);
			return 0;
		}
	} else {
		/* Normal keysym name */
		keysym = xkb_keysym_from_name(key_str, XKB_KEYSYM_CASE_INSENSITIVE);
		if (keysym == XKB_KEY_NoSymbol) {
			fprintf(stderr, "WARNING: Invalid key '%s', skipping keybinding\n", key_str);
			return 0;  /* Skip this keybinding instead of erroring */
		}
	}

	/* Get function reference */
	luaL_checktype(L, 3, LUA_TFUNCTION);
	lua_pushvalue(L, 3);  /* Copy function to top */
	func_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Optional description and group */
	if (lua_isstring(L, 4))
		description = lua_tostring(L, 4);
	if (lua_isstring(L, 5))
		group = lua_tostring(L, 5);

	/* Expand storage if needed */
	if (lua_keybindings_count >= lua_keybindings_capacity) {
		lua_keybindings_capacity = lua_keybindings_capacity == 0 ? 16 : lua_keybindings_capacity * 2;
		lua_keybindings = realloc(lua_keybindings,
			lua_keybindings_capacity * sizeof(LuaKeybinding));
	}

	/* Store keybinding */
	kb = &lua_keybindings[lua_keybindings_count++];
	kb->modifiers = modifiers;
	kb->keysym = keysym;
	kb->lua_func_ref = func_ref;
	kb->description = description ? strdup(description) : NULL;
	kb->group = group ? strdup(group) : NULL;

	return 0;
}

/** Check if keypress matches any key object (AwesomeWM pattern)
 * Iterates through globalconf.keys and emits "press" signal on matches
 *
 * \param mods Modifier mask
 * \param sym Keysym
 * \param base_sym Base keysym (without Shift/Lock)
 * \return 1 if handled, 0 if not
 */
int
luaA_key_check_and_emit(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym)
{
	xkb_keysym_t lower_base = xkb_keysym_to_lower(base_sym);
	int i;

	if (!global_L)
		return 0;

	/* Iterate through key objects in globalconf.keys */
	for (i = 0; i < globalconf.keys.len; i++) {
		keyb_t *key = globalconf.keys.tab[i];
		int keycode_match = 0;
		int keysym_match = 0;

		/* Match modifiers and (keycode OR keysym) - AwesomeWM pattern */
		if (key->modifiers == mods) {
			/* Check keycode match (if key has a keycode) */
			if (key->keycode && key->keycode == keycode) {
				keycode_match = 1;
			}
			/* Check keysym match (if key has a keysym) */
			if (key->keysym && key->keysym == lower_base) {
				keysym_match = 1;
			}
		}

		/* AwesomeWM pattern: match if mods match AND (keycode matches OR keysym matches) */
		if (key->modifiers == mods && (keycode_match || keysym_match)) {
			/* Push key object onto stack and emit signal using AwesomeWM's proper function */
			luaA_object_push(global_L, key);
			luaA_awm_object_emit_signal(global_L, -1, "press", 0);
			lua_pop(global_L, 1);

			/* Return after emitting - no need for further processing */
			return 1;
		}
	}

	return 0;
}

/** Check if client-specific key matches and emit signal
 * AwesomeWM pattern: client keybindings receive the client as argument
 *
 * \param c The client to check keys for
 * \param mods Modifier mask
 * \param keycode Keycode
 * \param sym Keysym
 * \param base_sym Base keysym (without Shift/Lock)
 * \return 1 if handled, 0 if not
 */
int
luaA_client_key_check_and_emit(client_t *c, uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym)
{
	xkb_keysym_t lower_base = xkb_keysym_to_lower(base_sym);
	int i;

	if (!global_L || !c)
		return 0;

	/* Iterate through key objects in client's keys array */
	for (i = 0; i < c->keys.len; i++) {
		keyb_t *key = (keyb_t *)c->keys.tab[i];
		int keycode_match = 0;
		int keysym_match = 0;

		if (!key)
			continue;

		/* Match modifiers and (keycode OR keysym) - AwesomeWM pattern */
		if (key->modifiers == mods) {
			/* Check keycode match (if key has a keycode) */
			if (key->keycode && key->keycode == keycode) {
				keycode_match = 1;
			}
			/* Check keysym match (if key has a keysym) */
			if (key->keysym && key->keysym == lower_base) {
				keysym_match = 1;
			}
		}

		/* AwesomeWM pattern: match if mods match AND (keycode matches OR keysym matches) */
		if (key->modifiers == mods && (keycode_match || keysym_match)) {
			/* Push client onto stack (owner of the key objects) */
			luaA_object_push(global_L, c);
			/* Push key object using push_item since it was stored with ref_item */
			luaA_object_push_item(global_L, -1, key);
			/* Emit signal with client as argument (1 arg) - client is at -2, key at -1 */
			lua_pushvalue(global_L, -2);  /* Copy client to top for signal arg */
			luaA_awm_object_emit_signal(global_L, -2, "press", 1);
			/* Pop key object and client */
			lua_pop(global_L, 2);

			/* Return after emitting - no need for further processing */
			return 1;
		}
	}

	return 0;
}

/** Check if a Lua keybinding matches and execute it (OLD SYSTEM - DEPRECATED)
 * Called from C keypress handler
 *
 * THIS FUNCTION IS DEPRECATED. Use luaA_key_check_and_emit() instead.
 * This old system stores callbacks directly instead of using key objects
 * with signals. It will be removed once the new system is fully tested.
 *
 * \param mods Current modifier mask
 * \param sym Current keysym (with modifiers applied)
 * \param base_sym Base keysym (ignoring Shift/Lock modifiers)
 * \return 1 if handled, 0 if not
 */
int
luaA_keybind_check(uint32_t mods, xkb_keysym_t sym, xkb_keysym_t base_sym)
{
	size_t i;
	xkb_keysym_t lower_base = xkb_keysym_to_lower(base_sym);

	if (!global_L)
		return 0;

	for (i = 0; i < lua_keybindings_count; i++) {
		LuaKeybinding *kb = &lua_keybindings[i];
		int ret;

		if (kb->modifiers == mods && kb->keysym == lower_base) {
			/* Call Lua function */
			lua_rawgeti(global_L, LUA_REGISTRYINDEX, kb->lua_func_ref);
			ret = lua_pcall(global_L, 0, 0, 0);
			if (ret != 0) {
				fprintf(stderr, "Error in keybinding callback: %s\n",
					lua_tostring(global_L, -1));
				lua_pop(global_L, 1);
			}
			return 1;
		}
	}

	return 0;
}

/* Keybinding module methods */
const luaL_Reg keybinding_methods[] = {
	{ "bind", luaA_keybind },
	{ "get_all", luaA_key_get_all },
	{ NULL, NULL }
};

/** Setup the keybinding Lua module
 */
void
luaA_keybinding_setup(lua_State *L)
{
	global_L = L;
	luaA_openlib(L, "_key", keybinding_methods, NULL);
}

/** Cleanup keybindings on exit
 */
void
luaA_keybinding_cleanup(void)
{
	for (size_t i = 0; i < lua_keybindings_count; i++) {
		if (global_L && lua_keybindings[i].lua_func_ref != LUA_NOREF) {
			luaL_unref(global_L, LUA_REGISTRYINDEX, lua_keybindings[i].lua_func_ref);
		}
		free(lua_keybindings[i].description);
		free(lua_keybindings[i].group);
	}
	free(lua_keybindings);
	lua_keybindings = NULL;
	lua_keybindings_count = 0;
	lua_keybindings_capacity = 0;
}
