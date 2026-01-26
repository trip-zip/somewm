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
#include "objects/screen.h"
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
#include <gdk-pixbuf/gdk-pixbuf.h>

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
 * Wayland: Wallpaper is set via root_set_wallpaper_buffer.
 */
void
root_update_wallpaper(void)
{
    /* X11-only: Reads _XROOTPMAP_ID pixmap property.
     * Wayland wallpaper is set via root_set_wallpaper() or
     * root_set_wallpaper_buffer(). */
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

/* ========== WALLPAPER SUPPORT ========== */

/* ========== WALLPAPER CACHE ==========
 * Issue #214: Cache wallpaper scene nodes for instant tag switching.
 *
 * TODO(2.x): This is a candidate for refactoring into a dedicated module:
 *   - compositor/texture_cache.c - generic GPU texture caching
 *   - features/wallpaper.c - wallpaper-specific logic
 * The wallpaper cache is conceptually a compositor-level texture cache that
 * happens to be used for wallpapers. In 2.x it could cache any frequently-used
 * textures (icons, wibox backgrounds, etc.) and live outside of root.c.
 */

void wallpaper_cache_init(void)
{
	wl_list_init(&globalconf.wallpaper_cache);
	for (int i = 0; i < WALLPAPER_MAX_SCREENS; i++) {
		globalconf.current_wallpaper_per_screen[i] = NULL;
	}
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
		free(entry->path);
		free(entry);
	}
	for (int i = 0; i < WALLPAPER_MAX_SCREENS; i++) {
		globalconf.current_wallpaper_per_screen[i] = NULL;
	}
}

static wallpaper_cache_entry_t *
wallpaper_cache_lookup(const char *path, int screen_index)
{
	if (!path || !globalconf.wallpaper_cache.next)
		return NULL;

	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link) {
		if (entry->path && strcmp(entry->path, path) == 0 &&
		    entry->screen_index == screen_index)
			return entry;
	}
	return NULL;
}

static int wallpaper_cache_count(void)
{
	int count = 0;
	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link) {
		count++;
	}
	return count;
}

/** Check if entry is currently displayed on any screen */
static bool wallpaper_cache_entry_is_current(wallpaper_cache_entry_t *entry)
{
	for (int i = 0; i < WALLPAPER_MAX_SCREENS; i++) {
		if (globalconf.current_wallpaper_per_screen[i] == entry)
			return true;
	}
	return false;
}

static void wallpaper_cache_evict_oldest(void)
{
	if (wallpaper_cache_count() < WALLPAPER_CACHE_MAX)
		return;

	/* Find oldest (last in list, since we insert at head) that isn't currently shown */
	wallpaper_cache_entry_t *oldest = NULL;
	wallpaper_cache_entry_t *entry;
	wl_list_for_each(entry, &globalconf.wallpaper_cache, link) {
		if (!wallpaper_cache_entry_is_current(entry))
			oldest = entry;
	}

	if (oldest) {
		wl_list_remove(&oldest->link);
		if (oldest->scene_node)
			wlr_scene_node_destroy(&oldest->scene_node->node);
		if (oldest->surface)
			cairo_surface_destroy(oldest->surface);
		free(oldest->path);
		free(oldest);
	}
}

/** Show a cached wallpaper for a specific screen.
 * Only hides/shows wallpapers for that screen, leaving other screens untouched.
 * \param entry The cache entry to show
 * \param screen_index The screen index (0-based)
 * \return true on success
 */
