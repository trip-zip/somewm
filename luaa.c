#include "objects/luaa.h"
#include "globalconf.h"
#include "objects/tag.h"
#include "objects/client.h"
#include "objects/screen.h"
#include "objects/drawin.h"
#include "objects/drawable.h"
#include "objects/signal.h"
#include "objects/timer.h"
#include "objects/spawn.h"
#include "objects/key.h"
#include "objects/keybinding.h"
#include "objects/keygrabber.h"
#include "objects/mousegrabber.h"
#include "objects/awesome.h"
#include "objects/wibox.h"
#include "objects/ipc.h"
#include "objects/root.h"
#include "objects/button.h"
#include "objects/mouse.h"
#include "objects/selection_getter.h"
#include "objects/selection_acquire.h"
#include "objects/selection_transfer.h"
#include "objects/selection_watcher.h"
#include "selection.h"
#include "common/luaobject.h"
#include "window.h"
#include "dbus.h"
#include "common/luaclass.h"
#include "common/lualib.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <unistd.h>
#include <sys/stat.h>

/* Legacy global Lua state pointer - now just an alias for globalconf.L */
lua_State *globalconf_L = NULL;

/* Global configuration structure instance */
awesome_t globalconf;

/* X11 atom stubs */
xcb_atom_t WM_TAKE_FOCUS = 0;
xcb_atom_t _NET_STARTUP_ID = 0;
xcb_atom_t WM_DELETE_WINDOW = 0;
xcb_atom_t WM_PROTOCOLS = 0;

#ifdef XWAYLAND
/* EWMH atoms - Extended Window Manager Hints for XWayland compatibility */

/* Root Window Atoms (WM capabilities) */
xcb_atom_t _NET_SUPPORTED = 0;
xcb_atom_t _NET_SUPPORTING_WM_CHECK = 0;
xcb_atom_t _NET_CLIENT_LIST = 0;
xcb_atom_t _NET_CLIENT_LIST_STACKING = 0;
xcb_atom_t _NET_NUMBER_OF_DESKTOPS = 0;
xcb_atom_t _NET_DESKTOP_NAMES = 0;
xcb_atom_t _NET_CURRENT_DESKTOP = 0;
xcb_atom_t _NET_ACTIVE_WINDOW = 0;
xcb_atom_t _NET_CLOSE_WINDOW = 0;
xcb_atom_t _NET_WM_NAME = 0;
xcb_atom_t _NET_WM_VISIBLE_NAME = 0;
xcb_atom_t _NET_WM_ICON_NAME = 0;
xcb_atom_t _NET_WM_VISIBLE_ICON_NAME = 0;
xcb_atom_t _NET_DESKTOP_GEOMETRY = 0;
xcb_atom_t _NET_DESKTOP_VIEWPORT = 0;
xcb_atom_t _NET_WORKAREA = 0;

/* Client Window Atoms (client properties) */
xcb_atom_t _NET_WM_DESKTOP = 0;
xcb_atom_t _NET_WM_STATE = 0;
xcb_atom_t _NET_WM_STATE_STICKY = 0;
xcb_atom_t _NET_WM_STATE_SKIP_TASKBAR = 0;
xcb_atom_t _NET_WM_STATE_FULLSCREEN = 0;
xcb_atom_t _NET_WM_STATE_MAXIMIZED_HORZ = 0;
xcb_atom_t _NET_WM_STATE_MAXIMIZED_VERT = 0;
xcb_atom_t _NET_WM_STATE_ABOVE = 0;
xcb_atom_t _NET_WM_STATE_BELOW = 0;
xcb_atom_t _NET_WM_STATE_MODAL = 0;
xcb_atom_t _NET_WM_STATE_HIDDEN = 0;
xcb_atom_t _NET_WM_STATE_DEMANDS_ATTENTION = 0;

/* Window Type Atoms */
xcb_atom_t _NET_WM_WINDOW_TYPE = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_DESKTOP = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_DOCK = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_TOOLBAR = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_MENU = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_UTILITY = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_SPLASH = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_DIALOG = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_DROPDOWN_MENU = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_POPUP_MENU = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_TOOLTIP = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_NOTIFICATION = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_COMBO = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_DND = 0;
xcb_atom_t _NET_WM_WINDOW_TYPE_NORMAL = 0;

/* Icon & PID Atoms */
xcb_atom_t _NET_WM_ICON = 0;
xcb_atom_t _NET_WM_PID = 0;

