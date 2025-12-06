/* TODO: Rename this module to something better than "awesome"
 * Options: somewm, core, compositor
 * Current name chosen for AwesomeWM API compatibility
 */

#include "awesome.h"
#include "luaa.h"
#include "signal.h"
#include "spawn.h"
#include "../somewm_api.h"
#include "../draw.h"  /* Must be before globalconf.h to avoid type conflicts */
#include "../globalconf.h"
#include <stdio.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

/* External functions */
extern void wlr_log_init(int verbosity, void *callback);

/* Forward declarations */
static int luaA_awesome_index(lua_State *L);

/** awesome.xrdb_get_value(resource_class, resource_name) - Get xrdb value
 * Delegates to Lua implementation for xrdb compatibility in Wayland.
 * This is a minimal stub that calls gears.xresources.get_value()
 * \param resource_class Resource class (usually empty string)
 * \param resource_name Resource name (e.g., "background", "Xft.dpi")
 * \return Resource value string or nil if not found
 */
static int
luaA_awesome_xrdb_get_value(lua_State *L)
{
	const char *resource_class;
	const char *resource_name;

	/* Parse arguments - AwesomeWM uses (class, name) */
	resource_class = luaL_optstring(L, 1, "");
	resource_name = luaL_checkstring(L, 2);

	/* Delegate to Lua implementation in gears.xresources */
	lua_getglobal(L, "require");
	lua_pushstring(L, "gears.xresources");
	lua_call(L, 1, 1);  /* require("gears.xresources") */

	/* Call get_value method */
	lua_getfield(L, -1, "get_value");
	lua_pushstring(L, resource_class);
	lua_pushstring(L, resource_name);
	lua_call(L, 2, 1);  /* xresources.get_value(class, name) */

	/* The return value is already on the stack */
	return 1;
}

/** awesome.quit() - Quit the compositor
 */
static int
luaA_awesome_quit(lua_State *L)
{
	some_compositor_quit();
	return 0;
}

/** awesome.new_client_placement - Get/set new client placement mode
 * Controls where new clients are placed in the tiling order.
 * 0 = master (new clients become master), 1 = slave (new clients become slaves)
 * When called with no arguments, returns current placement mode.
 * When called with a number or string, sets the placement mode.
 * \param placement Optional: 0/"master" for master placement, 1/"slave" for slave placement
 * \return Current placement mode (if getting): 0 for master, 1 for slave
 */
static int
luaA_awesome_new_client_placement(lua_State *L)
{
	if (lua_gettop(L) >= 1) {
		/* Set mode */
		int placement = 0;
		if (lua_isnumber(L, 1)) {
			placement = (int)lua_tonumber(L, 1);
		} else if (lua_isstring(L, 1)) {
			const char *str = lua_tostring(L, 1);
			if (strcmp(str, "slave") == 0) {
				placement = 1;
			} else if (strcmp(str, "master") == 0) {
				placement = 0;
			}
		}
		some_set_new_client_placement(placement);
		return 0;
	}
	/* Get mode */
	lua_pushnumber(L, some_get_new_client_placement());
	return 1;
}

/** awesome.get_cursor_position() - Get current cursor position
 * \return Table {x=double, y=double} with cursor coordinates
 */
static int
luaA_awesome_get_cursor_position(lua_State *L)
{
	double x, y;

	some_get_cursor_position(&x, &y);

	lua_newtable(L);
	lua_pushnumber(L, x);
	lua_setfield(L, -2, "x");
	lua_pushnumber(L, y);
	lua_setfield(L, -2, "y");
	return 1;
}

/** awesome.get_cursor_monitor() - Get monitor under cursor
 * \return Monitor userdata (lightuserdata) or nil
 */
static int
luaA_awesome_get_cursor_monitor(lua_State *L)
{
	Monitor *m = some_monitor_at_cursor();

	if (m)
		lua_pushlightuserdata(L, m);
	else
		lua_pushnil(L);
	return 1;
}

/** awesome.connect_signal(name, callback) - Connect to a global signal
 * Delegates to the signal module for AwesomeWM API compatibility
 * \param name Signal name (string)
 * \param callback Lua function to call when signal is emitted
 */
static int
luaA_awesome_connect_signal(lua_State *L)
{
	lua_getglobal(L, "signal");
	lua_getfield(L, -1, "connect");
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_call(L, 2, 0);
	lua_pop(L, 1);
	return 0;
}

/** awesome.disconnect_signal(name, callback) - Disconnect from a global signal
 * Delegates to the signal module for AwesomeWM API compatibility
 * \param name Signal name (string)
 * \param callback Lua function to disconnect
 */