static bool
wallpaper_cache_show(wallpaper_cache_entry_t *entry, int screen_index)
{
	if (!entry || !entry->scene_node)
		return false;
	if (screen_index < 0 || screen_index >= WALLPAPER_MAX_SCREENS)
		return false;

	/* Hide current wallpaper for THIS screen only */
	wallpaper_cache_entry_t *current = globalconf.current_wallpaper_per_screen[screen_index];
	if (current && current != entry && current->scene_node) {
		wlr_scene_node_set_enabled(&current->scene_node->node, false);
	}

	/* Also hide legacy wallpaper node if present (global, not per-screen) */
	if (globalconf.wallpaper_buffer_node) {
		wlr_scene_node_set_enabled(&globalconf.wallpaper_buffer_node->node, false);
	}

	/* Show requested wallpaper */
	wlr_scene_node_set_enabled(&entry->scene_node->node, true);
	globalconf.current_wallpaper_per_screen[screen_index] = entry;

	/* Update globalconf.wallpaper for getter compatibility
	 * Note: This is a single surface, so multi-screen gets the last one set.
	 * This matches AwesomeWM behavior where root.wallpaper() returns one surface.
	 */
	if (globalconf.wallpaper)
		cairo_surface_destroy(globalconf.wallpaper);
	globalconf.wallpaper = cairo_surface_reference(entry->surface);

	luaA_emit_signal_global("wallpaper_changed");
	return true;
}

/** Get the wallpaper path from Lua global (set by monkey-patched gears.surface.load) */
static const char *
get_wallpaper_path_from_lua(lua_State *L)
{
	lua_getglobal(L, "_somewm_last_wallpaper_path");
	const char *path = NULL;
	if (lua_isstring(L, -1)) {
		path = lua_tostring(L, -1);
	}
	lua_pop(L, 1);
	return path;
}

/** Screen info from Lua table */
typedef struct {
	int index;   /* 0-based screen index */
	int x, y;    /* Screen position */
	int width, height;  /* Screen size */
	bool valid;
} wallpaper_screen_info_t;

#define MAX_PENDING_SCREENS 8

/** Get ALL screen infos for a path from Lua nested table
 * Table structure: _somewm_wallpaper_screen_info[path][screen_index] = {x, y, width, height}
 * Returns count of valid screens found (up to MAX_PENDING_SCREENS)
 */
static int
get_all_wallpaper_screen_infos_from_lua(lua_State *L, const char *path,
                                        wallpaper_screen_info_t *infos, int max_infos)
{
	int count = 0;

	if (!path || !infos || max_infos <= 0)
		return 0;

	/* Look up the nested table: _somewm_wallpaper_screen_info[path] */
	lua_getglobal(L, "_somewm_wallpaper_screen_info");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return 0;
	}

	lua_getfield(L, -1, path);
	if (!lua_istable(L, -1)) {
		lua_pop(L, 2);
		return 0;
	}

	/* Iterate over all screen indices in the path's table */
	lua_pushnil(L);  /* first key */
	while (lua_next(L, -2) != 0 && count < max_infos) {
		/* key is screen_index (Lua 1-based), value is geometry table */
		if (lua_isnumber(L, -2) && lua_istable(L, -1)) {
			int screen_index = (int)lua_tointeger(L, -2) - 1;  /* Convert to 0-based */

			wallpaper_screen_info_t *info = &infos[count];
			info->index = screen_index;
			info->valid = false;

			lua_getfield(L, -1, "x");
			info->x = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
			lua_pop(L, 1);

			lua_getfield(L, -1, "y");
			info->y = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
			lua_pop(L, 1);

			lua_getfield(L, -1, "width");
			info->width = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
			lua_pop(L, 1);

			lua_getfield(L, -1, "height");
			info->height = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
			lua_pop(L, 1);

			if (screen_index >= 0 && info->width > 0 && info->height > 0) {
				info->valid = true;
				count++;
			}
		}
		lua_pop(L, 1);  /* pop value, keep key for next iteration */
	}

	lua_pop(L, 2);  /* pop path table and screen_info table */
	return count;
}

/** Clear the wallpaper path and screen Lua globals after using them */
static void
clear_wallpaper_info_in_lua(lua_State *L)
{
	/* Get path first so we can clear its entry from the screen info table */
	lua_getglobal(L, "_somewm_last_wallpaper_path");
	if (lua_isstring(L, -1)) {
		const char *path = lua_tostring(L, -1);
		/* Clear the screen info table entry for this path */
		lua_getglobal(L, "_somewm_wallpaper_screen_info");
		if (lua_istable(L, -1)) {
			lua_pushnil(L);
			lua_setfield(L, -2, path);
		}
		lua_pop(L, 1);  /* pop table */
	}
	lua_pop(L, 1);  /* pop path */

	/* Clear the path global */
	lua_pushnil(L);
	lua_setglobal(L, "_somewm_last_wallpaper_path");
}