/* UTF8_STRING atom for text properties */
xcb_atom_t UTF8_STRING = 0;
#endif /* XWAYLAND */

/* Global handler storage for object property miss handlers */
luaA_class_handlers_t client_handlers = {LUA_REFNIL, LUA_REFNIL};
luaA_class_handlers_t tag_handlers = {LUA_REFNIL, LUA_REFNIL};
luaA_class_handlers_t screen_handlers = {LUA_REFNIL, LUA_REFNIL};
luaA_class_handlers_t mouse_handlers = {LUA_REFNIL, LUA_REFNIL};

/* D-Bus library functions from dbus.c */
extern const struct luaL_Reg awesome_dbus_lib[];

/* Forward declaration */
static int luaA_dofunction_on_error(lua_State *L);

#ifdef XWAYLAND
/** Initialize EWMH atoms (Extended Window Manager Hints).
 * This function interns all 46 EWMH atoms from the X server.
 * Uses the batched cookie pattern from AwesomeWM for efficiency:
 * send all requests first, then collect all replies.
 * \param conn XCB connection to X server (from XWayland)
 */
void
init_ewmh_atoms(xcb_connection_t *conn)
{
	xcb_intern_atom_cookie_t cookies[47];  /* 46 EWMH + 1 UTF8_STRING */
	xcb_intern_atom_reply_t *reply;
	int i;

	if (!conn) return;

	/* Batch all xcb_intern_atom requests first (AwesomeWM pattern) */
	i = 0;

	/* Root Window Atoms (WM capabilities) */
	cookies[i++] = xcb_intern_atom(conn, 0, 13, "_NET_SUPPORTED");
	cookies[i++] = xcb_intern_atom(conn, 0, 25, "_NET_SUPPORTING_WM_CHECK");
	cookies[i++] = xcb_intern_atom(conn, 0, 16, "_NET_CLIENT_LIST");
	cookies[i++] = xcb_intern_atom(conn, 0, 25, "_NET_CLIENT_LIST_STACKING");
	cookies[i++] = xcb_intern_atom(conn, 0, 23, "_NET_NUMBER_OF_DESKTOPS");
	cookies[i++] = xcb_intern_atom(conn, 0, 19, "_NET_DESKTOP_NAMES");
	cookies[i++] = xcb_intern_atom(conn, 0, 21, "_NET_CURRENT_DESKTOP");
	cookies[i++] = xcb_intern_atom(conn, 0, 19, "_NET_ACTIVE_WINDOW");
	cookies[i++] = xcb_intern_atom(conn, 0, 18, "_NET_CLOSE_WINDOW");
	cookies[i++] = xcb_intern_atom(conn, 0, 12, "_NET_WM_NAME");
	cookies[i++] = xcb_intern_atom(conn, 0, 20, "_NET_WM_VISIBLE_NAME");
	cookies[i++] = xcb_intern_atom(conn, 0, 17, "_NET_WM_ICON_NAME");
	cookies[i++] = xcb_intern_atom(conn, 0, 25, "_NET_WM_VISIBLE_ICON_NAME");
	cookies[i++] = xcb_intern_atom(conn, 0, 22, "_NET_DESKTOP_GEOMETRY");
	cookies[i++] = xcb_intern_atom(conn, 0, 22, "_NET_DESKTOP_VIEWPORT");
	cookies[i++] = xcb_intern_atom(conn, 0, 13, "_NET_WORKAREA");

	/* Client Window Atoms (client properties) */
	cookies[i++] = xcb_intern_atom(conn, 0, 15, "_NET_WM_DESKTOP");
	cookies[i++] = xcb_intern_atom(conn, 0, 13, "_NET_WM_STATE");
	cookies[i++] = xcb_intern_atom(conn, 0, 20, "_NET_WM_STATE_STICKY");
	cookies[i++] = xcb_intern_atom(conn, 0, 25, "_NET_WM_STATE_SKIP_TASKBAR");
	cookies[i++] = xcb_intern_atom(conn, 0, 25, "_NET_WM_STATE_FULLSCREEN");
	cookies[i++] = xcb_intern_atom(conn, 0, 29, "_NET_WM_STATE_MAXIMIZED_HORZ");
	cookies[i++] = xcb_intern_atom(conn, 0, 29, "_NET_WM_STATE_MAXIMIZED_VERT");
	cookies[i++] = xcb_intern_atom(conn, 0, 19, "_NET_WM_STATE_ABOVE");
	cookies[i++] = xcb_intern_atom(conn, 0, 19, "_NET_WM_STATE_BELOW");
	cookies[i++] = xcb_intern_atom(conn, 0, 19, "_NET_WM_STATE_MODAL");
	cookies[i++] = xcb_intern_atom(conn, 0, 20, "_NET_WM_STATE_HIDDEN");
	cookies[i++] = xcb_intern_atom(conn, 0, 31, "_NET_WM_STATE_DEMANDS_ATTENTION");

	/* Window Type Atoms */
	cookies[i++] = xcb_intern_atom(conn, 0, 19, "_NET_WM_WINDOW_TYPE");
	cookies[i++] = xcb_intern_atom(conn, 0, 27, "_NET_WM_WINDOW_TYPE_DESKTOP");
	cookies[i++] = xcb_intern_atom(conn, 0, 24, "_NET_WM_WINDOW_TYPE_DOCK");
	cookies[i++] = xcb_intern_atom(conn, 0, 27, "_NET_WM_WINDOW_TYPE_TOOLBAR");
	cookies[i++] = xcb_intern_atom(conn, 0, 24, "_NET_WM_WINDOW_TYPE_MENU");
	cookies[i++] = xcb_intern_atom(conn, 0, 27, "_NET_WM_WINDOW_TYPE_UTILITY");
	cookies[i++] = xcb_intern_atom(conn, 0, 26, "_NET_WM_WINDOW_TYPE_SPLASH");
	cookies[i++] = xcb_intern_atom(conn, 0, 26, "_NET_WM_WINDOW_TYPE_DIALOG");
	cookies[i++] = xcb_intern_atom(conn, 0, 33, "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU");
	cookies[i++] = xcb_intern_atom(conn, 0, 30, "_NET_WM_WINDOW_TYPE_POPUP_MENU");
	cookies[i++] = xcb_intern_atom(conn, 0, 27, "_NET_WM_WINDOW_TYPE_TOOLTIP");
	cookies[i++] = xcb_intern_atom(conn, 0, 32, "_NET_WM_WINDOW_TYPE_NOTIFICATION");
	cookies[i++] = xcb_intern_atom(conn, 0, 25, "_NET_WM_WINDOW_TYPE_COMBO");
	cookies[i++] = xcb_intern_atom(conn, 0, 23, "_NET_WM_WINDOW_TYPE_DND");
	cookies[i++] = xcb_intern_atom(conn, 0, 26, "_NET_WM_WINDOW_TYPE_NORMAL");

	/* Icon & PID Atoms */
	cookies[i++] = xcb_intern_atom(conn, 0, 12, "_NET_WM_ICON");
	cookies[i++] = xcb_intern_atom(conn, 0, 11, "_NET_WM_PID");

	/* UTF8_STRING for text properties */
	cookies[i++] = xcb_intern_atom(conn, 0, 11, "UTF8_STRING");

	/* Now collect all replies (same order as requests) */
	i = 0;

	/* Root Window Atoms */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_SUPPORTED = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_SUPPORTING_WM_CHECK = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_CLIENT_LIST = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_CLIENT_LIST_STACKING = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_NUMBER_OF_DESKTOPS = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_DESKTOP_NAMES = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_CURRENT_DESKTOP = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_ACTIVE_WINDOW = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_CLOSE_WINDOW = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_NAME = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_VISIBLE_NAME = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_ICON_NAME = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_VISIBLE_ICON_NAME = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_DESKTOP_GEOMETRY = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_DESKTOP_VIEWPORT = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WORKAREA = reply->atom; free(reply); }

	/* Client Window Atoms */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_DESKTOP = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_STICKY = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_SKIP_TASKBAR = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_FULLSCREEN = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_MAXIMIZED_HORZ = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_MAXIMIZED_VERT = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_ABOVE = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_BELOW = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_MODAL = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_HIDDEN = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STATE_DEMANDS_ATTENTION = reply->atom; free(reply); }

	/* Window Type Atoms */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_DESKTOP = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_DOCK = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_TOOLBAR = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_MENU = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_UTILITY = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_SPLASH = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_DIALOG = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_DROPDOWN_MENU = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_POPUP_MENU = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_TOOLTIP = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_NOTIFICATION = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_COMBO = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_DND = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_WINDOW_TYPE_NORMAL = reply->atom; free(reply); }

	/* Icon & PID Atoms */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_ICON = reply->atom; free(reply); }
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_PID = reply->atom; free(reply); }

	/* UTF8_STRING */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { UTF8_STRING = reply->atom; free(reply); }

	printf("somewm: Initialized %d EWMH atoms for XWayland support\n", i);
}
#endif /* XWAYLAND */

