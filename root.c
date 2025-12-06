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
#include "objects/luaa.h"
#include "common/luaobject.h"
#include "common/lualib.h"
#include "objects/keybinding.h"
#include "objects/key.h"
#include "objects/button.h"
#include "somewm_api.h"
#include "globalconf.h"
#include "objects/drawable.h"
#include <xkbcommon/xkbcommon.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <cairo.h>

/* External references to somewm.c globals */
extern struct wlr_output_layout *output_layout;
extern struct wlr_scene_tree *layers[];

/* Property miss handlers (AwesomeWM compatibility) */
static int miss_index_handler = LUA_REFNIL;
static int miss_newindex_handler = LUA_REFNIL;

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
	fprintf(stderr, "[ROOT_APPEND_KEY] DEPRECATED: This function is a hack and should not be called.\n");
	fprintf(stderr, "[ROOT_APPEND_KEY] Use awful.keyboard.append_global_keybindings() instead.\n");
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
	int i, j, count = 0;
	size_t len;
	keyb_t *key;
	char keysym_name[64];

	fprintf(stderr, "[ROOT._APPEND_KEYS] Appending keybindings\n");

	if (!lua_istable(L, 1)) {
		fprintf(stderr, "[ROOT._APPEND_KEYS] ERROR: Expected table, got %s\n",
		        lua_typename(L, lua_type(L, 1)));
		return 0;
	}

	/* Check array length */
	len = luaA_rawlen(L, 1);
	fprintf(stderr, "[ROOT._APPEND_KEYS] Table length: %zu\n", len);
	fflush(stderr);

	/* Iterate using integer indices - more reliable than lua_next for arrays */
	for (i = 1; i <= (int)len && i <= 100; i++) {
		fprintf(stderr, "[ROOT._APPEND_KEYS] === ENTERING ITERATION %d (len=%zu) ===\n", i, len);
		fprintf(stderr, "[ROOT._APPEND_KEYS] Stack size before rawgeti: %d\n", lua_gettop(L));
		fprintf(stderr, "[ROOT._APPEND_KEYS] Type at index 1: %s\n", lua_typename(L, lua_type(L, 1)));
		fflush(stderr);

		lua_rawgeti(L, 1, i);  /* Get table[i] */
		fprintf(stderr, "[ROOT._APPEND_KEYS] After lua_rawgeti(%d), stack top type: %s, stack size: %d\n",
		        i, lua_typename(L, lua_type(L, -1)), lua_gettop(L));
		fflush(stderr);

		fprintf(stderr, "[ROOT._APPEND_KEYS] Index %d: type=%s\n",
		        i, lua_typename(L, lua_type(L, -1)));
		fflush(stderr);

		/* Check if this is a C key object directly */
		key = luaA_toudata(L, -1, &key_class);
		if (key) {
			/* luaA_object_ref REMOVES the object from stack, so no lua_pop needed */
			key_array_append(&globalconf.keys, luaA_object_ref(L, -1));

			xkb_keysym_get_name(key->keysym, keysym_name, sizeof(keysym_name));
			fprintf(stderr, "[ROOT._APPEND_KEYS] Adding key %d: mods=0x%04x keysym=%s (%u)\n",
			        ++count, key->modifiers, keysym_name, key->keysym);
			/* Stack is now back to just [table] - object was consumed by luaA_object_ref */
			continue;  /* Skip the lua_pop(L, 1) at the end since object already removed */
		}
		/* Or check if it's a table containing key objects */
		else if (lua_istable(L, -1)) {
			fprintf(stderr, "[ROOT._APPEND_KEYS] Index %d is a table, iterating its contents\n", i);
			fflush(stderr);
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

					xkb_keysym_get_name(key->keysym, keysym_name, sizeof(keysym_name));
					fprintf(stderr, "[ROOT._APPEND_KEYS] Adding key %d: mods=0x%04x keysym=%s\n",
					        ++count, key->modifiers, keysym_name);
					/* Object already removed by luaA_object_ref, no pop needed */
				} else {
					/* Not a key object, pop it */
					lua_pop(L, 1);
				}
			}
		} else {
			fprintf(stderr, "[ROOT._APPEND_KEYS] WARNING: Index %d is unknown type, skipping\n", i);
		}
		fprintf(stderr, "[ROOT._APPEND_KEYS] About to pop stack for index %d (stack size: %d)\n", i, lua_gettop(L));
		fflush(stderr);
		lua_pop(L, 1);  /* Pop table[i] */
		fprintf(stderr, "[ROOT._APPEND_KEYS] Stack popped successfully (new stack size: %d)\n", lua_gettop(L));
		fprintf(stderr, "[ROOT._APPEND_KEYS] Type at index 1 after pop: %s\n", lua_typename(L, lua_type(L, 1)));
		fflush(stderr);
		fprintf(stderr, "[ROOT._APPEND_KEYS] Completed index %d, continuing to next (i will become %d)\n", i, i+1);
		fflush(stderr);
	}
	fprintf(stderr, "[ROOT._APPEND_KEYS] === EXITED LOOP === Final i=%d, len=%zu\n", i, len);
	fflush(stderr);
	fprintf(stderr, "[ROOT._APPEND_KEYS] Loop completed, processed %d indices\n", i-1);
	fflush(stderr);

	fprintf(stderr, "[ROOT._APPEND_KEYS] Appended %d keys (total now: %d keys)\n",
	        count, globalconf.keys.len);
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
		int count = 0;
		int i;
		int idx;
		int found_c_objects;
		char keysym_name[64];

		fprintf(stderr, "[ROOT._KEYS] Setting global keybindings\n");
		fflush(stderr);

		/* Unref all existing key objects */
		for (i = 0; i < globalconf.keys.len; i++) {
			luaA_object_unref(L, globalconf.keys.tab[i]);
			fprintf(stderr, "[ROOT._KEYS] Unref old key %d\n", i);
		}

		/* Clear the array */
		key_array_wipe(&globalconf.keys);
		key_array_init(&globalconf.keys);

		/* Add new key objects from the table
		 * Use lua_next() iteration like AwesomeWM to handle all table types correctly */
		fprintf(stderr, "[ROOT._KEYS] Iterating table with lua_next(), initial stack size=%d\n",
		        lua_gettop(L));
		fflush(stderr);

		/* lua_next() iteration: push nil as first key, then iterate */
		lua_pushnil(L);  /* First key for lua_next */
		while (lua_next(L, 1)) {
			/* Stack now: [table, key, value] */
			/* key is at index -2, value is at index -1 */

			fprintf(stderr, "[ROOT._KEYS] lua_next() returned entry, key_type=%s, value_type=%s, stack size=%d\n",
			        lua_typename(L, lua_type(L, -2)),
			        lua_typename(L, lua_type(L, -1)),
			        lua_gettop(L));
			fflush(stderr);

			/* Log the key index if it's a number */
			if (lua_type(L, -2) == LUA_TNUMBER) {
				fprintf(stderr, "[ROOT._KEYS]   Key index: %d\n", (int)lua_tointeger(L, -2));
				fflush(stderr);
			}

			/* Check if this is a C key object */
			if (luaA_toudata(L, -1, &key_class)) {
				keyb_t *key = luaA_checkudata(L, -1, &key_class);

				xkb_keysym_get_name(key->keysym, keysym_name, sizeof(keysym_name));
				fprintf(stderr, "[ROOT._KEYS]   ✓ C key object: mods=0x%04x keysym=%s (%u) keycode=%u\n",
				        key->modifiers, keysym_name, key->keysym, key->keycode);
				fflush(stderr);

				/* luaA_object_ref REMOVES the object from stack.
				 * After this, stack will be [table, key] which is perfect for lua_next */
				key_array_append(&globalconf.keys, luaA_object_ref(L, -1));
				count++;
				/* Object already removed by luaA_object_ref, stack is [table, key] - ready for next iteration */
			} else if (lua_type(L, -1) == LUA_TTABLE) {
				/* Might be an awful.key wrapper table - check for C objects at integer indices */
				fprintf(stderr, "[ROOT._KEYS]   ✗ Lua table (possible awful.key wrapper) - checking for C objects at integer indices...\n");
				fflush(stderr);

				found_c_objects = 0;
				for (idx = 1; idx <= 100; idx++) {
					lua_rawgeti(L, -1, idx);  /* Get table[idx] */
					if (lua_isnil(L, -1)) {
						lua_pop(L, 1);
						break;
					}

					if (luaA_toudata(L, -1, &key_class)) {
						keyb_t *key = luaA_checkudata(L, -1, &key_class);
						xkb_keysym_get_name(key->keysym, keysym_name, sizeof(keysym_name));
						fprintf(stderr, "[ROOT._KEYS]     Found C object at [%d]: mods=0x%04x keysym=%s (%u) keycode=%u\n",
						        idx, key->modifiers, keysym_name, key->keysym, key->keycode);
						fflush(stderr);

						/* Ref and append this C object */
						key_array_append(&globalconf.keys, luaA_object_ref(L, -1));
						count++;
						found_c_objects++;
						/* Object removed by ref, continue */
					} else {
						lua_pop(L, 1);  /* Not a C object, pop it */
					}
				}

				if (found_c_objects == 0) {
					fprintf(stderr, "[ROOT._KEYS]     WARNING: Table has no C key objects at integer indices!\n");
					fflush(stderr);
				}

				/* Pop the awful.key wrapper table, leave key for lua_next */
				lua_pop(L, 1);
			} else {
				fprintf(stderr, "[ROOT._KEYS]   ✗ Unexpected type=%s, skipping\n",
				        lua_typename(L, lua_type(L, -1)));
				fflush(stderr);
				/* Not a key object - pop the value, leave key for lua_next */
				lua_pop(L, 1);
				/* Stack is now [table, key] - ready for next iteration */
			}
			/* lua_next will pop the key and push the next key-value pair */
		}
		/* lua_next returns 0 when done and has already popped the last key */

		fprintf(stderr, "[ROOT._KEYS] Loop completed\n");
		fflush(stderr);
		fprintf(stderr, "[ROOT._KEYS] Registration complete: %d keys stored in globalconf.keys\n", count);
		fflush(stderr);

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
	fprintf(stderr, "[ROOT._KEYS] Getting global keybindings (%d keys)\n", globalconf.keys.len);
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

	fprintf(stderr, "[ROOT_BUTTON] Checking %d root buttons for button=%u mods=0x%x at (%.1f, %.1f)\n",
	        buttons->len, button, mods, x, y);

	/* Iterate through root button array */
	for (int i = 0; i < buttons->len; i++) {
		button_t *btn = buttons->tab[i];

		/* Match button number (0 = any button) */
		bool button_matches = (btn->button == 0 || btn->button == button);

		/* Match modifiers (0 = any modifiers) */
		bool mods_match = (btn->modifiers == 0 || btn->modifiers == mods);

		if (button_matches && mods_match) {
			fprintf(stderr, "[ROOT_BUTTON] Button %d matched (btn->button=%d btn->modifiers=0x%x)\n",
			        i, btn->button, btn->modifiers);

			/* Push button object */
			luaA_object_push(L, btn);

			/* Emit press/release signal on button object (no args) */
			luaA_awm_object_emit_signal(L, -1, signal_name, 0);

			/* Pop button object */
			lua_pop(L, 1);

			matched++;
		}
	}

	fprintf(stderr, "[ROOT_BUTTON] Matched %d root buttons\n", matched);
	return matched;
}