/* ========== WALLPAPER API ========== */

/** Create a cache entry for one screen
 * Returns true on success, false on failure
 */
static bool
create_wallpaper_cache_entry(const char *path, cairo_pattern_t *pattern,
                             wallpaper_screen_info_t *info)
{
	cairo_surface_t *surface = NULL;
	cairo_t *cr = NULL;
	struct wlr_buffer *buffer = NULL;
	struct wlr_scene_buffer *scene_node = NULL;

	int x = info->x;
	int y = info->y;
	int width = info->width;
	int height = info->height;
	int screen_index = info->index;

	surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		goto fail;

	/* Paint pattern to surface, offsetting to extract the screen region */
	cr = cairo_create(surface);
	cairo_translate(cr, -x, -y);
	cairo_set_source(cr, pattern);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);
	cr = NULL;
	cairo_surface_flush(surface);

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

	wlr_scene_node_set_position(&scene_node->node, x, y);
	wlr_scene_node_set_enabled(&scene_node->node, false);  /* Hidden until shown */

	wallpaper_cache_evict_oldest();

	wallpaper_cache_entry_t *entry = calloc(1, sizeof(*entry));
	if (!entry)
		goto fail;

	entry->path = strdup(path);
	entry->screen_index = screen_index;
	entry->scene_node = scene_node;
	entry->surface = surface;
	wl_list_insert(&globalconf.wallpaper_cache, &entry->link);

	wlr_buffer_drop(buffer);

	/* Show this wallpaper */
	wallpaper_cache_show(entry, screen_index);
	return true;

fail:
	if (scene_node)
		wlr_scene_node_destroy(&scene_node->node);
	if (buffer)
		wlr_buffer_drop(buffer);
	if (surface)
		cairo_surface_destroy(surface);
	return false;
}

/** Set wallpaper with per-screen caching
 * Creates cache entries for ALL screens that requested this wallpaper path.
 * This handles the case where the same wallpaper is used on multiple screens.
 */
static bool
root_set_wallpaper_cached(lua_State *L, cairo_pattern_t *pattern)
{
	const char *path = get_wallpaper_path_from_lua(L);
	bool cache_enabled = globalconf.wallpaper_cache.next != NULL;
	bool result = false;

	/* Get ALL pending screens for this path */
	wallpaper_screen_info_t screen_infos[MAX_PENDING_SCREENS];
	int screen_count = 0;

	if (cache_enabled && path) {
		screen_count = get_all_wallpaper_screen_infos_from_lua(L, path,
			screen_infos, MAX_PENDING_SCREENS);
	}

	/* Create cache entries for all pending screens */
	if (screen_count > 0) {
		for (int i = 0; i < screen_count; i++) {
			wallpaper_screen_info_t *info = &screen_infos[i];
			if (!info->valid)
				continue;

			/* Check if already cached */
			wallpaper_cache_entry_t *existing = wallpaper_cache_lookup(path, info->index);
			if (existing) {
				wallpaper_cache_show(existing, info->index);
				result = true;
				continue;
			}

			/* Create new cache entry */
			if (create_wallpaper_cache_entry(path, pattern, info))
				result = true;
		}

		clear_wallpaper_info_in_lua(L);
		if (result)
			return true;
	}

	/* Fallback: no caching (cache not ready, no path, or no screens) */
	/* Use full layout geometry */
	struct wlr_box layout_box;
	wlr_output_layout_get_box(output_layout, NULL, &layout_box);
	int x = 0, y = 0;
	int width = layout_box.width;
	int height = layout_box.height;

	if (width <= 0 || height <= 0) {
		clear_wallpaper_info_in_lua(L);
		return false;
	}

	/* Create single wallpaper for full layout (legacy path) */
	cairo_surface_t *surface = NULL;
	cairo_t *cr = NULL;
	struct wlr_buffer *buffer = NULL;
	struct wlr_scene_buffer *scene_node = NULL;

	surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		goto cleanup;

	cr = cairo_create(surface);
	cairo_translate(cr, -x, -y);
	cairo_set_source(cr, pattern);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);
	cr = NULL;
	cairo_surface_flush(surface);

	buffer = drawable_create_buffer_from_data(
		width, height,
		cairo_image_surface_get_data(surface),
		cairo_image_surface_get_stride(surface)
	);
	if (!buffer)
		goto cleanup;

	scene_node = wlr_scene_buffer_create(layers[0], buffer);
	if (!scene_node)
		goto cleanup;
	wlr_scene_node_set_position(&scene_node->node, x, y);

	if (globalconf.wallpaper_buffer_node)
		wlr_scene_node_destroy(&globalconf.wallpaper_buffer_node->node);
	globalconf.wallpaper_buffer_node = scene_node;

	if (globalconf.wallpaper)
		cairo_surface_destroy(globalconf.wallpaper);
	globalconf.wallpaper = surface;
	surface = NULL;

	wlr_buffer_drop(buffer);
	buffer = NULL;

	luaA_emit_signal_global("wallpaper_changed");
	result = true;

