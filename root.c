/* root.c - AwesomeWM-compatible root (global) API
 *
 * In AwesomeWM on X11, "root" refers to the root window which owns global
 * keybindings and mouse bindings. In Wayland, there is no root window concept,
 * but we emulate the API for compatibility by managing global input bindings.
 *
 * This module wraps the existing keybinding.c infrastructure with an
 * AwesomeWM-compatible API.
 */

#include "objects/root.h"
#include "luaa.h"
#include "objects/signal.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "objects/keybinding.h"
#include "objects/key.h"
#include "objects/button.h"
#include "somewm_api.h"
#include "globalconf.h"
#include "objects/drawable.h"
#include "objects/drawin.h"
#include "objects/client.h"
#include "somewm_types.h"
#include <xkbcommon/xkbcommon.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_output_layout.h>
#include <linux/input-event-codes.h>
#include <time.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/render/pass.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/allocator.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <cairo.h>
#include <drm_fourcc.h>
#include <string.h>

/* External references to somewm.c globals */
extern struct wlr_output_layout *output_layout;
extern struct wlr_scene_tree *layers[];
extern struct wlr_scene *scene;
extern struct wlr_renderer *drw;
extern struct wlr_allocator *alloc;
extern struct wl_list mons;
extern struct wlr_cursor *cursor;
extern struct wlr_xcursor_manager *cursor_mgr;
extern struct wlr_seat *seat;
extern char* selected_root_cursor;

/* External function to find surface at coordinates (from somewm.c) */
extern void xytonode(double x, double y, struct wlr_surface **psurface,
	Client **pc, LayerSurface **pl, drawin_t **pd, drawable_t **pdrawable,
	double *nx, double *ny);

/* Property miss handlers (AwesomeWM compatibility) */
static int miss_index_handler = LUA_REFNIL;
static int miss_newindex_handler = LUA_REFNIL;
static int miss_call_handler = LUA_REFNIL;

/** Convert string to X11 keycode (X11-only stub).
 * \param s The key name string.
 * \return The keycode (always 0 in Wayland).
 */
static xcb_keycode_t __attribute__((unused))
_string_to_key_code(const char *s)
{
    /* X11-only: Uses XStringToKeysym and xcb_key_symbols_get_keycode.
     * Wayland uses xkb_keymap_key_by_name or keysym_to_keycode. */
    (void)s;
    return 0;
}

/** Update wallpaper from X11 root window (X11-only stub).
 * X11: Reads _XROOTPMAP_ID property from root window.
 * Wayland: Wallpaper is set via root.wallpaper() Lua API with automatic caching.
 */
void
root_update_wallpaper(void)
{
    /* X11-only: Reads _XROOTPMAP_ID pixmap property.
     * Wayland wallpaper is set via root.wallpaper() Lua API. */
}

#if 0 /* REMOVED: These functions don't exist in AwesomeWM - they caused infinite recursion
       * The Lua layer (awful/root.lua) creates _append_* and _remove_* wrappers itself.
       * Only _keys and _buttons (getters/setters) should exist in C. */

/** root._append_key(key) - DEPRECATED HACK
 *
 * THIS FUNCTION IS DEPRECATED. It was a hack to extract callbacks from
 * key objects and call the old _key.bind() system. Now that we have proper
 * AwesomeWM-compatible key objects with signals, this is no longer needed.
 *
 * awful.keyboard should create key objects and pass them to root._keys()
 * which stores them in globalconf.keys. Then somewm.c:keypress() emits
 * signals on matching key objects.
 *
 * This function is kept temporarily for backwards compatibility but will
 * be removed once the new system is fully tested.
 */
static int
luaA_root_append_key(lua_State *L)
{
	(void)L;
	/* Deprecated - use awful.keyboard.append_global_keybindings() instead */
	return 0;
}

/** root._append_keys(keys) - Append keys to global keybindings
 *
 * This is what awful.keyboard uses to add keybindings.
 * Unlike root._keys(), this APPENDS instead of replacing.
 *
 * \param keys Array of key objects (or nested tables containing key objects)
 */
static int
luaA_root_append_keys(lua_State *L)
{
	int i, j;
	size_t len;
	keyb_t *key;

	if (!lua_istable(L, 1))
		return 0;

	len = luaA_rawlen(L, 1);

	/* Iterate using integer indices - more reliable than lua_next for arrays */
	for (i = 1; i <= (int)len && i <= 100; i++) {
		lua_rawgeti(L, 1, i);  /* Get table[i] */

		/* Check if this is a C key object directly */
		key = luaA_toudata(L, -1, &key_class);
		if (key) {
			/* luaA_object_ref REMOVES the object from stack, so no lua_pop needed */
			key_array_append(&globalconf.keys, luaA_object_ref(L, -1));
			continue;  /* Skip the lua_pop(L, 1) at the end since object already removed */
		}
		/* Or check if it's a table containing key objects */
		else if (lua_istable(L, -1)) {
			/* Iterate table with integer indices */
			for (j = 1; j <= 100; j++) {
				lua_rawgeti(L, -1, j);
				if (lua_isnil(L, -1)) {
					lua_pop(L, 1);
					break;
				}

				key = luaA_toudata(L, -1, &key_class);
				if (key) {
					/* luaA_object_ref REMOVES the object from stack */
					key_array_append(&globalconf.keys, luaA_object_ref(L, -1));
				} else {
					lua_pop(L, 1);
				}
			}
		}
		lua_pop(L, 1);  /* Pop table[i] */
	}
	(void)i;  /* Suppress unused warning */
	return 0;
}

/** root._remove_key(key) - Remove a global keybinding
 *
 * Note: Current keybinding.c doesn't support removal, so this is a no-op
 * TODO: Implement keybinding removal in keybinding.c
 *
 * \param key Key object to remove
 */
static int
luaA_root_remove_key(lua_State *L)
{
	/* TODO: Implement keybinding removal
	 * For now, this is a no-op for compatibility */
	(void)L;
	fprintf(stderr, "WARNING: root._remove_key not yet implemented\n");
	return 0;
}

#endif /* End of first block of removed functions */