/** UTF-8 aware string length computing.
 * \param L The Lua VM state.
 * \return The number of elements pushed on stack.
 */
static int
luaA_mbstrlen(lua_State *L)
{
    const char *cmd = luaL_checkstring(L, 1);
    lua_pushinteger(L, (ssize_t) mbstowcs(NULL, cmd ? cmd : "", 0));
    return 1;
}

/** Enhanced type() function which recognizes awesome objects (AwesomeWM pattern).
 * This is critical for the Lua code to differentiate between generic userdata
 * and our custom C objects like button, key, client, etc.
 * \param L The Lua VM state.
 * \return The number of arguments pushed on the stack (1 = typename string).
 */
static int
luaAe_type(lua_State *L)
{
	luaL_checkany(L, 1);
	lua_pushstring(L, luaA_typename(L, 1));
	return 1;
}

/** Add AwesomeWM-compatible Lua extensions.
 * \param L The Lua VM state.
 */
static void
luaA_fixups(lua_State *L)
{
	/* Export string.wlen for UTF-8 aware string length */
	lua_getglobal(L, "string");
	lua_pushcfunction(L, luaA_mbstrlen);
	lua_setfield(L, -2, "wlen");
	lua_pop(L, 1);

	/* Replace type() with enhanced version that recognizes awesome objects.
	 * This is CRITICAL for awful.button/awful.key legacy compatibility.
	 * Without this, type(button_obj) returns "userdata" instead of "button",
	 * breaking the join_if checks in gears.object.properties. */
	lua_pushcfunction(L, luaAe_type);
	lua_setglobal(L, "type");
}