cleanup:
	if (cr) cairo_destroy(cr);
	if (surface) cairo_surface_destroy(surface);
	if (buffer) wlr_buffer_drop(buffer);
	clear_wallpaper_info_in_lua(L);
	return result;
}

/** root._wallpaper([pattern]) - Get or set wallpaper
 * VERBATIM copy from AwesomeWM root.c:493-515
 *
 * Getter: Returns cached wallpaper surface as lightuserdata
 * Setter: Sets wallpaper from Cairo pattern (lightuserdata)
 *
 * \param pattern Optional Cairo pattern to set as wallpaper
 * \return For setter: boolean success. For getter: cairo_surface_t* or nil
 *
 * @deprecated wallpaper
 * @see awful.wallpaper
 */
static int
luaA_root_wallpaper(lua_State *L)
{
	cairo_pattern_t *pattern;

	if(lua_gettop(L) == 1)
	{
		/* Avoid `error()s` down the line. If this happens during
		 * initialization, AwesomeWM can be stuck in an infinite loop */
		if(lua_isnil(L, -1))
			return 0;

		pattern = (cairo_pattern_t *)lua_touserdata(L, -1);
		lua_pushboolean(L, root_set_wallpaper_cached(L, pattern));
		/* Don't return the wallpaper, it's too easy to get memleaks */
		return 1;
	}

	if(globalconf.wallpaper == NULL)
		return 0;

	/* lua has to make sure this surface gets destroyed */
	lua_pushlightuserdata(L, cairo_surface_reference(globalconf.wallpaper));
	return 1;
}

/* ========== END WALLPAPER SUPPORT ========== */

/** root.wallpaper_cache_has(path, screen) - Check if wallpaper is cached for screen
 * \param path Wallpaper file path
 * \param screen Screen object or index (1-based)
 * \return true if (path, screen) is in cache
 */
static int
luaA_root_wallpaper_cache_has(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	int screen_index = -1;

	/* Get screen index from screen object or number */
	if (lua_isnumber(L, 2)) {
		screen_index = (int)lua_tointeger(L, 2) - 1;  /* Lua is 1-based */
	} else {
		screen_t *screen = luaA_toscreen(L, 2);
		if (screen)
			screen_index = screen->index - 1;  /* screen->index is 1-based */
	}

	bool has = (screen_index >= 0) && wallpaper_cache_lookup(path, screen_index) != NULL;
	lua_pushboolean(L, has);
	return 1;
}

/** root.wallpaper_cache_show(path, screen) - Show cached wallpaper directly
 * Skips all Lua/cairo work if wallpaper is cached for the given screen.
 * \param path Wallpaper file path
 * \param screen Screen object or index (1-based)
 * \return true if cache hit and wallpaper shown, false otherwise
 */
