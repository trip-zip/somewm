#include "keybinding.h"
#include "key.h"
#include "screen.h"
#include "luaa.h"
#include "client.h"
#include "common/luaobject.h"
#include "signal.h"
#include "../somewm_api.h"
#include "../globalconf.h"
#include <xkbcommon/xkbcommon.h>

/* Lua state - stored globally for keypress callback */
static lua_State *global_L = NULL;

/** Check if keypress matches any key object (AwesomeWM pattern)
 * Iterates through globalconf.keys and emits "press" signal on matches
 *
 * \param mods Modifier mask
 * \param sym Keysym
 * \param base_sym Base keysym (without Shift/Lock)
 * \return 1 if handled, 0 if not
 */
int
luaA_key_check_and_emit(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym, bool is_keypress)
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
			luaA_awm_object_emit_signal(global_L, -1, is_keypress ? "press" : "release", 0);
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
luaA_client_key_check_and_emit(client_t *c, uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym, bool is_keypress)
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
			luaA_awm_object_emit_signal(global_L, -2, is_keypress ? "press" : "release", 1);
			/* Pop key object and client */
			lua_pop(global_L, 2);

			/* Return after emitting - no need for further processing */
			return 1;
		}
	}

	return 0;
}

/** Setup the keybinding module
 */
void
luaA_keybinding_setup(lua_State *L)
{
	global_L = L;
}