void
luaA_init(void)
{
	const char *cur_path;

	/* Initialize Lua state */
	globalconf_L = luaL_newstate();
	if (!globalconf_L) {
		fprintf(stderr, "somewm: failed to create Lua state\n");
		return;
	}

	/* Initialize globalconf structure */
	globalconf_init(globalconf_L);

	/* Keep globalconf_L in sync with globalconf.L for legacy code */
	globalconf_L = globalconf.L;

	/* Set error handling function */
	lualib_dofunction_on_error = luaA_dofunction_on_error;

	luaL_openlibs(globalconf_L);

	/* Add AwesomeWM-compatible Lua extensions */
	luaA_fixups(globalconf_L);

	printf("somewm: Lua %s initialized successfully\n", LUA_VERSION);

	/* Initialize the AwesomeWM object system (must be done before any class setup) */
	luaA_object_setup(globalconf_L);

	/* Add lua/ directory to package.path for require() support */
	lua_getglobal(globalconf_L, "package");
	lua_getfield(globalconf_L, -1, "path");
	cur_path = lua_tostring(globalconf_L, -1);
	lua_pop(globalconf_L, 1);

	/* Prepend lua paths: development paths first, then system-wide paths */
	lua_pushfstring(globalconf_L,
		"./lua/?.lua;./lua/?/init.lua;./lua/lib/?.lua;./lua/lib/?/init.lua;"
		DATADIR "/somewm/lua/?.lua;" DATADIR "/somewm/lua/?/init.lua;"
		DATADIR "/somewm/lua/lib/?.lua;" DATADIR "/somewm/lua/lib/?/init.lua;%s",
		cur_path);
	lua_setfield(globalconf_L, -2, "path");
	lua_pop(globalconf_L, 1);  /* pop package table */

	/* Add user library directory (~/.local/share/somewm) to package.path
	 * This allows users to install custom Lua libraries that are available
	 * to all their configs (AwesomeWM compatibility) */
	{
		const char *xdg_data_home;
		const char *home;
		const char *old_path;
		char user_data_dir[512];

		xdg_data_home = getenv("XDG_DATA_HOME");
		home = getenv("HOME");

		if (xdg_data_home && xdg_data_home[0] != '\0') {
			snprintf(user_data_dir, sizeof(user_data_dir), "%s/somewm", xdg_data_home);
		} else if (home && home[0] != '\0') {
			snprintf(user_data_dir, sizeof(user_data_dir), "%s/.local/share/somewm", home);
		} else {
			user_data_dir[0] = '\0';  /* No home directory found */
		}

		if (user_data_dir[0] != '\0') {
			lua_getglobal(globalconf_L, "package");
			lua_getfield(globalconf_L, -1, "path");
			old_path = lua_tostring(globalconf_L, -1);
			lua_pop(globalconf_L, 1);

			lua_pushfstring(globalconf_L, "%s/?.lua;%s/?/init.lua;%s",
				user_data_dir, user_data_dir, old_path);
			lua_setfield(globalconf_L, -2, "path");
			lua_pop(globalconf_L, 1);  /* pop package table */
		}
	}

	/* Register somewm Lua modules */
	luaA_signal_setup(globalconf_L);
	key_class_setup(globalconf_L);  /* AwesomeWM key object class */
	tag_class_setup(globalconf_L);
	window_class_setup(globalconf_L);  /* Setup window base class first */
	client_class_setup(globalconf_L);
	screen_class_setup(globalconf_L);
	luaA_drawable_setup(globalconf_L);
	luaA_drawin_setup(globalconf_L);
	luaA_timer_setup(globalconf_L);
	luaA_spawn_setup(globalconf_L);
	luaA_keybinding_setup(globalconf_L);
	luaA_awesome_setup(globalconf_L);
	luaA_root_setup(globalconf_L);
	button_class_setup(globalconf_L); /* Setup button class (AwesomeWM class system) */

	/* Setup selection classes (must be before selection_setup) */
	selection_getter_class_setup(globalconf_L);
	selection_acquire_class_setup(globalconf_L);
	selection_transfer_class_setup(globalconf_L);
	selection_watcher_class_setup(globalconf_L);
	selection_setup(globalconf_L); /* Creates "selection" global from class globals */

	luaA_mouse_setup(globalconf_L);
	luaA_wibox_setup(globalconf_L);
	luaA_ipc_setup(globalconf_L);

	/* Register D-Bus library (AwesomeWM compatibility) */
	luaA_registerlib(globalconf_L, "dbus", awesome_dbus_lib);

	/* Setup keygrabber module (AwesomeWM pattern: global variable) */
	lua_newtable(globalconf_L);  /* Create keygrabber module table */
	luaA_keygrabber_setup(globalconf_L);
	lua_setglobal(globalconf_L, "keygrabber");  /* keygrabber = module */

	/* Setup mousegrabber module (AwesomeWM pattern: global variable) */
	lua_newtable(globalconf_L);  /* Create mousegrabber module table */
	luaA_mousegrabber_setup(globalconf_L);
	lua_setglobal(globalconf_L, "mousegrabber");  /* mousegrabber = module */

	/* NOTE: The C-based key class is now set up by key_class_setup() above (line 88).
	 * The old Lua-based implementation below has been disabled to let the C implementation work.
	 * The C key class provides full AwesomeWM compatibility with proper signal emission
	 * and integration with the C keybinding system.
	 */

	/* DISABLED: Old Lua-based key implementation (replaced by C key class)
	if (luaL_dostring(globalconf_L,
		"key = {\n"
		"  _index_miss_handler = nil,\n"
		"  _newindex_miss_handler = nil\n"
		"}\n"
		"function key.set_index_miss_handler(handler)\n"
		"  key._index_miss_handler = handler\n"
		"end\n"
		"function key.set_newindex_miss_handler(handler)\n"
		"  key._newindex_miss_handler = handler\n"
		"end\n"
		"setmetatable(key, {\n"
		"  __call = function(self, args)\n"
		"    local obj = {\n"
		"      modifiers = args.modifiers or {},\n"
		"      key = args.key,\n"
		"      _private = {},\n"
		"      _signals = {}\n"
		"    }\n"
		"    function obj:connect_signal(name, func)\n"
		"      if not self._signals[name] then\n"
		"        self._signals[name] = {}\n"
		"      end\n"
		"      table.insert(self._signals[name], func)\n"
		"    end\n"
		"    function obj:emit_signal(name, ...)\n"
		"      if self._signals[name] then\n"
		"        for _, func in ipairs(self._signals[name]) do\n"
		"          func(self, ...)\n"
		"        end\n"
		"      end\n"
		"    end\n"
		"    return obj\n"
		"  end\n"
		"})\n"
	) != 0) {
		fprintf(stderr, "somewm: failed to create key class: %s\n",
			lua_tostring(globalconf_L, -1));
		lua_pop(globalconf_L, 1);
	}
	*/ /* END DISABLED */

	/* AwesomeWM compatibility: The client, tag, screen classes are already registered
	 * as globals by their respective *_class_setup() functions via luaA_class_setup.
	 * No aliasing needed - they use the correct names already.
	 */
}