static int
luaA_root_wallpaper_cache_show(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	int screen_index = -1;

	/* Get screen index from screen object or number */
	if (lua_isnumber(L, 2)) {
		screen_index = (int)lua_tointeger(L, 2) - 1;  /* Lua is 1-based */
	} else {
		screen_t *screen = luaA_toscreen(L, 2);
		if (screen) {
			screen_index = screen->index - 1;  /* screen->index is 1-based */
		}
	}

	if (screen_index < 0) {
		lua_pushboolean(L, false);
		return 1;
	}

	wallpaper_cache_entry_t *entry = wallpaper_cache_lookup(path, screen_index);
	if (entry) {
		bool ok = wallpaper_cache_show(entry, screen_index);
		lua_pushboolean(L, ok);
		return 1;
	}

	lua_pushboolean(L, false);
	return 1;
}

/** root.wallpaper_cache_clear() - Clear all cached wallpapers
 * Frees GPU memory used by cached wallpaper textures.
 */
static int
luaA_root_wallpaper_cache_clear(lua_State *L)
{
	(void)L;

	if (!globalconf.wallpaper_cache.next)
		return 0;

	wallpaper_cache_entry_t *entry, *tmp;
	wl_list_for_each_safe(entry, tmp, &globalconf.wallpaper_cache, link) {
		wl_list_remove(&entry->link);
		if (entry->scene_node)
			wlr_scene_node_destroy(&entry->scene_node->node);
		if (entry->surface)
			cairo_surface_destroy(entry->surface);
		free(entry->path);
		free(entry);
	}

	for (int i = 0; i < WALLPAPER_MAX_SCREENS; i++) {
		globalconf.current_wallpaper_per_screen[i] = NULL;
	}
	return 0;
}