static int
luaA_awesome_disconnect_signal(lua_State *L)
{
	lua_getglobal(L, "signal");
	lua_getfield(L, -1, "disconnect");
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_call(L, 2, 0);
	lua_pop(L, 1);
	return 0;
}

/** awesome.emit_signal(name, ...) - Emit a global signal
 * Delegates to the signal module for AwesomeWM API compatibility
 * \param name Signal name (string)
 * \param ... Arguments to pass to callbacks
 */
static int
luaA_awesome_emit_signal(lua_State *L)
{
	int nargs = lua_gettop(L);

	lua_getglobal(L, "signal");
	lua_getfield(L, -1, "emit");
	for (int i = 1; i <= nargs; i++) {
		lua_pushvalue(L, i);
	}
	lua_call(L, nargs, 0);
	lua_pop(L, 1);
	return 0;
}

/** awesome._get_key_name(keysym) - Get human-readable key name
 * Translates XKB keysym to name string for AwesomeWM compatibility
 * \param keysym XKB keysym (number or string)
 * \return[1] string keysym The keysym name
 * \return[1] nil keysym If no valid keysym is found
 * \return[2] string printsymbol The UTF-8 representation
 * \return[2] nil printsymbol If the keysym has no printable representation
 */
static int
luaA_awesome_get_key_name(lua_State *L)
{
	xkb_keysym_t keysym;
	char keysym_name[64];
	char utf8[8] = {0};

	/* Accept either number (keysym) or string (key name) */
	if (lua_isnumber(L, 1)) {
		keysym = (xkb_keysym_t)lua_tonumber(L, 1);
	} else if (lua_isstring(L, 1)) {
		const char *key_str = lua_tostring(L, 1);
		keysym = xkb_keysym_from_name(key_str, XKB_KEYSYM_CASE_INSENSITIVE);
		if (keysym == XKB_KEY_NoSymbol) {
			/* Return nil, nil for invalid keysym */
			lua_pushnil(L);
			lua_pushnil(L);
			return 2;
		}
	} else {
		/* Return nil, nil for invalid input */
		lua_pushnil(L);
		lua_pushnil(L);
		return 2;
	}

	/* Get the keysym name */
	xkb_keysym_get_name(keysym, keysym_name, sizeof(keysym_name));

	/* Push the keysym name as first return value */
	lua_pushstring(L, keysym_name);

	/* Try to get UTF-8 representation as second return value */
	if (xkb_keysym_to_utf8(keysym, utf8, sizeof(utf8)) > 0 && utf8[0]) {
		lua_pushstring(L, utf8);
	} else {
		lua_pushnil(L);
	}

	return 2;  /* Return two values */
}

/** awesome.xkb_get_group_names() - Get keyboard layout group names
 * Stub implementation for AwesomeWM compatibility.
 * Returns a simple default layout (US English).
 * \return String of layout names (comma-separated)
 */
static int
luaA_awesome_xkb_get_group_names(lua_State *L)
{
	/* TODO: Implement actual keyboard layout detection
	 * For now, return a default US layout to prevent crashes */
	lua_pushstring(L, "English (US)");
	return 1;
}

/** awesome.register_xproperty() - Register X property for client persistence
 * Stub implementation for AwesomeWM compatibility.
 * In AwesomeWM this registers X11 properties that persist across restarts.
 * For Wayland we don't have X properties, so this is a no-op stub.
 * TODO: Implement Wayland-native persistence (maybe via desktop files or state files)
 * \param property_name The property name to register
 * \param property_type The type: "string", "number", or "boolean"
 * \return Returns nothing
 */
static int
luaA_awesome_register_xproperty(lua_State *L)
{
	/* Validate arguments for compatibility */
	luaL_checkstring(L, 1);  /* property name */
	luaL_checkstring(L, 2);  /* property type */

	/* TODO: Implement Wayland-native persistence mechanism
	 * For now, this is a silent no-op to allow awful.client to load */
	return 0;
}

/** awesome.pixbuf_to_surface() - Convert GdkPixbuf to cairo surface
 * Translates a GdkPixbuf (from LGI) to a cairo image surface.
 * This is used by gears.surface when loading image files via GdkPixbuf.
 * \param pixbuf The GdkPixbuf as a light userdata (from GdkPixbuf._native)
 * \param path The pixbuf origin path (for error messages, unused)
 * \return Cairo surface as light userdata (or nil + error message)
 */