/** root.fake_input(event_type, detail) - Simulate input events
 *
 * TODO: This requires wlroots virtual input protocol support
 * For now, stub it out for compatibility
 *
 * \param event_type "key_press", "key_release", "button_press", etc.
 * \param detail Key name or button number
 */
static int
luaA_root_fake_input(lua_State *L)
{
	(void)L;
	/* TODO: Implement using wlroots virtual pointer/keyboard
	 * wlr_virtual_keyboard_v1, wlr_virtual_pointer_v1 */
	fprintf(stderr, "WARNING: root.fake_input not yet implemented\n");
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
	/* TODO: Implement cursor changing via wlroots
	 * For now, this is a no-op stub */
	(void)L;
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
	/* TODO: Implement once we track all drawin objects globally
	 * For now, return empty table as placeholder */
	lua_newtable(L);
	return 1;
}

/* ========== WALLPAPER SUPPORT ========== */

/** Set wallpaper buffer in scene graph
 * Helper function that updates the wallpaper scene buffer node.
 * This is the Wayland equivalent of AwesomeWM's root_set_wallpaper_pixmap().
 *
 * \param buffer The wlr_buffer containing wallpaper pixel data
 */
static void
root_set_wallpaper_buffer(struct wlr_buffer *buffer)
{
	/* Clean up old wallpaper scene node */
	if (globalconf.wallpaper_buffer_node) {
		wlr_scene_node_destroy(&globalconf.wallpaper_buffer_node->node);
		globalconf.wallpaper_buffer_node = NULL;
	}

	/* Create scene buffer in LyrBg (layer 0 - wallpaper layer)
	 * This is the Wayland equivalent of xcb_change_window_attributes() */
	globalconf.wallpaper_buffer_node = wlr_scene_buffer_create(layers[0], buffer);
	if (globalconf.wallpaper_buffer_node) {
		wlr_scene_node_set_position(&globalconf.wallpaper_buffer_node->node, 0, 0);
	}
}