/** Preload a single wallpaper into cache for a specific screen (internal helper) */
static bool
wallpaper_cache_preload_path(const char *path, int screen_index)
{
	if (!path || !globalconf.wallpaper_cache.next)
		return false;
	if (screen_index < 0 || screen_index >= (int)globalconf.screens.len)
		return false;

	/* Already cached for this screen? */
	if (wallpaper_cache_lookup(path, screen_index))
		return true;

	/* Get screen geometry */
	screen_t *screen = globalconf.screens.tab[screen_index];
	if (!screen)
		return false;
	int scr_x = screen->geometry.x;
	int scr_y = screen->geometry.y;
	int scr_width = screen->geometry.width;
	int scr_height = screen->geometry.height;
	if (scr_width <= 0 || scr_height <= 0)
		return false;

	/* Load image via gdk-pixbuf */
	GError *error = NULL;
	GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(path, &error);
	if (!pixbuf) {
		if (error) g_error_free(error);
		return false;
	}

	int img_width = gdk_pixbuf_get_width(pixbuf);
	int img_height = gdk_pixbuf_get_height(pixbuf);
	int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
	int n_channels = gdk_pixbuf_get_n_channels(pixbuf);
	guchar *pixels = gdk_pixbuf_get_pixels(pixbuf);

	/* Create a screen-sized surface */
	cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, scr_width, scr_height);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
		g_object_unref(pixbuf);
		return false;
	}

	/* Create intermediate surface for the source image */
	cairo_surface_t *img_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, img_width, img_height);
	if (cairo_surface_status(img_surface) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surface);
		g_object_unref(pixbuf);
		return false;
	}

	/* Copy pixbuf to image surface */
	unsigned char *dest = cairo_image_surface_get_data(img_surface);
	int dest_stride = cairo_image_surface_get_stride(img_surface);
	for (int y = 0; y < img_height; y++) {
		guchar *src_row = pixels + y * rowstride;
		uint32_t *dest_row = (uint32_t *)(dest + y * dest_stride);
		for (int x = 0; x < img_width; x++) {
			guchar r = src_row[x * n_channels + 0];
			guchar g = src_row[x * n_channels + 1];
			guchar b = src_row[x * n_channels + 2];
			guchar a = (n_channels == 4) ? src_row[x * n_channels + 3] : 255;
			dest_row[x] = (a << 24) | (r << 16) | (g << 8) | b;
		}
	}
	cairo_surface_mark_dirty(img_surface);
	g_object_unref(pixbuf);

	/* Scale image to fit screen (maximized style) */
	cairo_t *cr = cairo_create(surface);
	double scale_x = (double)scr_width / img_width;
	double scale_y = (double)scr_height / img_height;
	double scale = (scale_x > scale_y) ? scale_x : scale_y;  /* Cover (max scale) */
	double offset_x = (scr_width - img_width * scale) / 2.0;
	double offset_y = (scr_height - img_height * scale) / 2.0;
	cairo_translate(cr, offset_x, offset_y);
	cairo_scale(cr, scale, scale);
	cairo_set_source_surface(cr, img_surface, 0, 0);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);
	cairo_surface_destroy(img_surface);
	cairo_surface_flush(surface);

	/* Create wlr_buffer */
	struct wlr_buffer *buffer = drawable_create_buffer_from_data(
		scr_width, scr_height,
		cairo_image_surface_get_data(surface),
		cairo_image_surface_get_stride(surface)
	);
	if (!buffer) {
		cairo_surface_destroy(surface);
		return false;
	}

	/* Create scene node at screen position (hidden) */
	struct wlr_scene_buffer *scene_node = wlr_scene_buffer_create(layers[0], buffer);
	if (!scene_node) {
		wlr_buffer_drop(buffer);
		cairo_surface_destroy(surface);
		return false;
	}
	wlr_scene_node_set_position(&scene_node->node, scr_x, scr_y);
	wlr_scene_node_set_enabled(&scene_node->node, false);
	wlr_buffer_drop(buffer);

	/* Evict oldest if needed */
	wallpaper_cache_evict_oldest();

	/* Add to cache */
	wallpaper_cache_entry_t *entry = calloc(1, sizeof(*entry));
	if (!entry) {
		wlr_scene_node_destroy(&scene_node->node);
		cairo_surface_destroy(surface);
		return false;
	}
	entry->path = strdup(path);
	entry->screen_index = screen_index;
	entry->scene_node = scene_node;
	entry->surface = surface;
	wl_list_insert(&globalconf.wallpaper_cache, &entry->link);

	return true;
}

/** root.wallpaper_cache_preload(paths, screen) - Preload wallpapers into cache
 * \param paths Array of file paths to preload
 * \param screen Screen object or index (1-based). If omitted, preloads for primary screen.
 * \return Number of successfully preloaded wallpapers
 */
static int
luaA_root_wallpaper_cache_preload(lua_State *L)
{
	luaA_checktable(L, 1);

	/* Get screen index (default to primary/screen 0) */
	int screen_index = 0;
	if (lua_gettop(L) >= 2) {
		if (lua_isnumber(L, 2)) {
			screen_index = (int)lua_tointeger(L, 2) - 1;  /* Lua is 1-based */
		} else {
			screen_t *screen = luaA_toscreen(L, 2);
			if (screen)
				screen_index = screen->index - 1;
		}
	}

	int count = 0;
	lua_pushnil(L);
	while (lua_next(L, 1) != 0) {
		if (lua_isstring(L, -1)) {
			const char *path = lua_tostring(L, -1);
			if (wallpaper_cache_preload_path(path, screen_index))
				count++;
		}
		lua_pop(L, 1);
	}

	lua_pushinteger(L, count);
	return 1;
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
	/* somewm extensions for wallpaper caching (Issue #214)
	 * TODO(2.x): Move to dedicated wallpaper.c or compositor/texture_cache.c */
	{ "wallpaper_cache_has", luaA_root_wallpaper_cache_has },
	{ "wallpaper_cache_show", luaA_root_wallpaper_cache_show },
	{ "wallpaper_cache_clear", luaA_root_wallpaper_cache_clear },
	{ "wallpaper_cache_preload", luaA_root_wallpaper_cache_preload },
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