/** Accumulate a startup error message (AwesomeWM pattern)
 * \param err Error message to accumulate
 */
static void
luaA_startup_error(const char *err)
{
	/* Add separator if there are existing errors */
	if (globalconf.startup_errors.len > 0)
		buffer_addsl(&globalconf.startup_errors, "\n\n");

	/* Append the new error */
	buffer_adds(&globalconf.startup_errors, err);
}

/** Error handler for lua_pcall (AwesomeWM pattern)
 * This is called when a Lua error occurs during protected calls.
 * It adds a traceback to the error message and returns it.
 * \param L Lua state
 * \return Number of return values (1 = error message with traceback)
 */
static int
luaA_dofunction_on_error(lua_State *L)
{
	/* Get the error message */
	const char *err = lua_tostring(L, -1);
	if (!err)
		err = "(error object is not a string)";

	/* Add traceback using debug.traceback */
	lua_getglobal(L, "debug");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "traceback");
		if (lua_isfunction(L, -1)) {
			lua_pushvalue(L, -3);  /* Push original error */
			lua_pushinteger(L, 2);  /* Skip this function and caller */
			/* Use pcall for safety - debug.traceback could fail */
			if (lua_pcall(L, 2, 1, 0) == 0) {
				lua_remove(L, -2);      /* Remove debug table */
				return 1;               /* Return error with traceback */
			}
			/* If traceback itself failed, pop the error and fall through */
			lua_pop(L, 1);
		}
		lua_pop(L, 1);  /* Pop traceback function or non-function */
	}
	lua_pop(L, 1);  /* Pop debug table or nil */

	/* Fallback: return original error if debug.traceback not available or failed */
	return 1;
}