static int
luaA_pixbuf_to_surface(lua_State *L)
{
	GdkPixbuf *pixbuf = (GdkPixbuf *) lua_touserdata(L, 1);
	cairo_surface_t *surface;

	if (!pixbuf) {
		lua_pushnil(L);
		lua_pushstring(L, "Invalid pixbuf (expected light userdata)");
		return 2;
	}

	surface = draw_surface_from_pixbuf(pixbuf);
	if (!surface) {
		lua_pushnil(L);
		lua_pushstring(L, "Failed to create cairo surface from pixbuf");
		return 2;
	}

	/* Lua must free this ref via cairo.Surface or we have a leak */
	lua_pushlightuserdata(L, surface);
	return 1;
}

/** Rebuild keyboard keymap with current XKB settings
 * Called after changing xkb_layout, xkb_variant, or xkb_options
 */
static void
rebuild_keyboard_keymap(void)
{
	/* TODO: Implement keymap rebuild - needs access to keyboard group
	 * For now, changes take effect on next keyboard device init */
}

/* awesome module methods */
static const luaL_Reg awesome_methods[] = {
	{ "quit", luaA_awesome_quit },
	{ "spawn", luaA_spawn },
	{ "new_client_placement", luaA_awesome_new_client_placement },
	{ "get_cursor_position", luaA_awesome_get_cursor_position },
	{ "get_cursor_monitor", luaA_awesome_get_cursor_monitor },
	{ "connect_signal", luaA_awesome_connect_signal },
	{ "disconnect_signal", luaA_awesome_disconnect_signal },
	{ "emit_signal", luaA_awesome_emit_signal },
	{ "_get_key_name", luaA_awesome_get_key_name },
	{ "xkb_get_group_names", luaA_awesome_xkb_get_group_names },
	{ "xrdb_get_value", luaA_awesome_xrdb_get_value },
	{ "register_xproperty", luaA_awesome_register_xproperty },
	{ "pixbuf_to_surface", luaA_pixbuf_to_surface },
	{ NULL, NULL }
};

/** awesome.__index handler for property access
 * Handles: startup_errors, keyboard settings, input settings
 * (AwesomeWM-compatible pattern)
 */
static int
luaA_awesome_index(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	if (A_STREQ(key, "startup_errors")) {
		/* Return nil if no errors, otherwise return error string */
		if (globalconf.startup_errors.len == 0)
			return 0;  /* Return nothing (nil) */
		lua_pushstring(L, globalconf.startup_errors.s);
		return 1;
	}

	/* Keyboard properties */
	if (A_STREQ(key, "xkb_layout")) {
		lua_pushstring(L, globalconf.keyboard.xkb_layout ? globalconf.keyboard.xkb_layout : "");
		return 1;
	}
	if (A_STREQ(key, "xkb_variant")) {
		lua_pushstring(L, globalconf.keyboard.xkb_variant ? globalconf.keyboard.xkb_variant : "");
		return 1;
	}
	if (A_STREQ(key, "xkb_options")) {
		lua_pushstring(L, globalconf.keyboard.xkb_options ? globalconf.keyboard.xkb_options : "");
		return 1;
	}
	if (A_STREQ(key, "keyboard_repeat_rate")) {
		lua_pushinteger(L, globalconf.keyboard.repeat_rate);
		return 1;
	}
	if (A_STREQ(key, "keyboard_repeat_delay")) {
		lua_pushinteger(L, globalconf.keyboard.repeat_delay);
		return 1;
	}

	/* Input device properties */
	if (A_STREQ(key, "input_tap_to_click")) {
		lua_pushinteger(L, globalconf.input.tap_to_click);
		return 1;
	}
	if (A_STREQ(key, "input_tap_and_drag")) {
		lua_pushinteger(L, globalconf.input.tap_and_drag);
		return 1;
	}
	if (A_STREQ(key, "input_drag_lock")) {
		lua_pushinteger(L, globalconf.input.drag_lock);
		return 1;
	}
	if (A_STREQ(key, "input_natural_scrolling")) {
		lua_pushinteger(L, globalconf.input.natural_scrolling);
		return 1;
	}
	if (A_STREQ(key, "input_disable_while_typing")) {
		lua_pushinteger(L, globalconf.input.disable_while_typing);
		return 1;
	}
	if (A_STREQ(key, "input_left_handed")) {
		lua_pushinteger(L, globalconf.input.left_handed);
		return 1;
	}
	if (A_STREQ(key, "input_middle_button_emulation")) {
		lua_pushinteger(L, globalconf.input.middle_button_emulation);
		return 1;
	}
	if (A_STREQ(key, "input_scroll_method")) {
		lua_pushstring(L, globalconf.input.scroll_method ? globalconf.input.scroll_method : "");
		return 1;
	}
	if (A_STREQ(key, "input_click_method")) {
		lua_pushstring(L, globalconf.input.click_method ? globalconf.input.click_method : "");
		return 1;
	}
	if (A_STREQ(key, "input_send_events_mode")) {
		lua_pushstring(L, globalconf.input.send_events_mode ? globalconf.input.send_events_mode : "");
		return 1;
	}
	if (A_STREQ(key, "input_accel_profile")) {
		lua_pushstring(L, globalconf.input.accel_profile ? globalconf.input.accel_profile : "");
		return 1;
	}
	if (A_STREQ(key, "input_accel_speed")) {
		lua_pushnumber(L, globalconf.input.accel_speed);
		return 1;
	}
	if (A_STREQ(key, "input_tap_button_map")) {
		lua_pushstring(L, globalconf.input.tap_button_map ? globalconf.input.tap_button_map : "");
		return 1;
	}

	/* Logging properties */
	if (A_STREQ(key, "log_level")) {
		/* Convert int enum to string */
		const char *level_str = "error";  /* Default */
		switch (globalconf.log_level) {
			case 0: level_str = "silent"; break;  /* WLR_SILENT */
			case 1: level_str = "error"; break;   /* WLR_ERROR */
			case 2: level_str = "info"; break;    /* WLR_INFO */
			case 3: level_str = "debug"; break;   /* WLR_DEBUG */
		}
		lua_pushstring(L, level_str);
		return 1;
	}

	/* Compositor behavior properties */
	if (A_STREQ(key, "bypass_surface_visibility")) {
		lua_pushboolean(L, globalconf.appearance.bypass_surface_visibility);
		return 1;
	}

	/* For other keys, do regular table lookup */
	lua_rawget(L, 1);
	return 1;
}