/** Set wallpaper from Cairo pattern
 * Mirrors AwesomeWM's root_set_wallpaper() function (root.c:91-156).
 * Converts Cairo pattern to wlroots scene buffer and displays as wallpaper.
 *
 * \param pattern Cairo pattern to use as wallpaper
 * \return true on success, false on error
 */
static bool
root_set_wallpaper(cairo_pattern_t *pattern)
{
	cairo_surface_t *surface = NULL;
	cairo_t *cr = NULL;
	struct wlr_buffer *buffer = NULL;
	bool result = false;
	struct wlr_box layout_box;
	int width, height;

	/* Get virtual screen dimensions (AwesomeWM uses screen->width_in_pixels) */
	wlr_output_layout_get_box(output_layout, NULL, &layout_box);
	width = layout_box.width;
	height = layout_box.height;

	if (width <= 0 || height <= 0)
		goto cleanup;

	/* Create Cairo surface (Wayland equivalent of xcb_create_pixmap) */
	surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		goto cleanup;

	/* Paint pattern to surface - EXACT COPY from AwesomeWM root.c:122-126 */
	cr = cairo_create(surface);
	cairo_set_source(cr, pattern);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);
	cr = NULL;
	cairo_surface_flush(surface);

	/* Create wlr_buffer (reuse existing drawable infrastructure) */
	buffer = drawable_create_buffer_from_data(
		width, height,
		cairo_image_surface_get_data(surface),
		cairo_image_surface_get_stride(surface)
	);
	if (!buffer)
		goto cleanup;

	/* Set as wallpaper via scene graph */
	root_set_wallpaper_buffer(buffer);

	/* Update cached wallpaper - EXACT COPY from AwesomeWM root.c:147-148 */
	cairo_surface_destroy(globalconf.wallpaper);
	globalconf.wallpaper = surface;
	surface = NULL; /* Now owned by globalconf */

	/* Emit signal - EXACT COPY from AwesomeWM root.c:149 */
	luaA_emit_signal_global("wallpaper_changed");

	result = true;