void
luaA_loadrc(void)
{
	char xdg_config_path[512];
	const char *xdg_config_home;
	const char *home;
	const char *config_paths[8];
	int path_count = 0;
	int loaded = 0;
	int load_result;
	int i;

	if (!globalconf_L) {
		fprintf(stderr, "somewm: Lua not initialized, cannot load config\n");
		return;
	}

	/* Build config search path following AwesomeWM pattern:
	 * 1. $XDG_CONFIG_HOME/somewm/rc.lua or ~/.config/somewm/rc.lua
	 * 2. ~/.config/awesome/rc.lua (AwesomeWM compatibility)
	 * 3. SYSCONFDIR/xdg/somewm/rc.lua (installed example)
	 * 4. DATADIR/somewm/somewmrc.lua (installed fallback)
	 */

	/* XDG user config - somewm takes priority */
	xdg_config_home = getenv("XDG_CONFIG_HOME");
	if (xdg_config_home && xdg_config_home[0] != '\0') {
		snprintf(xdg_config_path, sizeof(xdg_config_path), "%s/somewm/rc.lua", xdg_config_home);
		config_paths[path_count++] = xdg_config_path;
	} else {
		home = getenv("HOME");
		if (home && home[0] != '\0') {
			snprintf(xdg_config_path, sizeof(xdg_config_path), "%s/.config/somewm/rc.lua", home);
			config_paths[path_count++] = xdg_config_path;
		}
	}

	/* AwesomeWM compatibility - check ~/.config/awesome/rc.lua */
	home = getenv("HOME");
	if (home && home[0] != '\0') {
		static char awesome_config_path[512];
		snprintf(awesome_config_path, sizeof(awesome_config_path), "%s/.config/awesome/rc.lua", home);
		config_paths[path_count++] = awesome_config_path;
	}

	/* System-wide installed example config (XDG compliant) */
	config_paths[path_count++] = SYSCONFDIR "/xdg/somewm/rc.lua";

	/* System-wide fallback */
	config_paths[path_count++] = DATADIR "/somewm/somewmrc.lua";

	/* Development repo fallback (when running from source) */
	home = getenv("HOME");
	if (home && home[0] != '\0') {
		static char repo_fallback[512];
		snprintf(repo_fallback, sizeof(repo_fallback), "%s/tools/some/somewmrc.lua", home);
		config_paths[path_count++] = repo_fallback;
	}

	config_paths[path_count] = NULL;

	/* Try to load config file */
	for (i = 0; config_paths[i] != NULL; i++) {
		/* Use luaL_loadfile + lua_pcall with traceback for better errors */
		load_result = luaL_loadfile(globalconf_L, config_paths[i]);
		if (load_result != 0) {
			/* File doesn't exist or syntax error */
			const char *err = lua_tostring(globalconf_L, -1);

			/* Accumulate error for naughty notification */
			luaA_startup_error(err);

			if (i == 0) {
				fprintf(stderr, "somewm: error loading %s: %s\n",
					config_paths[i], err);
				fprintf(stderr, "somewm: trying alternate configs...\n");
			}
			lua_pop(globalconf_L, 1);
			continue;
		}

		/* Add config directory to package.path so require() can find local modules
		 * (AwesomeWM compatibility - allows require("src.theme.user_variables")) */
		{
			char config_dir[512];
			char *last_slash;
			const char *old_path;

			strncpy(config_dir, config_paths[i], sizeof(config_dir) - 1);
			config_dir[sizeof(config_dir) - 1] = '\0';

			last_slash = strrchr(config_dir, '/');
			if (last_slash) {
				*last_slash = '\0';  /* Truncate at last slash to get directory */

				/* Prepend config directory to package.path */
				lua_getglobal(globalconf_L, "package");
				lua_getfield(globalconf_L, -1, "path");
				old_path = lua_tostring(globalconf_L, -1);
				lua_pop(globalconf_L, 1);

				lua_pushfstring(globalconf_L, "%s/?.lua;%s/?/init.lua;%s",
					config_dir, config_dir, old_path);
				lua_setfield(globalconf_L, -2, "path");
				lua_pop(globalconf_L, 1);  /* pop package table */
			}
		}

		/* Set conffile path BEFORE execution (AwesomeWM pattern) */
		luaA_awesome_set_conffile(globalconf_L, config_paths[i]);

		/* Push error handler BEFORE chunk (AwesomeWM pattern) */
		lua_pushcfunction(globalconf_L, luaA_dofunction_on_error);
		lua_insert(globalconf_L, -2);   /* Insert error handler before chunk */

		/* Execute with protected call using error handler */
		if (lua_pcall(globalconf_L, 0, 0, -2) == 0) {
			/* Success */
			lua_pop(globalconf_L, 1);  /* Pop error handler */
			printf("somewm: loaded Lua config from %s\n", config_paths[i]);

			/* Automatically load IPC module for CLI support (somewm extension) */
			lua_getglobal(globalconf_L, "require");
			lua_pushstring(globalconf_L, "awful.ipc");
			if (lua_pcall(globalconf_L, 1, 0, 0) != 0) {
				fprintf(stderr, "Warning: Failed to load IPC module: %s\n",
					lua_tostring(globalconf_L, -1));
				lua_pop(globalconf_L, 1);
			}

			loaded = 1;
			break;
		} else {
			/* Runtime error - already handled by error handler */
			const char *err = lua_tostring(globalconf_L, -1);

			/* Accumulate runtime error for naughty notification */
			luaA_startup_error(err);

			if (i == 0) {
				fprintf(stderr, "somewm: error executing %s:\n%s\n",
					config_paths[i], err);
				fprintf(stderr, "somewm: trying alternate configs...\n");
			}
			lua_pop(globalconf_L, 2);  /* Pop error and error handler */
			continue;  /* Try next config */
		}
	}

	if (!loaded) {
		fprintf(stderr, "somewm: FATAL: no working Lua config found!\n");
		fprintf(stderr, "somewm: tried:\n");
		for (i = 0; config_paths[i] != NULL; i++) {
			fprintf(stderr, "  - %s\n", config_paths[i]);
		}
	}
}