/** awesome.__newindex handler for property setting
 * Handles: keyboard settings, input settings
 */
static int
luaA_awesome_newindex(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	/* Keyboard properties */
	if (A_STREQ(key, "xkb_layout")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.keyboard.xkb_layout);
		globalconf.keyboard.xkb_layout = val ? strdup(val) : NULL;
		rebuild_keyboard_keymap();
		return 0;
	}
	if (A_STREQ(key, "xkb_variant")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.keyboard.xkb_variant);
		globalconf.keyboard.xkb_variant = val ? strdup(val) : NULL;
		rebuild_keyboard_keymap();
		return 0;
	}
	if (A_STREQ(key, "xkb_options")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.keyboard.xkb_options);
		globalconf.keyboard.xkb_options = val ? strdup(val) : NULL;
		rebuild_keyboard_keymap();
		return 0;
	}
	if (A_STREQ(key, "keyboard_repeat_rate")) {
		globalconf.keyboard.repeat_rate = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "keyboard_repeat_delay")) {
		globalconf.keyboard.repeat_delay = luaL_checkinteger(L, 3);
		return 0;
	}

	/* Input device properties */
	if (A_STREQ(key, "input_tap_to_click")) {
		globalconf.input.tap_to_click = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_tap_and_drag")) {
		globalconf.input.tap_and_drag = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_drag_lock")) {
		globalconf.input.drag_lock = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_natural_scrolling")) {
		globalconf.input.natural_scrolling = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_disable_while_typing")) {
		globalconf.input.disable_while_typing = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_left_handed")) {
		globalconf.input.left_handed = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_middle_button_emulation")) {
		globalconf.input.middle_button_emulation = luaL_checkinteger(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_scroll_method")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.input.scroll_method);
		globalconf.input.scroll_method = val ? strdup(val) : NULL;
		return 0;
	}
	if (A_STREQ(key, "input_click_method")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.input.click_method);
		globalconf.input.click_method = val ? strdup(val) : NULL;
		return 0;
	}
	if (A_STREQ(key, "input_send_events_mode")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.input.send_events_mode);
		globalconf.input.send_events_mode = val ? strdup(val) : NULL;
		return 0;
	}
	if (A_STREQ(key, "input_accel_profile")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.input.accel_profile);
		globalconf.input.accel_profile = val ? strdup(val) : NULL;
		return 0;
	}
	if (A_STREQ(key, "input_accel_speed")) {
		globalconf.input.accel_speed = luaL_checknumber(L, 3);
		return 0;
	}
	if (A_STREQ(key, "input_tap_button_map")) {
		const char *val = luaL_checkstring(L, 3);
		free(globalconf.input.tap_button_map);
		globalconf.input.tap_button_map = val ? strdup(val) : NULL;
		return 0;
	}

	/* Logging properties */
	if (A_STREQ(key, "log_level")) {
		const char *val = luaL_checkstring(L, 3);
		int new_level = 1;  /* WLR_ERROR default */

		/* Convert string to wlroots log level enum */
		if (strcmp(val, "silent") == 0)      new_level = 0;  /* WLR_SILENT */
		else if (strcmp(val, "error") == 0)  new_level = 1;  /* WLR_ERROR */
		else if (strcmp(val, "info") == 0)   new_level = 2;  /* WLR_INFO */
		else if (strcmp(val, "debug") == 0)  new_level = 3;  /* WLR_DEBUG */

		globalconf.log_level = new_level;

		/* Apply new log level immediately */
		wlr_log_init(new_level, NULL);

		return 0;
	}

	/* Compositor behavior properties */
	if (A_STREQ(key, "bypass_surface_visibility")) {
		globalconf.appearance.bypass_surface_visibility = lua_toboolean(L, 3);
		return 0;
	}

	/* For other keys, do regular table set */
	lua_rawset(L, 1);
	return 0;
}