cleanup:
	if (cr) cairo_destroy(cr);
	if (surface) cairo_surface_destroy(surface);
	if (buffer) wlr_buffer_drop(buffer);
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
		lua_pushboolean(L, root_set_wallpaper(pattern));
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

/** __index metamethod for root
 * Handles property access, first checking metatable methods,
 * then delegating to miss handler if set
 */
static int
luaA_root_index(lua_State *L)
{
	/* First, try to get the key from the metatable (where methods are stored) */
	if (luaL_getmetafield(L, 1, lua_tostring(L, 2))) {
		return 1;  /* Found in metatable, return it */
	}

	/* Not in metatable, try miss handler */
	if (miss_index_handler != LUA_REFNIL)
		return luaA_call_handler(L, miss_index_handler);

	/* No handler set - return nil (property doesn't exist) */
	return 0;
}

/** __newindex metamethod for root
 * Handles property assignment, delegating to miss handler if set
 */
static int
luaA_root_newindex(lua_State *L)
{
	if (miss_newindex_handler != LUA_REFNIL)
		return luaA_call_handler(L, miss_newindex_handler);

	/* No handler set - silently ignore (property can't be set) */
	return 0;
}

static const luaL_Reg root_methods[] = {
	/* AwesomeWM-compatible exports (following Prime Directive) */
	{ "_buttons", luaA_root_buttons },
	{ "_keys", luaA_root_keys },
	{ "_wallpaper", luaA_root_wallpaper },
	{ "cursor", luaA_root_cursor },
	{ "fake_input", luaA_root_fake_input },
	{ "drawins", luaA_root_drawins },
	{ "size", luaA_root_size },
	{ "size_mm", luaA_root_size_mm },
	{ "tags", luaA_root_tags },
	{ "set_index_miss_handler", luaA_root_set_index_miss_handler },
	{ "set_newindex_miss_handler", luaA_root_set_newindex_miss_handler },
	/* NOTE: _append_* and _remove_* functions removed - these don't exist in AwesomeWM's C layer.
	 * The Lua layer (awful/root.lua) creates these wrappers itself. */
	{ NULL, NULL }
};

static const luaL_Reg root_meta[] = {
	{ "__index", luaA_root_index },
	{ "__newindex", luaA_root_newindex },
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