void
luaA_cleanup(void)
{
	if (globalconf_L) {
		/* Clean up signal and keybinding systems first */
		luaA_signal_cleanup();
		luaA_keybinding_cleanup();

		/* Close Lua state - this triggers Lua GC which calls registered
		 * collector functions (client_wipe, tag_wipe, screen_wipe, drawin_wipe)
		 * to properly free all Lua objects. This must happen BEFORE
		 * globalconf_wipe() to avoid use-after-free bugs. */
		lua_close(globalconf_L);
		globalconf_L = NULL;

		/* Clean up globalconf structure AFTER closing Lua.
		 * At this point, Lua GC has already destroyed all objects via collectors,
		 * so we're just wiping the (now empty) array pointers. */
		globalconf_wipe();
	}
}

/** Load and execute a Lua file with error reporting.
 * Wrapper around luaL_dofile with better error messages.
 *
 * \param L The Lua VM state.
 * \param path Path to the Lua file to load.
 * \return 0 on success, -1 on error.
 */
int
luaA_dofunction_from_file(lua_State *L, const char *path)
{
	if (luaL_dofile(L, path) != 0) {
		fprintf(stderr, "somewm:Lua error in %s: %s\n",
		        path, lua_tostring(L, -1));
		lua_pop(L, 1);  /* Remove error message */
		return -1;
	}
	return 0;
}