/** Setup the awesome Lua module
 * Registers the global 'awesome' table with compositor functions
 */
void
luaA_awesome_setup(lua_State *L)
{
	luaA_openlib(L, "awesome", awesome_methods, NULL);

	/* Set metatable for property access (AwesomeWM pattern) */
	lua_getglobal(L, "awesome");
	lua_newtable(L);  /* metatable */
	lua_pushcfunction(L, luaA_awesome_index);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, luaA_awesome_newindex);
	lua_setfield(L, -2, "__newindex");
	lua_setmetatable(L, -2);
	lua_pop(L, 1);  /* pop awesome table */

	/* Set up awesome._modifiers table for AwesomeWM compatibility
	 * Maps modifier names to XKB keysyms
	 * Format: { Shift = {{keysym=0xffe1}}, Control = {{keysym=0xffe3}}, ... }
	 */
	lua_getglobal(L, "awesome");

	lua_newtable(L);  /* _modifiers table */

	/* Shift modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe1);  /* XKB_KEY_Shift_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Shift");

	/* Control modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe3);  /* XKB_KEY_Control_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Control");

	/* Mod1 (Alt) modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe9);  /* XKB_KEY_Alt_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod1");

	/* Mod4 (Super/Logo) modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffeb);  /* XKB_KEY_Super_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod4");

	/* Mod5 modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xfe03);  /* XKB_KEY_ISO_Level3_Shift */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod5");

	lua_setfield(L, -2, "_modifiers");

	/* awesome._active_modifiers - initially empty, will be updated by C code
	 * This is a read-only property that returns currently pressed modifiers
	 */
	lua_newtable(L);
	lua_setfield(L, -2, "_active_modifiers");

	/* awesome.api_level - AwesomeWM API compatibility level
	 * Version 5+ enables properties by default on widgets
	 */
	lua_pushnumber(L, 5);
	lua_setfield(L, -2, "api_level");

	/* awesome.composite_manager_running - indicates if compositing is active
	 * Always true for a Wayland compositor (we are the compositor)
	 */
	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "composite_manager_running");

	/* awesome.themes_path - path to theme directory
	 * Used by gears.filesystem.get_themes_dir()
	 * NOTE: Do NOT include trailing slash - Lua adds it
	 * Using AwesomeWM's themes directly for 100% compatibility
	 */
	lua_pushstring(L, "/home/jimmy/tools/awesome/themes");
	lua_setfield(L, -2, "themes_path");

	/* awesome.conffile - path to loaded config file
	 * Would be set to actual loaded config path, for now use placeholder
	 */
	lua_pushstring(L, "");
	lua_setfield(L, -2, "conffile");

	/* awesome.startup_errors - accumulated errors during startup
	 * AwesomeWM compatibility: errors are accumulated in buffer during config load
	 * and exposed to Lua for display via naughty notifications
	 */
	if (globalconf.startup_errors.len > 0) {
		lua_pushlstring(L, globalconf.startup_errors.s, globalconf.startup_errors.len);
	} else {
		lua_pushnil(L);
	}
	lua_setfield(L, -2, "startup_errors");

	lua_pop(L, 1);  /* pop awesome table */
}

/** Set the conffile path in awesome.conffile
 * Called after successfully loading a config file
 * \param L Lua state
 * \param conffile Path to the loaded config file
 */
void
luaA_awesome_set_conffile(lua_State *L, const char *conffile)
{
	lua_getglobal(L, "awesome");
	lua_pushstring(L, conffile);
	lua_setfield(L, -2, "conffile");
	lua_pop(L, 1);  /* pop awesome table */
}