/** root._keys([new_keys]) - Get or set global keybindings (INTERNAL)
 * This is the C implementation that actually stores key objects.
 * AwesomeWM-compatible: stores key objects in globalconf.keys array.
 *
 * \param new_keys Optional array of key objects to set as global keybindings
 * \return Current global keybindings (if getting)
 */
static int
luaA_root_keys(lua_State *L)
{
	if (lua_gettop(L) >= 1 && lua_istable(L, 1)) {
		int i;
		int idx;

		/* Unref all existing key objects */
		for (i = 0; i < globalconf.keys.len; i++)
			luaA_object_unref(L, globalconf.keys.tab[i]);

		/* Clear the array */
		key_array_wipe(&globalconf.keys);
		key_array_init(&globalconf.keys);

		/* Add new key objects from the table
		 * Use lua_next() iteration like AwesomeWM to handle all table types correctly */
		lua_pushnil(L);  /* First key for lua_next */
		while (lua_next(L, 1)) {
			/* Stack now: [table, key, value] */
			/* key is at index -2, value is at index -1 */

			/* Check if this is a C key object */
			if (luaA_toudata(L, -1, &key_class)) {
				/* luaA_object_ref REMOVES the object from stack.
				 * After this, stack will be [table, key] which is perfect for lua_next */
				key_array_append(&globalconf.keys, luaA_object_ref(L, -1));
				/* Object already removed by luaA_object_ref, stack is [table, key] - ready for next iteration */
			} else if (lua_type(L, -1) == LUA_TTABLE) {
				/* Might be an awful.key wrapper table - check for C objects at integer indices */
				for (idx = 1; idx <= 100; idx++) {
					lua_rawgeti(L, -1, idx);  /* Get table[idx] */
					if (lua_isnil(L, -1)) {
						lua_pop(L, 1);
						break;
					}

					if (luaA_toudata(L, -1, &key_class)) {
						/* Ref and append this C object */
						key_array_append(&globalconf.keys, luaA_object_ref(L, -1));
						/* Object removed by ref, continue */
					} else {
						lua_pop(L, 1);  /* Not a C object, pop it */
					}
				}

				/* Pop the awful.key wrapper table, leave key for lua_next */
				lua_pop(L, 1);
			} else {
				/* Not a key object - pop the value, leave key for lua_next */
				lua_pop(L, 1);
				/* Stack is now [table, key] - ready for next iteration */
			}
			/* lua_next will pop the key and push the next key-value pair */
		}
		/* lua_next returns 0 when done and has already popped the last key */

		/* Also update root._private.keys for awful.root compatibility */
		lua_getglobal(L, "root");              /* Push root */
		lua_getfield(L, -1, "_private");       /* Push root._private */
		if (!lua_istable(L, -1)) {
			/* _private doesn't exist yet, create it */
			lua_pop(L, 1);                     /* Pop nil */
			lua_newtable(L);                   /* Create new table */
			lua_pushvalue(L, -1);              /* Dup table for setfield */
			lua_setfield(L, -3, "_private");   /* root._private = {} */
		}
		/* Now root._private is on stack */
		lua_pushvalue(L, 1);                   /* Copy the keys table */
		lua_setfield(L, -2, "keys");           /* _private.keys = keys */
		lua_pop(L, 2);                         /* Pop _private and root */

		return 1;
	}

	/* Get keybindings - return array of key objects */
	lua_createtable(L, globalconf.keys.len, 0);
	for (int i = 0; i < globalconf.keys.len; i++) {
		luaA_object_push(L, globalconf.keys.tab[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

#if 0 /* Second block of removed functions (_append_button and _append_buttons) */

/** root._append_button(button) - Append a global button binding
 *
 * This is called by awful.mouse to register global mouse button bindings.
 * Forwards to _button.bind() for consistency with keybindings.
 *
 * \param button Button object (table with modifiers, button, callback, etc.)
 */
static int
luaA_root_append_button(lua_State *L)
{
	const char *description;
	const char *group;

	/* Button object should be a table with:
	 * - modifiers: table of modifier strings
	 * - button: button number or string
	 * - on_press: callback function (optional)
	 * - description: string (optional)
	 * - group: string (optional)
	 */
	luaL_checktype(L, 1, LUA_TTABLE);

	/* Get modifiers table */
	lua_getfield(L, 1, "modifiers");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);  /* Empty modifiers if not provided */
	}

	/* Get button number/string */
	lua_getfield(L, 1, "button");
	if (!lua_isstring(L, -1) && !lua_isnumber(L, -1)) {
		return luaL_error(L, "Button object missing 'button' field");
	}

	/* Get callback - try on_press first, fallback to direct function */
	lua_getfield(L, 1, "on_press");
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 1);
		/* Try direct function at index 1 */
		lua_getfield(L, 1, "func");
		if (!lua_isfunction(L, -1)) {
			lua_pop(L, 1);
			/* Maybe the table IS the function? Check metatable */
			if (lua_getmetatable(L, 1)) {
				lua_getfield(L, -1, "__call");
				if (lua_isfunction(L, -1)) {
					lua_remove(L, -2);  /* Remove metatable */
				} else {
					lua_pop(L, 2);  /* Pop __call and metatable */
					return luaL_error(L, "Button object missing callback function");
				}
			} else {
				return luaL_error(L, "Button object missing callback function");
			}
		}
	}

	/* Optional description and group */
	lua_getfield(L, 1, "description");
	description = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;

	lua_getfield(L, 1, "group");
	group = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;

	/* Now stack is: modifiers, button, callback, description, group */
	/* Call _button.bind(modifiers, button, callback, description, group) */
	lua_getglobal(L, "_button");
	lua_getfield(L, -1, "bind");
	lua_pushvalue(L, -7);  /* modifiers */
	lua_pushvalue(L, -7);  /* button */
	lua_pushvalue(L, -7);  /* callback */
	if (description) {
		lua_pushstring(L, description);
	} else {
		lua_pushnil(L);
	}
	if (group) {
		lua_pushstring(L, group);
	} else {
		lua_pushnil(L);
	}

	/* Call _button.bind() */
	lua_call(L, 5, 0);

	return 0;
}

/** root._append_buttons(buttons) - Append multiple global button bindings
 *
 * \param buttons Array of button objects
 */