/** Initialize the global configuration structure.
 * This is called early in luaA_init() before any other subsystems.
 *
 * \param L The Lua state to use
 */
void
globalconf_init(lua_State *L)
{
	/* Zero out the entire structure */
	memset(&globalconf, 0, sizeof(globalconf));

	/* Set the Lua state */
	globalconf.L = L;

	/* Initialize arrays to empty state */
	client_array_init(&globalconf.clients);
	client_array_init(&globalconf.stack);
	tag_array_init(&globalconf.tags);
	key_array_init(&globalconf.keys);
	button_array_init(&globalconf.buttons);
	screen_array_init(&globalconf.screens);
	drawin_array_init(&globalconf.drawins);

	/* Initialize focus state */
	globalconf.focus.client = NULL;
	globalconf.focus.need_update = false;

	/* Initialize screen state */
	globalconf.primary_screen = NULL;

	/* Initialize flags */
	globalconf.need_lazy_banning = false;

	/* Initialize grabbers */
	globalconf.keygrabber = LUA_REFNIL;
	globalconf.mousegrabber = LUA_REFNIL;

	/* Initialize exit code */
	globalconf.exit_code = 0;

	/* Initialize API level (AwesomeWM compatibility) */
	globalconf.api_level = 4;  /* Match AwesomeWM's current API level */

	/* Initialize icon size preference */
	globalconf.preferred_icon_size = 0;  /* 0 = no preference */

	/* Initialize startup errors buffer (AwesomeWM compatibility)
	 * This accumulates all errors during config loading */
	buffer_init(&globalconf.startup_errors);

	/* Initialize X11 stubs */
	globalconf.connection = NULL;
	globalconf.timestamp = 0;
}

/** Cleanup the global configuration structure.
 * This is called at shutdown to free all allocated resources.
 */
void
globalconf_wipe(void)
{
	/* Note: Individual objects are cleaned up by their respective subsystems.
	 * We just need to wipe the arrays themselves, not the objects they contain.
	 */

	/* Wipe arrays - uses DO_NOTHING dtor so it doesn't free the objects */
	client_array_wipe(&globalconf.clients);
	client_array_wipe(&globalconf.stack);
	tag_array_wipe(&globalconf.tags);
	screen_array_wipe(&globalconf.screens);
	drawin_array_wipe(&globalconf.drawins);

	/* Clean up wallpaper resources */
	if (globalconf.wallpaper) {
		cairo_surface_destroy(globalconf.wallpaper);
		globalconf.wallpaper = NULL;
	}
	if (globalconf.wallpaper_buffer_node) {
		wlr_scene_node_destroy(&globalconf.wallpaper_buffer_node->node);
		globalconf.wallpaper_buffer_node = NULL;
	}

	/* Zero out the structure */
	memset(&globalconf, 0, sizeof(globalconf));
}

/** Default __index metamethod.
 * Matches AwesomeWM luaa.c:1342-1346.
 * \param L The Lua VM state.
 * \return Number of values pushed.
 */
int
luaA_default_index(lua_State *L)
{
	return luaA_class_index_miss_property(L, NULL);
}

/** Default __newindex metamethod.
 * Matches AwesomeWM luaa.c:1348-1352.
 * \param L The Lua VM state.
 * \return Number of values pushed.
 */
int
luaA_default_newindex(lua_State *L)
{
	return luaA_class_newindex_miss_property(L, NULL);
}