static int
luaA_root_append_buttons(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);

	/* Iterate over array */
	lua_pushnil(L);
	while (lua_next(L, 1)) {
		if (lua_istable(L, -1)) {
			/* Call _append_button for each element */
			lua_getglobal(L, "root");
			lua_getfield(L, -1, "_append_button");
			lua_pushvalue(L, -3);  /* Copy the button table */
			lua_call(L, 1, 0);
			lua_pop(L, 1);  /* Pop root table */
		}
		lua_pop(L, 1);  /* Pop value, keep key for next iteration */
	}

	return 0;
}

#endif /* End of second block of removed functions */

/** root.buttons([new_buttons]) - Get or set global button bindings
 *
 * Ported directly from AwesomeWM for API compatibility.
 * This is a simple getter/setter for the global button bindings array.
 *
 * \param new_buttons Optional array of button objects to set as global bindings
 * \return Current global button bindings (if getting)
 */
static int
luaA_root_buttons(lua_State *L)
{
	button_array_t *buttons = (button_array_t *)&globalconf.buttons;

	if (lua_gettop(L) == 1) {
		/* Setter: replace all button bindings */
		luaL_checktype(L, 1, LUA_TTABLE);

		/* Unref all existing buttons */
		for (int i = 0; i < buttons->len; i++)
			luaA_object_unref(L, buttons->tab[i]);

		/* Clear the array */
		button_array_wipe(buttons);
		button_array_init(buttons);

		/* Add new buttons from the table */
		lua_pushnil(L);
		while (lua_next(L, 1))
			button_array_append(buttons, luaA_object_ref(L, -1));

		/* Also update root._private.buttons for awful.root compatibility */
		lua_getglobal(L, "root");              /* Push root */
		lua_getfield(L, -1, "_private");       /* Push root._private */
		if (!lua_istable(L, -1)) {
			/* _private doesn't exist yet, create it */
			lua_pop(L, 1);                     /* Pop nil */
			lua_newtable(L);                   /* Create new table */
			lua_pushvalue(L, -1);              /* Dup table for setfield */
			lua_setfield(L, -3, "_private");   /* root._private = {} */
		}
		/* Now root._private is on stack */
		lua_pushvalue(L, 1);                   /* Copy the buttons table */
		lua_setfield(L, -2, "buttons");        /* _private.buttons = buttons */
		lua_pop(L, 2);                          /* Pop _private and root */

		return 1;
	}

	/* Getter: return array of button objects */
	lua_createtable(L, buttons->len, 0);
	for (int i = 0; i < buttons->len; i++) {
		luaA_object_push(L, buttons->tab[i]);
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

/** Check root button bindings and emit signals (C export)
 * This function is called from somewm.c when a button is pressed on the root window
 * (empty desktop space) to check if any global button bindings match.
 *
 * \param L Lua state
 * \param button Button code
 * \param mods Modifier mask
 * \param x Global X coordinate
 * \param y Global Y coordinate
 * \param is_press true for press, false for release
 * \return Number of matching buttons found
 */
int
luaA_root_button_check(lua_State *L, uint32_t button, uint32_t mods,
                       double x, double y, bool is_press)
{
	button_array_t *buttons = (button_array_t *)&globalconf.buttons;
	const char *signal_name = is_press ? "press" : "release";
	int matched = 0;
	uint32_t translated_button;

	(void)x;
	(void)y;

	/* Translate Linux input code to X11-style button number */
	translated_button = translate_button_code(button);

	/* Iterate through root button array */
	for (int i = 0; i < buttons->len; i++) {
		button_t *btn = buttons->tab[i];

		/* Match button number (0 = any button) - use translated code */
		bool button_matches = (btn->button == 0 || btn->button == translated_button);

		/* Match modifiers (0 = any modifiers) */
		bool mods_match = (btn->modifiers == 0 || btn->modifiers == mods);

		if (button_matches && mods_match) {
			/* Push button object */
			luaA_object_push(L, btn);

			/* Emit press/release signal on button object (no args) */
			luaA_awm_object_emit_signal(L, -1, signal_name, 0);

			/* Pop button object */
			lua_pop(L, 1);

			matched++;
		}
	}

	return matched;
}

/** Get current time in milliseconds for input events */
static uint32_t
get_current_time_msec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/** Convert keysym to keycode using current keymap
 * \param keymap XKB keymap to search
 * \param keysym Keysym to find
 * \return Keycode, or 0 if not found
 */
static xkb_keycode_t
keysym_to_keycode(struct xkb_keymap *keymap, xkb_keysym_t keysym)
{
	xkb_keycode_t min_kc = xkb_keymap_min_keycode(keymap);
	xkb_keycode_t max_kc = xkb_keymap_max_keycode(keymap);

	for (xkb_keycode_t kc = min_kc; kc <= max_kc; kc++) {
		xkb_layout_index_t num_layouts = xkb_keymap_num_layouts_for_key(keymap, kc);
		for (xkb_layout_index_t layout = 0; layout < num_layouts; layout++) {
			xkb_level_index_t num_levels = xkb_keymap_num_levels_for_key(keymap, kc, layout);
			for (xkb_level_index_t level = 0; level < num_levels; level++) {
				const xkb_keysym_t *syms;
				int nsyms = xkb_keymap_key_get_syms_by_level(keymap, kc, layout, level, &syms);
				for (int i = 0; i < nsyms; i++) {
					if (syms[i] == keysym)
						return kc;
				}
			}
		}
	}
	return 0;
}

/** Convert button number to Linux input event code
 * \param button Button number (1=left, 2=middle, 3=right, 4/5=scroll)
 * \return Linux BTN_* code
 */
static uint32_t
button_to_code(int button)
{
	switch (button) {
	case 1: return BTN_LEFT;
	case 2: return BTN_MIDDLE;
	case 3: return BTN_RIGHT;
	case 4: return BTN_SIDE;
	case 5: return BTN_EXTRA;
	case 6: return BTN_FORWARD;
	case 7: return BTN_BACK;
	case 8: return BTN_TASK;
	default: return BTN_LEFT;
	}
}

/** root.fake_input(event_type, detail, [x], [y]) - Simulate input events
 *
 * Injects synthetic input events for automation and testing.
 * Matches AwesomeWM's API for compatibility.
 *
 * \param event_type One of: "key_press", "key_release", "button_press",
 *                   "button_release", "motion_notify"
 * \param detail For key events: keysym name (string) or keycode (int)
 *               For button events: button number (1=left, 2=middle, 3=right)
 *               For motion events: true for relative, false for absolute
 * \param x X coordinate (for motion events)
 * \param y Y coordinate (for motion events)
 */
static int
luaA_root_fake_input(lua_State *L)
{
	const char *event_type;
	uint32_t timestamp;
	struct xkb_keymap *keymap;

	event_type = luaL_checkstring(L, 1);
	timestamp = get_current_time_msec();

	if (strcmp(event_type, "key_press") == 0 || strcmp(event_type, "key_release") == 0) {
		/* Key event */
		xkb_keycode_t keycode;
		enum wl_keyboard_key_state state;

		state = (strcmp(event_type, "key_press") == 0)
			? WL_KEYBOARD_KEY_STATE_PRESSED
			: WL_KEYBOARD_KEY_STATE_RELEASED;

		keymap = some_xkb_get_keymap();
		if (!keymap)
			return luaL_error(L, "No keyboard/keymap available");

		if (lua_type(L, 2) == LUA_TSTRING) {
			/* Keysym name string */
			const char *key_str = lua_tostring(L, 2);
			xkb_keysym_t keysym = xkb_keysym_from_name(key_str, XKB_KEYSYM_CASE_INSENSITIVE);
			if (keysym == XKB_KEY_NoSymbol)
				return luaL_error(L, "Unknown keysym: %s", key_str);

			keycode = keysym_to_keycode(keymap, keysym);
			if (keycode == 0)
				return luaL_error(L, "Keysym '%s' not in current keymap", key_str);
		} else if (lua_type(L, 2) == LUA_TNUMBER) {
			/* Direct keycode */
			keycode = (xkb_keycode_t)lua_tointeger(L, 2);
		} else {
			return luaL_error(L, "Expected keysym string or keycode number");
		}

		/* XKB keycodes are evdev keycodes + 8 */
		wlr_seat_keyboard_notify_key(seat, timestamp, keycode - 8, state);

	} else if (strcmp(event_type, "button_press") == 0 || strcmp(event_type, "button_release") == 0) {
		/* Button event - update pointer focus to match cursor position first */
		int button;
		uint32_t button_code;
		enum wl_pointer_button_state state;
		struct wlr_surface *surface = NULL;
		double sx, sy;

		button = luaL_checkinteger(L, 2);
		button_code = button_to_code(button);
		state = (strcmp(event_type, "button_press") == 0)
			? WL_POINTER_BUTTON_STATE_PRESSED
			: WL_POINTER_BUTTON_STATE_RELEASED;

		/* Find what surface is under the cursor and update pointer focus
		 * This ensures the button event goes to the correct window */
		xytonode(cursor->x, cursor->y, &surface, NULL, NULL, NULL, NULL, &sx, &sy);
		if (surface) {
			wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
		}

		wlr_seat_pointer_notify_button(seat, timestamp, button_code, state);

	} else if (strcmp(event_type, "motion_notify") == 0) {
		/* Motion event */
		bool relative;
		double x, y;

		relative = lua_toboolean(L, 2);
		x = luaL_optnumber(L, 3, 0);
		y = luaL_optnumber(L, 4, 0);

		if (relative) {
			wlr_cursor_move(cursor, NULL, x, y);
		} else {
			/* Absolute coordinates - warp to position */
			wlr_cursor_warp_absolute(cursor, NULL,
				x / (double)cursor->x, y / (double)cursor->y);
			/* Actually just warp directly */
			wlr_cursor_warp(cursor, NULL, x, y);
		}
		wlr_seat_pointer_notify_motion(seat, timestamp, cursor->x, cursor->y);

	} else {
		return luaL_error(L, "Unknown event type: %s (expected key_press, key_release, "
			"button_press, button_release, or motion_notify)", event_type);
	}

	return 0;
}

/* root module methods */
/** Get root window size (stub for AwesomeWM compatibility)
 * Returns virtual screen dimensions (bounding box of all monitors)
 * Lua: root.size() -> width, height
 */
static int
luaA_root_size(lua_State *L)
{
	struct wlr_box box;

	/* In AwesomeWM this is the root window size (entire X11 virtual screen).
	 * In Wayland, we return the bounding box of all outputs combined.
	 * This matches AwesomeWM's behavior for multi-monitor setups.
	 */
	wlr_output_layout_get_box(output_layout, NULL, &box);
	lua_pushinteger(L, box.width);
	lua_pushinteger(L, box.height);
	return 2;
}

/** Get root window physical size in mm (stub for AwesomeWM compatibility)
 * Returns approximate physical dimensions based on monitor DPI
 * Lua: root.size_mm() -> width_mm, height_mm
 */
static int
luaA_root_size_mm(lua_State *L)
{
	struct wlr_box box;
	struct wl_list *monitors;
	Monitor *m;
	double total_width_mm, total_height_mm, total_pixels;
	int width_mm, height_mm;

	/* Calculate weighted average physical size based on all monitors.
	 * Since monitors can have different DPI, we weight by pixel count.
	 */
	total_width_mm = 0.0;
	total_height_mm = 0.0;
	total_pixels = 0.0;

	monitors = some_get_monitors();
	wl_list_for_each(m, monitors, link) {
		struct wlr_box mon_box;
		double pixels;

		if (!m->wlr_output || !m->wlr_output->enabled)
			continue;

		some_monitor_get_geometry(m, &mon_box);
		pixels = (double)(mon_box.width * mon_box.height);

		/* Weight each monitor's physical size by its pixel count */
		total_width_mm += (double)m->wlr_output->phys_width * pixels;
		total_height_mm += (double)m->wlr_output->phys_height * pixels;
		total_pixels += pixels;
	}

	/* Get total virtual screen size */
	wlr_output_layout_get_box(output_layout, NULL, &box);

	/* Calculate average DPI and apply to virtual screen size */
	if (total_pixels > 0.0) {
		double avg_width_mm_per_pixel = total_width_mm / total_pixels;
		double avg_height_mm_per_pixel = total_height_mm / total_pixels;
		width_mm = (int)(box.width * avg_width_mm_per_pixel);
		height_mm = (int)(box.height * avg_height_mm_per_pixel);
	} else {
		/* Fallback: assume 96 DPI (25.4mm per inch / 96 pixels per inch) */
		width_mm = (int)(box.width * 25.4 / 96.0);
		height_mm = (int)(box.height * 25.4 / 96.0);
	}

	lua_pushinteger(L, width_mm);
	lua_pushinteger(L, height_mm);
	return 2;
}

/** root.cursor(cursor_name) - Set cursor (stub for AwesomeWM compatibility)
 * \param cursor_name Name of cursor to set (e.g., "left_ptr")
 */
static int
luaA_root_cursor(lua_State *L)
{
	const char *cursor_name = luaL_checkstring(L, 1);

	if(wlr_xcursor_manager_get_xcursor(cursor_mgr, cursor_name, 1.0) == NULL) {
		luaA_warn(L, "invalid cursor %s", cursor_name);
		return 0;
	}
	free(selected_root_cursor);
	selected_root_cursor = strdup(cursor_name);
	if(some_get_focused_client() == NULL) {
		wlr_cursor_set_xcursor(cursor, cursor_mgr, cursor_name);
	}
	return 0;
}

/** root.tags() - Get all tags
 * AwesomeWM compatibility: returns array of all tag objects
 * \return Table containing all tags
 */
static int
luaA_root_tags(lua_State *L)
{
	lua_createtable(L, globalconf.tags.len, 0);
	for (int i = 0; i < globalconf.tags.len; i++) {
		luaA_object_push(L, globalconf.tags.tab[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/** root.drawins() - Get all drawins (wiboxes)
 * AwesomeWM compatibility: returns array of all drawin objects
 * \return Table containing all drawins
 */
static int
luaA_root_drawins(lua_State *L)
{
	int i;

	lua_createtable(L, globalconf.drawins.len, 0);

	for (i = 0; i < globalconf.drawins.len; i++) {
		luaA_object_push(L, globalconf.drawins.tab[i]);
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

/* ========== WALLPAPER CACHE ========== */

void wallpaper_cache_init(void)
{
	wl_list_init(&globalconf.wallpaper_cache);
	globalconf.current_wallpaper = NULL;
}

void wallpaper_cache_cleanup(void)
{
	wallpaper_cache_entry_t *entry, *tmp;
	wl_list_for_each_safe(entry, tmp, &globalconf.wallpaper_cache, link) {
		wl_list_remove(&entry->link);
		if (entry->scene_node)
			wlr_scene_node_destroy(&entry->scene_node->node);
		if (entry->surface)
			cairo_surface_destroy(entry->surface);
		free(entry->key);
		free(entry);
	}
	globalconf.current_wallpaper = NULL;
}

/* FNV-1a hash */
static uint32_t fnv1a_hash(const unsigned char *data, size_t len)
{
	uint32_t hash = 2166136261u;
	for (size_t i = 0; i < len; i++) {
		hash ^= data[i];
		hash *= 16777619u;
	}
	return hash;
}

static wallpaper_fingerprint_t
compute_fingerprint(cairo_surface_t *surface)
{
	wallpaper_fingerprint_t fp = {0};
	fp.width = cairo_image_surface_get_width(surface);
	fp.height = cairo_image_surface_get_height(surface);

	unsigned char *data = cairo_image_surface_get_data(surface);
	int stride = cairo_image_surface_get_stride(surface);
	if (data && stride > 0)
		fp.crc = fnv1a_hash(data, stride);
	return fp;
}

static bool
fingerprint_matches(const wallpaper_fingerprint_t *a,
                    const wallpaper_fingerprint_t *b)
{
	return a->width == b->width && a->height == b->height && a->crc == b->crc;
}

static wallpaper_cache_entry_t *
wallpaper_cache_lookup_key(const char *key)
{
	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link) {
		if (entry->key && strcmp(entry->key, key) == 0)
			return entry;
	}
	return NULL;
}

static wallpaper_cache_entry_t *
wallpaper_cache_lookup_fingerprint(const wallpaper_fingerprint_t *fp)
{
	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link) {
		if (fingerprint_matches(&entry->fp, fp))
			return entry;
	}
	return NULL;
}

static int wallpaper_cache_count(void)
{
	int count = 0;
	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link)
		count++;
	return count;
}

static void wallpaper_cache_evict_oldest(void)
{
	if (wallpaper_cache_count() < WALLPAPER_CACHE_MAX)
		return;

	/* Find oldest (last in list, since we insert at head) */
	wallpaper_cache_entry_t *oldest = NULL;
	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link) {
		if (entry != globalconf.current_wallpaper)
			oldest = entry;
	}

	if (oldest) {
		wl_list_remove(&oldest->link);
		if (oldest->scene_node)
			wlr_scene_node_destroy(&oldest->scene_node->node);
		if (oldest->surface)
			cairo_surface_destroy(oldest->surface);
		free(oldest->key);
		free(oldest);
	}
}

static bool
wallpaper_cache_show_entry(wallpaper_cache_entry_t *entry)
{
	if (!entry)
		return false;

	if (globalconf.current_wallpaper && globalconf.current_wallpaper != entry)
		wlr_scene_node_set_enabled(&globalconf.current_wallpaper->scene_node->node, false);

	/* Hide legacy wallpaper node if present */
	if (globalconf.wallpaper_buffer_node &&
	    (!globalconf.current_wallpaper ||
	     globalconf.wallpaper_buffer_node != globalconf.current_wallpaper->scene_node))
		wlr_scene_node_set_enabled(&globalconf.wallpaper_buffer_node->node, false);

	wlr_scene_node_set_enabled(&entry->scene_node->node, true);
	globalconf.current_wallpaper = entry;

	cairo_surface_destroy(globalconf.wallpaper);
	globalconf.wallpaper = cairo_surface_reference(entry->surface);

	luaA_emit_signal_global("wallpaper_changed");
	return true;
}

static bool
wallpaper_cache_show(const char *key)
{
	return wallpaper_cache_show_entry(wallpaper_cache_lookup_key(key));
}

static bool
root_set_wallpaper_cached(cairo_pattern_t *pattern, const char *key)
{
	cairo_surface_t *surface = NULL;
	cairo_t *cr = NULL;
	struct wlr_buffer *buffer = NULL;
	struct wlr_scene_buffer *scene_node = NULL;
	struct wlr_box layout_box;
	wallpaper_fingerprint_t fp;

	wlr_output_layout_get_box(output_layout, NULL, &layout_box);
	int width = layout_box.width;
	int height = layout_box.height;

	if (width <= 0 || height <= 0)
		return false;

	surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		goto fail;

	cr = cairo_create(surface);
	cairo_set_source(cr, pattern);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);
	cr = NULL;
	cairo_surface_flush(surface);

	fp = compute_fingerprint(surface);

	/* Check cache by key first, then fingerprint */
	wallpaper_cache_entry_t *entry = NULL;
	if (key)
		entry = wallpaper_cache_lookup_key(key);
	if (!entry)
		entry = wallpaper_cache_lookup_fingerprint(&fp);

	if (entry) {
		cairo_surface_destroy(surface);
		return wallpaper_cache_show_entry(entry);
	}

	/* Cache miss */
	buffer = drawable_create_buffer_from_data(
		width, height,
		cairo_image_surface_get_data(surface),
		cairo_image_surface_get_stride(surface)
	);
	if (!buffer)
		goto fail;

	scene_node = wlr_scene_buffer_create(layers[0], buffer);
	if (!scene_node)
		goto fail;
	wlr_scene_node_set_position(&scene_node->node, 0, 0);
	wlr_scene_node_set_enabled(&scene_node->node, false);

	wallpaper_cache_evict_oldest();

	entry = calloc(1, sizeof(*entry));
	if (!entry)
		goto fail;
	entry->key = key ? strdup(key) : NULL;
	entry->fp = fp;
	entry->scene_node = scene_node;
	entry->surface = surface;
	wl_list_insert(&globalconf.wallpaper_cache, &entry->link);

	wlr_buffer_drop(buffer);
	return wallpaper_cache_show_entry(entry);

fail:
	if (scene_node) wlr_scene_node_destroy(&scene_node->node);
	if (buffer) wlr_buffer_drop(buffer);
	if (cr) cairo_destroy(cr);
	if (surface) cairo_surface_destroy(surface);
	return false;
}

/* ========== WALLPAPER LUA API ========== */

/* root._wallpaper([pattern[, key]]) - Get/set wallpaper with automatic caching */
static int
luaA_root_wallpaper(lua_State *L)
{
	cairo_pattern_t *pattern;
	int nargs = lua_gettop(L);

	if (nargs >= 1 && !lua_isnil(L, 1)) {
		pattern = (cairo_pattern_t *)lua_touserdata(L, 1);
		const char *key = (nargs >= 2 && lua_isstring(L, 2)) ? lua_tostring(L, 2) : NULL;
		lua_pushboolean(L, root_set_wallpaper_cached(pattern, key));
		return 1;
	}

	if (globalconf.wallpaper == NULL)
		return 0;

	lua_pushlightuserdata(L, cairo_surface_reference(globalconf.wallpaper));
	return 1;
}

/* root.wallpaper_show(key) - Show a previously cached wallpaper */
static int
luaA_root_wallpaper_show(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);
	lua_pushboolean(L, wallpaper_cache_show(key));
	return 1;
}

/* root.wallpaper_cache_clear() - Free all cached wallpapers */
static int
luaA_root_wallpaper_cache_clear(lua_State *L)
{
	(void)L;
	wallpaper_cache_cleanup();
	wallpaper_cache_init();
	return 0;
}

/** root.set_index_miss_handler(function) - Set custom property getter
 * AwesomeWM compatibility: allows Lua code to handle missing properties
 * \param handler Function to call when an undefined property is accessed
 */
static int
luaA_root_set_index_miss_handler(lua_State *L)
{
	return luaA_registerfct(L, 1, &miss_index_handler);
}

/** root.set_newindex_miss_handler(function) - Set custom property setter
 * AwesomeWM compatibility: allows Lua code to handle property assignment
 * \param handler Function to call when setting an undefined property
 */
static int
luaA_root_set_newindex_miss_handler(lua_State *L)
{
	return luaA_registerfct(L, 1, &miss_newindex_handler);
}

/** root.set_call_handler(function) - Set custom call handler
 * AwesomeWM compatibility: allows Lua code to handle root() calls
 * \param handler Function to call when root() is invoked as a function
 */
static int
luaA_root_set_call_handler(lua_State *L)
{
	return luaA_registerfct(L, 1, &miss_call_handler);
}

/* ========== SCREENSHOT SUPPORT ========== */

/** Callback data for scene buffer iteration during screenshot */
struct screenshot_render_data {
	cairo_t *cr;             /* Cairo context to draw on */
	struct wlr_renderer *renderer;
	int offset_x, offset_y;  /* Offset for this output in virtual screen */
};

/** Composite a Cairo surface onto the screenshot at the given position.
 * Used to directly composite widget content from drawable surfaces.
 */
static void
composite_cairo_surface(cairo_t *cr, cairo_surface_t *surface,
                        int x, int y, int width, int height)
{
	if (!surface || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		return;

	cairo_save(cr);
	cairo_set_source_surface(cr, surface, x, y);
	/* Use OVER operator to handle transparency */
	cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
	cairo_rectangle(cr, x, y, width, height);
	cairo_fill(cr);
	cairo_restore(cr);
}

/** Composite all widgets directly from their drawable Cairo surfaces.
 * This bypasses wlroots scene buffers which may have NULL content between frames.
 * Note: Wallpaper is handled separately in luaA_root_get_content().
 */
static void
composite_widgets_directly(cairo_t *cr, bool ontop_only)
{
	int i, bar;
	drawin_t *drawin;
	client_t *c;
	bool is_ontop;

	/* Composite visible drawins filtered by ontop state */
	for (i = 0; i < globalconf.drawins.len; i++) {
		drawin = globalconf.drawins.tab[i];
		if (!drawin || !drawin->visible || !drawin->drawable)
			continue;

		/* Filter by ontop to ensure correct z-order in screenshots */
		if (drawin->ontop != ontop_only)
			continue;

		if (drawin->drawable->surface &&
		    cairo_surface_status(drawin->drawable->surface) == CAIRO_STATUS_SUCCESS) {
			cairo_surface_t *surface_to_composite = drawin->drawable->surface;
			cairo_surface_t *masked_surface = NULL;

			/* Apply shape_bounding mask if set (for rounded corners etc.) */
			if (drawin->shape_bounding &&
			    cairo_surface_status(drawin->shape_bounding) == CAIRO_STATUS_SUCCESS) {
				masked_surface = drawin_apply_shape_mask_for_screenshot(
					drawin->drawable->surface, drawin->shape_bounding);
				if (masked_surface)
					surface_to_composite = masked_surface;
			}

			composite_cairo_surface(cr, surface_to_composite,
			                        drawin->x, drawin->y,
			                        drawin->width, drawin->height);

			/* Clean up temporary masked surface */
			if (masked_surface)
				cairo_surface_destroy(masked_surface);
		}
	}

	/* Composite client titlebars filtered by ontop/fullscreen state */
	for (i = 0; i < globalconf.clients.len; i++) {
		c = globalconf.clients.tab[i];
		if (!c)
			continue;

		/* Filter by ontop/fullscreen to ensure correct z-order */
		is_ontop = c->ontop || c->fullscreen;
		if (is_ontop != ontop_only)
			continue;

		for (bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++) {
			drawable_t *d = c->titlebar[bar].drawable;
			int size = c->titlebar[bar].size;
			int tb_x, tb_y, tb_w, tb_h;

			if (!d || !d->surface || size <= 0)
				continue;

			if (cairo_surface_status(d->surface) != CAIRO_STATUS_SUCCESS)
				continue;

			/* Calculate titlebar position based on client geometry and bar type */
			switch (bar) {
			case CLIENT_TITLEBAR_TOP:
				tb_x = c->geometry.x;
				tb_y = c->geometry.y;
				tb_w = c->geometry.width;
				tb_h = size;
				break;
			case CLIENT_TITLEBAR_BOTTOM:
				tb_x = c->geometry.x;
				tb_y = c->geometry.y + c->geometry.height - size;
				tb_w = c->geometry.width;
				tb_h = size;
				break;
			case CLIENT_TITLEBAR_LEFT:
				tb_x = c->geometry.x;
				tb_y = c->geometry.y + c->titlebar[CLIENT_TITLEBAR_TOP].size;
				tb_w = size;
				tb_h = c->geometry.height -
				       c->titlebar[CLIENT_TITLEBAR_TOP].size -
				       c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
				break;
			case CLIENT_TITLEBAR_RIGHT:
				tb_x = c->geometry.x + c->geometry.width - size;
				tb_y = c->geometry.y + c->titlebar[CLIENT_TITLEBAR_TOP].size;
				tb_w = size;
				tb_h = c->geometry.height -
				       c->titlebar[CLIENT_TITLEBAR_TOP].size -
				       c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
				break;
			default:
				continue;
			}

			composite_cairo_surface(cr, d->surface, tb_x, tb_y, tb_w, tb_h);
		}
	}
}

/** Callback for wlr_scene_output_for_each_buffer
 * Reads pixels from each scene buffer and composites onto Cairo surface.
 * Handles both SHM buffers (widgets) and GPU buffers (clients).
 */
static void
composite_scene_buffer_to_cairo(struct wlr_scene_buffer *scene_buffer,
                                int sx, int sy, void *data)
{
	struct screenshot_render_data *rdata = data;
	struct wlr_buffer *buffer;
	cairo_surface_t *buf_surface;
	int buf_width, buf_height;
	void *shm_data;
	uint32_t shm_format;
	size_t shm_stride;
	void *pixels = NULL;
	size_t stride;
	bool need_free = false;
	cairo_format_t cairo_fmt;

	if (!scene_buffer->buffer)
		return;

	buffer = scene_buffer->buffer;
	buf_width = scene_buffer->dst_width;
	buf_height = scene_buffer->dst_height;

	if (buf_width <= 0 || buf_height <= 0)
		return;

	/* First try direct buffer access (works for SHM buffers - widgets) */
	if (wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
	                                     &shm_data, &shm_format, &shm_stride)) {
		/* Direct access succeeded - this is an SHM buffer */

		/* Check format compatibility with Cairo */
		if (shm_format == DRM_FORMAT_ARGB8888 || shm_format == DRM_FORMAT_XRGB8888) {
			cairo_fmt = (shm_format == DRM_FORMAT_ARGB8888) ?
			            CAIRO_FORMAT_ARGB32 : CAIRO_FORMAT_RGB24;
			buf_surface = cairo_image_surface_create_for_data(
				shm_data, cairo_fmt, buf_width, buf_height, shm_stride);

			if (cairo_surface_status(buf_surface) == CAIRO_STATUS_SUCCESS) {
				/* Composite onto target surface */
				cairo_save(rdata->cr);
				cairo_set_source_surface(rdata->cr, buf_surface,
					sx + rdata->offset_x, sy + rdata->offset_y);
				cairo_paint(rdata->cr);
				cairo_restore(rdata->cr);
				cairo_surface_destroy(buf_surface);
			}
		}
		wlr_buffer_end_data_ptr_access(buffer);
		return;
	}

	/* Direct access failed - try GPU texture path (for DMA-BUF/GPU buffers) */
	{
		struct wlr_texture *texture;

		texture = wlr_texture_from_buffer(rdata->renderer, buffer);
		if (!texture)
			return;

		/* Allocate pixel buffer for reading */
		stride = buf_width * 4;
		pixels = malloc(stride * buf_height);
		if (!pixels) {
			wlr_texture_destroy(texture);
			return;
		}
		need_free = true;

		/* Read pixels from texture */
		if (!wlr_texture_read_pixels(texture, &(struct wlr_texture_read_pixels_options){
			.data = pixels,
			.format = DRM_FORMAT_ARGB8888,
			.stride = stride,
			.src_box = { .x = 0, .y = 0, .width = buf_width, .height = buf_height },
		})) {
			free(pixels);
			wlr_texture_destroy(texture);
			return;
		}

		wlr_texture_destroy(texture);
	}

	/* Create Cairo surface from pixel data */
	buf_surface = cairo_image_surface_create_for_data(
		pixels, CAIRO_FORMAT_ARGB32, buf_width, buf_height, stride);

	if (cairo_surface_status(buf_surface) != CAIRO_STATUS_SUCCESS) {
		if (need_free)
			free(pixels);
		return;
	}

	/* Composite onto target surface */
	cairo_save(rdata->cr);
	cairo_set_source_surface(rdata->cr, buf_surface,
		sx + rdata->offset_x, sy + rdata->offset_y);
	cairo_paint(rdata->cr);
	cairo_restore(rdata->cr);

	cairo_surface_destroy(buf_surface);
	if (need_free)
		free(pixels);
}

/** root.content([preserve_alpha]) - Get screenshot of entire desktop
 *
 * Returns a Cairo surface containing the current desktop content.
 * Uses CPU-side compositing to avoid GPU buffer compatibility issues.
 *
 * \param preserve_alpha Optional boolean. If true, skips wallpaper compositing
 *        and clears to transparent, preserving alpha channel of transparent windows.
 *        Default is false (normal screenshot with wallpaper).
 * \return cairo_surface_t* as lightuserdata
 */
static int
luaA_root_get_content(lua_State *L)
{
	struct wlr_box layout_box;
	cairo_surface_t *surface;
	cairo_t *cr;
	int width, height;
	struct screenshot_render_data rdata;
	bool preserve_alpha = false;

	/* Check for optional preserve_alpha parameter */
	if (lua_gettop(L) >= 1 && lua_isboolean(L, 1))
		preserve_alpha = lua_toboolean(L, 1);

	/* Get virtual screen size (bounding box of all outputs) */
	wlr_output_layout_get_box(output_layout, NULL, &layout_box);
	width = layout_box.width;
	height = layout_box.height;

	if (width <= 0 || height <= 0)
		return 0;

	/* Create Cairo surface for compositing */
	surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		return 0;

	cr = cairo_create(surface);

	if (preserve_alpha) {
		/* Clear to fully transparent for alpha-preserving screenshots */
		cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
		cairo_set_source_rgba(cr, 0, 0, 0, 0);
		cairo_paint(cr);
		cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
	} else {
		/* Clear to black and composite wallpaper (normal behavior) */
		cairo_set_source_rgb(cr, 0, 0, 0);
		cairo_paint(cr);

		/* Composite wallpaper as background */
		if (globalconf.wallpaper)
			composite_cairo_surface(cr, globalconf.wallpaper, 0, 0, width, height);
	}

	/* Set up render data - no offset since we're using layout coordinates */
	rdata.cr = cr;
	rdata.renderer = drw;
	rdata.offset_x = 0;
	rdata.offset_y = 0;

	/* Iterate scene buffers for client content (GPU-rendered surfaces) */
	wlr_scene_node_for_each_buffer(&scene->tree.node,
		composite_scene_buffer_to_cairo, &rdata);

	/* Composite widgets in z-order: normal first, then ontop.
	 * This ensures correct layering where ontop popups appear above titlebars. */
	composite_widgets_directly(cr, false);  /* Normal widgets */
	composite_widgets_directly(cr, true);   /* Ontop widgets */

	cairo_destroy(cr);

	/* Return surface as lightuserdata (Lua will use gears.surface to manage it) */
	lua_pushlightuserdata(L, surface);
	return 1;
}

/* ========== END SCREENSHOT SUPPORT ========== */

/** __index metamethod for root
 * Delegates to miss handler if set, otherwise calls default handler.
 * Matches AwesomeWM root.c:620-626 exactly.
 */
static int
luaA_root_index(lua_State *L)
{
	if (miss_index_handler != LUA_REFNIL)
		return luaA_call_handler(L, miss_index_handler);
	return luaA_default_index(L);
}

/** __newindex metamethod for root
 * Delegates to miss handler if set, otherwise calls default handler.
 * Matches AwesomeWM root.c:628-633 exactly.
 */
static int
luaA_root_newindex(lua_State *L)
{
	if (miss_newindex_handler != LUA_REFNIL)
		return luaA_call_handler(L, miss_newindex_handler);
	return luaA_default_newindex(L);
}

static const luaL_Reg root_methods[] = {
	/* AwesomeWM-compatible exports (following Prime Directive) */
	{ "_buttons", luaA_root_buttons },
	{ "_keys", luaA_root_keys },
	{ "_wallpaper", luaA_root_wallpaper },
	{ "wallpaper_show", luaA_root_wallpaper_show },
	{ "wallpaper_cache_clear", luaA_root_wallpaper_cache_clear },
	{ "cursor", luaA_root_cursor },
	{ "fake_input", luaA_root_fake_input },
	{ "drawins", luaA_root_drawins },
	{ "size", luaA_root_size },
	{ "size_mm", luaA_root_size_mm },
	{ "tags", luaA_root_tags },
	{ "content", luaA_root_get_content },
	/* __index and __newindex MUST be in methods, not meta!
	 * luaA_openlib sets the methods table as its own metatable.
	 * So __index must be in methods for metamethod lookup to find it.
	 * This matches AwesomeWM root.c:654-655 exactly. */
	{ "__index", luaA_root_index },
	{ "__newindex", luaA_root_newindex },
	{ "set_index_miss_handler", luaA_root_set_index_miss_handler },
	{ "set_newindex_miss_handler", luaA_root_set_newindex_miss_handler },
	{ "set_call_handler", luaA_root_set_call_handler },
	{ NULL, NULL }
};

/* Empty meta table - matches AwesomeWM root.c:663-666 */
static const luaL_Reg root_meta[] = {
	{ NULL, NULL }
};

/** Setup the root Lua module
 * Creates the global 'root' table for AwesomeWM compatibility
 */
void
luaA_root_setup(lua_State *L)
{
	luaA_openlib(L, "root", root_methods, root_meta);
}
