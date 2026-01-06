#include "luaa.h"
#include "globalconf.h"

/* Include LuaJIT header for luaJIT_setmode() if available.
 * This is needed to disable JIT during config load for reliable hook triggering. */
#if defined(__has_include)
#if __has_include(<luajit.h>)
#include <luajit.h>
#endif
#endif

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
#include "objects/systray.h"
#include "selection.h"
#include "common/luaobject.h"
#include "window.h"
#include "dbus.h"

/* Forward declaration for Lua state recreation (used by config timeout handler) */
static lua_State *luaA_create_fresh_state(void);
#include "common/luaclass.h"
#include "common/lualib.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <unistd.h>
#include <sys/stat.h>
#include <signal.h>
#include <limits.h>
#include <setjmp.h>

/* Config loading timeout state (for graceful fallback on hanging configs) */
static volatile sig_atomic_t config_timeout_fired = 0;
static lua_State *config_timeout_L = NULL;
static sigjmp_buf config_timeout_jmp;
static volatile sig_atomic_t config_timeout_jmp_valid = 0;


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

	/* Install Lua 5.3/5.4 compatibility stubs for helpful error messages.
	 * LuaJIT and Lua 5.1/5.2 don't have these features, so user configs
	 * that try to use them get confusing errors. These stubs provide
	 * clear messages about what's wrong and how to fix it. */
#if LUA_VERSION_NUM < 503
	/* utf8 library stub (Lua 5.3+) */
	if (luaL_dostring(L,
		"utf8 = setmetatable({}, {\n"
		"    __index = function(t, k)\n"
		"        error('utf8.' .. k .. '() requires Lua 5.3+.\\n'\n"
		"              .. 'somewm uses ' .. _VERSION .. ' (LuaJIT).\\n'\n"
		"              .. 'Use GLib UTF-8 functions via LGI instead:\\n'\n"
		"              .. '  local lgi = require(\"lgi\")\\n'\n"
		"              .. '  local GLib = lgi.GLib\\n'\n"
		"              .. '  GLib.utf8_strlen(str, -1)  -- instead of utf8.len()', 2)\n"
		"    end\n"
		"})") != 0) {
		fprintf(stderr, "somewm: warning: failed to create utf8 stub: %s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	/* string.pack/unpack stubs (Lua 5.3+) */
	if (luaL_dostring(L,
		"if not string.pack then\n"
		"    string.pack = function()\n"
		"        error('string.pack() requires Lua 5.3+. somewm uses ' .. _VERSION, 2)\n"
		"    end\n"
		"    string.unpack = function()\n"
		"        error('string.unpack() requires Lua 5.3+. somewm uses ' .. _VERSION, 2)\n"
		"    end\n"
		"    string.packsize = function()\n"
		"        error('string.packsize() requires Lua 5.3+. somewm uses ' .. _VERSION, 2)\n"
		"    end\n"
		"end") != 0) {
		fprintf(stderr, "somewm: warning: failed to create string.pack stubs: %s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	/* table.move stub (Lua 5.3+) */
	if (luaL_dostring(L,
		"if not table.move then\n"
		"    table.move = function()\n"
		"        error('table.move() requires Lua 5.3+. somewm uses ' .. _VERSION .. '.\\n'\n"
		"              .. 'Use a manual loop instead:\\n'\n"
		"              .. '  for i = f, e do dest[t+i-f] = src[i] end', 2)\n"
		"    end\n"
		"end") != 0) {
		fprintf(stderr, "somewm: warning: failed to create table.move stub: %s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	/* warn() stub (Lua 5.4) */
	if (luaL_dostring(L,
		"if not warn then\n"
		"    warn = function(msg)\n"
		"        -- warn() is Lua 5.4 only, just print to stderr as fallback\n"
		"        io.stderr:write('Lua warning: ' .. tostring(msg) .. '\\n')\n"
		"    end\n"
		"end") != 0) {
		fprintf(stderr, "somewm: warning: failed to create warn stub: %s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}
#endif /* LUA_VERSION_NUM < 503 */

	/* Wrap io.popen with automatic timeout to prevent hanging on blocking commands.
	 * This is critical for graceful fallback - any io.popen that hangs for more
	 * than 3 seconds will be killed, allowing the config to fail and fallback. */
	if (luaL_dostring(L,
		"do\n"
		"    local original_popen = io.popen\n"
		"    io.popen = function(cmd, mode)\n"
		"        -- Wrap command with timeout (3 seconds) to prevent hangs\n"
		"        -- The timeout command kills the subprocess if it takes too long\n"
		"        local wrapped_cmd = 'timeout -s 9 3 sh -c ' .. string.format('%q', cmd)\n"
		"        return original_popen(wrapped_cmd, mode)\n"
		"    end\n"
		"    -- Store original for code that really needs unbounded popen\n"
		"    io.popen_raw = original_popen\n"
		"end") != 0) {
		fprintf(stderr, "somewm: warning: failed to wrap io.popen: %s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	/* CRITICAL: Prevent GTK from calling gtk_init_check() during lgi.require().
	 *
	 * When running inside a Wayland compositor, GTK's init tries to connect
	 * as a Wayland client to WAYLAND_DISPLAY. But the compositor's event loop
	 * is blocked waiting for Lua to finish loading, causing a deadlock.
	 *
	 * The fix: preload an empty table at "lgi.override.Gtk" so lgi skips
	 * loading the real override file (which calls gtk_init_check()).
	 * GTK still works fine without init - IconTheme and other non-display
	 * features work perfectly. */
	if (luaL_dostring(L,
		"package.loaded['lgi.override.Gtk'] = {}") != 0) {
		fprintf(stderr, "somewm: warning: failed to preload Gtk override: %s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}
}

/* Search paths added via command line -L/--search */
#define MAX_SEARCH_PATHS 16
static const char *extra_search_paths[MAX_SEARCH_PATHS];
static int num_extra_search_paths = 0;

/* Custom config file path - set via -c/--config flag */
static const char *custom_confpath = NULL;

void
luaA_set_confpath(const char *path)
{
	custom_confpath = path;
}

void
luaA_add_search_paths(const char **paths, int count)
{
	for (int i = 0; i < count && num_extra_search_paths < MAX_SEARCH_PATHS; i++) {
		extra_search_paths[num_extra_search_paths++] = paths[i];
	}
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

	/* Also set up package.cpath for C modules like lgi */
	lua_getfield(globalconf_L, -1, "cpath");
	cur_path = lua_tostring(globalconf_L, -1);
	lua_pop(globalconf_L, 1);

	/* Prepend C module paths: development paths first, then system-wide paths */
	lua_pushfstring(globalconf_L,
		"./lua/?.so;./lua/lib/?.so;"
		DATADIR "/somewm/lua/?.so;" DATADIR "/somewm/lua/lib/?.so;%s",
		cur_path);
	lua_setfield(globalconf_L, -2, "cpath");

	/* Add extra search paths from -L/--search command line options */
	if (num_extra_search_paths > 0) {
		for (int i = 0; i < num_extra_search_paths; i++) {
			const char *dir = extra_search_paths[i];

			/* Add to package.path */
			lua_getfield(globalconf_L, -1, "path");
			cur_path = lua_tostring(globalconf_L, -1);
			lua_pop(globalconf_L, 1);
			lua_pushfstring(globalconf_L, "%s/?.lua;%s/?/init.lua;%s",
				dir, dir, cur_path);
			lua_setfield(globalconf_L, -2, "path");

			/* Add to package.cpath */
			lua_getfield(globalconf_L, -1, "cpath");
			cur_path = lua_tostring(globalconf_L, -1);
			lua_pop(globalconf_L, 1);
			lua_pushfstring(globalconf_L, "%s/?.so;%s",
				dir, cur_path);
			lua_setfield(globalconf_L, -2, "cpath");

			printf("somewm: added search path: %s\n", dir);
		}
	}

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
	systray_item_class_setup(globalconf_L);  /* SNI systray item class */

	/* Register D-Bus library (AwesomeWM compatibility) */
	luaA_registerlib(globalconf_L, "dbus", awesome_dbus_lib);
	lua_pop(globalconf_L, 1);  /* luaA_registerlib leaves table on stack */

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
 * It emits debug::error signal and adds a traceback to the error message.
 * \param L Lua state
 * \return Number of return values (1 = error message with traceback)
 */
static int
luaA_dofunction_on_error(lua_State *L)
{
	/* Convert error to string to prevent follow-up errors (AwesomeWM pattern) */
	if (!lua_isstring(L, -1)) {
		lua_pushliteral(L, "(error object is not a string)");
		lua_remove(L, -2);
	}

	/* Duplicate error string for signal emission */
	lua_pushvalue(L, -1);

	/* Emit debug::error signal (AwesomeWM pattern)
	 * This allows naughty to catch and display errors */
	luaA_emit_signal_global_with_stack(L, "debug::error", 1);

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

/** SIGALRM handler for config loading timeout.
 * Uses siglongjmp to forcefully abort - lua_sethook doesn't work reliably with LuaJIT.
 * \param signo Signal number (unused)
 */
static void
config_timeout_handler(int signo)
{
	(void)signo;
	config_timeout_fired = 1;
	/* Debug: write directly to stderr (signal-safe) */
	(void)!write(STDERR_FILENO, "\n*** CONFIG TIMEOUT - ABORTING ***\n", 35);

	/* Use siglongjmp to forcefully abort config loading.
	 * This is more reliable than lua_sethook which doesn't work well with LuaJIT. */
	if (config_timeout_jmp_valid) {
		siglongjmp(config_timeout_jmp, 1);
	}
}

/** Pattern severity levels for config scanner */
typedef enum {
	SEVERITY_INFO,      /* May not work, but won't break config */
	SEVERITY_WARNING,   /* Needs Wayland alternative */
	SEVERITY_CRITICAL   /* Will fail or hang on Wayland */
} x11_severity_t;

/** X11-specific patterns that may cause issues on Wayland.
 * These patterns are scanned BEFORE executing config to prevent hangs,
 * and can also be used with `somewm --check` for config analysis.
 */
typedef struct {
	const char *pattern;      /* Simple substring to search for */
	const char *description;  /* Human-readable description */
	const char *suggestion;   /* How to fix it */
	x11_severity_t severity;  /* How serious the issue is */
} x11_pattern_t;

static const x11_pattern_t x11_patterns[] = {
	/* === CRITICAL: Will fail or hang === */

	/* X11 property APIs - safe no-op stubs that won't hang
	 * Downgraded to WARNING since they just return nil, not block */
	{"awesome.get_xproperty", "awesome.get_xproperty() [X11 only]",
	 "Use persistent storage (gears.filesystem) or remove", SEVERITY_WARNING},
	{"awesome.set_xproperty", "awesome.set_xproperty() [X11 only]",
	 "Use persistent storage (gears.filesystem) or remove", SEVERITY_WARNING},
	{"awesome.register_xproperty", "awesome.register_xproperty() [X11 only]",
	 "Remove - X11 properties don't exist on Wayland", SEVERITY_WARNING},

	/* Blocking X11 tool calls that will hang */
	{"io.popen(\"xrandr", "io.popen with xrandr (blocks)",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"io.popen('xrandr", "io.popen with xrandr (blocks)",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"io.popen(\"xwininfo", "io.popen with xwininfo (blocks)",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"io.popen('xwininfo", "io.popen with xwininfo (blocks)",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"io.popen(\"xdotool", "io.popen with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"io.popen('xdotool", "io.popen with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"io.popen(\"xprop", "io.popen with xprop (blocks)",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},
	{"io.popen('xprop", "io.popen with xprop (blocks)",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},
	{"io.popen(\"xrdb", "io.popen with xrdb (blocks)",
	 "Use beautiful.xresources.get_current_theme() instead", SEVERITY_CRITICAL},
	{"io.popen('xrdb", "io.popen with xrdb (blocks)",
	 "Use beautiful.xresources.get_current_theme() instead", SEVERITY_CRITICAL},

	/* os.execute blocks even harder */
	{"os.execute(\"xrandr", "os.execute with xrandr (blocks)",
	 "Use awful.spawn.easy_async instead", SEVERITY_CRITICAL},
	{"os.execute('xrandr", "os.execute with xrandr (blocks)",
	 "Use awful.spawn.easy_async instead", SEVERITY_CRITICAL},
	{"os.execute(\"xdotool", "os.execute with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"os.execute('xdotool", "os.execute with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},

	/* Shell subcommand patterns in strings */
	{"$(xrandr", "shell subcommand with xrandr",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"`xrandr", "shell subcommand with xrandr",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"$(xwininfo", "shell subcommand with xwininfo",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"`xwininfo", "shell subcommand with xwininfo",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"$(xdotool", "shell subcommand with xdotool",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"`xdotool", "shell subcommand with xdotool",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"$(xprop", "shell subcommand with xprop",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},
	{"`xprop", "shell subcommand with xprop",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},

	/* === WARNING: Needs Wayland alternative === */

	/* Screenshot tools (start of string or mid-command) */
	{"\"maim", "maim screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"'maim", "maim screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{" maim ", "maim screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"\"scrot", "scrot screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"'scrot", "scrot screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{" scrot ", "scrot screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"\"import ", "ImageMagick import (screenshot)",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"'import ", "ImageMagick import (screenshot)",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"\"flameshot", "flameshot screenshot tool",
	 "Use awful.screenshot, grim, or flameshot with XDG portal", SEVERITY_WARNING},
	{"'flameshot", "flameshot screenshot tool",
	 "Use awful.screenshot, grim, or flameshot with XDG portal", SEVERITY_WARNING},

	/* Clipboard tools (start of string or piped) */
	{"\"xclip", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"'xclip", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"| xclip", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{" xclip ", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"\"xsel", "xsel clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"'xsel", "xsel clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"| xsel", "xsel clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},

	/* Display/input tools used async */
	{"\"xset", "xset display settings",
	 "Most settings are handled by compositor or wlr-randr", SEVERITY_WARNING},
	{"'xset", "xset display settings",
	 "Most settings are handled by compositor or wlr-randr", SEVERITY_WARNING},
	{"\"xinput", "xinput device settings",
	 "Use compositor input settings or libinput config", SEVERITY_WARNING},
	{"'xinput", "xinput device settings",
	 "Use compositor input settings or libinput config", SEVERITY_WARNING},
	{"\"xmodmap", "xmodmap keyboard settings",
	 "Use xkb_options in compositor config", SEVERITY_WARNING},
	{"'xmodmap", "xmodmap keyboard settings",
	 "Use xkb_options in compositor config", SEVERITY_WARNING},
	{"\"setxkbmap", "setxkbmap keyboard layout",
	 "Use awful.keyboard.set_layouts() or compositor config", SEVERITY_WARNING},
	{"'setxkbmap", "setxkbmap keyboard layout",
	 "Use awful.keyboard.set_layouts() or compositor config", SEVERITY_WARNING},

	/* Spawn tools that won't work */
	{"\"xdg-screensaver", "xdg-screensaver",
	 "Use swayidle or compositor idle settings", SEVERITY_WARNING},
	{"'xdg-screensaver", "xdg-screensaver",
	 "Use swayidle or compositor idle settings", SEVERITY_WARNING},

	/* === INFO: May not work, usually harmless === */

	/* Compositor references (no-op on Wayland - built-in) */
	{"\"picom", "picom compositor",
	 "Compositing is built into Wayland, remove picom references", SEVERITY_INFO},
	{"'picom", "picom compositor",
	 "Compositing is built into Wayland, remove picom references", SEVERITY_INFO},
	{"\"compton", "compton compositor",
	 "Compositing is built into Wayland, remove compton references", SEVERITY_INFO},
	{"'compton", "compton compositor",
	 "Compositing is built into Wayland, remove compton references", SEVERITY_INFO},

	/* Tray tools (layer-shell based trays work differently) */
	{"\"stalonetray", "stalonetray system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},
	{"'stalonetray", "stalonetray system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},
	{"\"trayer", "trayer system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},
	{"'trayer", "trayer system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},

	/* Theming tools that read X resources */
	{"\"lxappearance", "lxappearance GTK theme tool",
	 "GTK themes work, but use gsettings or gtk config files", SEVERITY_INFO},
	{"'lxappearance", "lxappearance GTK theme tool",
	 "GTK themes work, but use gsettings or gtk config files", SEVERITY_INFO},
	{"\"qt5ct", "qt5ct Qt theme tool",
	 "Qt5/6 themes work, but configure via qt5ct/qt6ct config", SEVERITY_INFO},
	{"'qt5ct", "qt5ct Qt theme tool",
	 "Qt5/6 themes work, but configure via qt5ct/qt6ct config", SEVERITY_INFO},

	/* X11-only utilities that silently fail */
	{"\"xhost", "xhost X11 access control",
	 "Wayland has different security model, remove xhost", SEVERITY_INFO},
	{"'xhost", "xhost X11 access control",
	 "Wayland has different security model, remove xhost", SEVERITY_INFO},
	{"\"xauth", "xauth X11 authentication",
	 "Wayland uses different auth, remove xauth", SEVERITY_INFO},
	{"'xauth", "xauth X11 authentication",
	 "Wayland uses different auth, remove xauth", SEVERITY_INFO},

	{NULL, NULL, NULL, 0}
};

/* Maximum recursion depth for require scanning */
#define PRESCAN_MAX_DEPTH 8
/* Maximum number of files to scan */
#define PRESCAN_MAX_FILES 100

/* Track already-scanned files to avoid duplicates */
static const char *prescan_visited[PRESCAN_MAX_FILES];
static int prescan_visited_count = 0;

/** Check if a file was already scanned */
static bool
prescan_already_visited(const char *path)
{
	int i;
	for (i = 0; i < prescan_visited_count; i++) {
		if (strcmp(prescan_visited[i], path) == 0)
			return true;
	}
	return false;
}

/** Mark a file as visited (strdup'd - caller must free prescan_visited array) */
static void
prescan_mark_visited(const char *path)
{
	if (prescan_visited_count < PRESCAN_MAX_FILES)
		prescan_visited[prescan_visited_count++] = strdup(path);
}

/** Free all visited path strings */
static void
prescan_cleanup_visited(void)
{
	int i;
	for (i = 0; i < prescan_visited_count; i++)
		free((void *)prescan_visited[i]);
	prescan_visited_count = 0;
}

/** Internal recursive pre-scan function */
static bool
luaA_prescan_file(const char *config_path, const char *config_dir, int depth);

/** Extract and scan all require()d files from content
 * \param content File content to scan
 * \param config_dir Directory for resolving relative requires
 * \param depth Current recursion depth
 * \return true if all required files are safe, false if dangerous patterns found
 */
static bool
luaA_prescan_requires(const char *content, const char *config_dir, int depth)
{
	const char *pos = content;
	char module_name[256];
	char resolved_path[PATH_MAX];
	bool all_safe = true;

	if (depth >= PRESCAN_MAX_DEPTH || !config_dir)
		return true;

	/* Scan for require("module") and require('module') patterns */
	while ((pos = strstr(pos, "require")) != NULL) {
		const char *start;
		const char *end;
		char quote;
		size_t len;

		pos += 7;  /* Skip "require" */

		/* Skip whitespace and optional ( */
		while (*pos == ' ' || *pos == '\t' || *pos == '(')
			pos++;

		/* Check for string delimiter */
		if (*pos != '"' && *pos != '\'')
			continue;

		quote = *pos++;
		start = pos;

		/* Find end of string */
		end = strchr(pos, quote);
		if (!end || (end - start) >= (int)sizeof(module_name) - 1)
			continue;

		len = end - start;
		memcpy(module_name, start, len);
		module_name[len] = '\0';
		pos = end + 1;

		/* Skip standard library modules (no dots = likely stdlib) */
		/* We only care about local modules like "fishlive.helpers" */
		if (strchr(module_name, '.') == NULL &&
		    strcmp(module_name, "fishlive") != 0 &&
		    strcmp(module_name, "lain") != 0 &&
		    strcmp(module_name, "freedesktop") != 0)
			continue;

		/* Convert module.name to module/name */
		{
			char *p;
			for (p = module_name; *p; p++) {
				if (*p == '.') *p = '/';
			}
		}

		/* Try module_name.lua */
		snprintf(resolved_path, sizeof(resolved_path),
		         "%s/%s.lua", config_dir, module_name);

		if (access(resolved_path, R_OK) == 0) {
			if (!luaA_prescan_file(resolved_path, config_dir, depth + 1))
				all_safe = false;
			continue;
		}

		/* Try module_name/init.lua */
		snprintf(resolved_path, sizeof(resolved_path),
		         "%s/%s/init.lua", config_dir, module_name);

		if (access(resolved_path, R_OK) == 0) {
			if (!luaA_prescan_file(resolved_path, config_dir, depth + 1))
				all_safe = false;
		}
	}

	return all_safe;
}

/** Internal pre-scan implementation with recursion
 * \param config_path Path to the config file
 * \param config_dir Directory containing the config (for require resolution)
 * \param depth Current recursion depth
 * \return true if config is safe to load, false if dangerous patterns found
 */
static bool
luaA_prescan_file(const char *config_path, const char *config_dir, int depth)
{
	FILE *fp;
	char *content = NULL;
	long file_size;
	const x11_pattern_t *pattern;
	bool found_fatal = false;
	int line_num;
	char *line_start;
	char *match_pos;
	char *newline;

	/* Check recursion depth */
	if (depth >= PRESCAN_MAX_DEPTH)
		return true;

	/* Skip already-visited files */
	if (prescan_already_visited(config_path))
		return true;
	prescan_mark_visited(config_path);

	fp = fopen(config_path, "r");
	if (!fp) {
		/* File doesn't exist - not a pre-scan failure, let normal loading handle it */
		return true;
	}

	/* Get file size */
	fseek(fp, 0, SEEK_END);
	file_size = ftell(fp);
	fseek(fp, 0, SEEK_SET);

	if (file_size <= 0 || file_size > 10 * 1024 * 1024) {
		/* Empty or too large (>10MB) - skip pre-scan */
		fclose(fp);
		return true;
	}

	content = malloc(file_size + 1);
	if (!content) {
		fclose(fp);
		return true;
	}

	if (fread(content, 1, file_size, fp) != (size_t)file_size) {
		free(content);
		fclose(fp);
		return true;
	}
	content[file_size] = '\0';
	fclose(fp);

	/* Scan for each dangerous pattern */
	for (pattern = x11_patterns; pattern->pattern != NULL; pattern++) {
		match_pos = strstr(content, pattern->pattern);
		if (match_pos) {
			int line_len;

			/* Found a match - calculate line number */
			line_num = 1;
			for (line_start = content; line_start < match_pos; line_start++) {
				if (*line_start == '\n')
					line_num++;
			}

			/* Find the actual line for context */
			line_start = match_pos;
			while (line_start > content && *(line_start - 1) != '\n')
				line_start--;
			newline = strchr(line_start, '\n');
			line_len = newline ? (int)(newline - line_start) : (int)strlen(line_start);
			if (line_len > 200) line_len = 200;  /* Truncate long lines */

			/* Skip if line is a Lua comment (starts with -- after whitespace) */
			{
				const char *p = line_start;
				while (p < match_pos && (*p == ' ' || *p == '\t'))
					p++;
				if (p[0] == '-' && p[1] == '-')
					continue;  /* Skip commented lines */
			}

			fprintf(stderr, "\n");
			fprintf(stderr, "somewm: *** X11 PATTERN DETECTED ***\n");
			fprintf(stderr, "somewm: File: %s:%d\n", config_path, line_num);
			fprintf(stderr, "somewm: Pattern: %s\n", pattern->description);
			fprintf(stderr, "somewm: \n");
			fprintf(stderr, "somewm: This may hang on Wayland (no X11 display).\n");
			fprintf(stderr, "somewm: Suggestion: %s\n", pattern->suggestion);
			fprintf(stderr, "somewm: \n");

			/* Show the offending line */
			if (line_len > 0) {
				fprintf(stderr, "somewm: Line %d: %.*s\n", line_num,
				        line_len, line_start);
			}

			/* Store first detected pattern for Lua notification */
			if (!found_fatal) {
				globalconf.x11_fallback.config_path = strdup(config_path);
				globalconf.x11_fallback.line_number = line_num;
				globalconf.x11_fallback.pattern_desc = strdup(pattern->description);
				globalconf.x11_fallback.suggestion = strdup(pattern->suggestion);
				globalconf.x11_fallback.line_content = strndup(line_start, line_len);
			}

			found_fatal = true;
			/* Continue scanning to report all issues */
		}
	}

	/* Recursively scan required files */
	if (!found_fatal && config_dir) {
		if (!luaA_prescan_requires(content, config_dir, depth))
			found_fatal = true;
	}

	free(content);
	return !found_fatal;
}

/** Public pre-scan function - scans config and all required files
 * \param config_path Path to the main config file
 * \param config_dir Directory containing the config (for require resolution)
 * \return true if config is safe to load, false if dangerous patterns found
 */
static bool
luaA_prescan_config(const char *config_path, const char *config_dir)
{
	bool result;
	char dir_buf[PATH_MAX];
	const char *dir = config_dir;

	/* Reset visited tracking */
	prescan_cleanup_visited();

	/* If no config_dir provided, derive from config_path */
	if (!dir && config_path) {
		char *last_slash;
		strncpy(dir_buf, config_path, sizeof(dir_buf) - 1);
		dir_buf[sizeof(dir_buf) - 1] = '\0';
		last_slash = strrchr(dir_buf, '/');
		if (last_slash) {
			*last_slash = '\0';
			dir = dir_buf;
		}
	}

	result = luaA_prescan_file(config_path, dir, 0);

	if (!result) {
		fprintf(stderr, "\n");
		fprintf(stderr, "somewm: Skipping this config to prevent hang.\n");
		fprintf(stderr, "somewm: Falling back to default somewmrc.lua...\n");
		fprintf(stderr, "\n");
	}

	prescan_cleanup_visited();
	return result;
}

/* ============================================================================
 * Check Mode: `somewm --check <config>` for config compatibility analysis
 * ============================================================================
 * Scans config without starting compositor and outputs a report.
 */

/* Maximum issues to track in check mode */
#define CHECK_MAX_ISSUES 200

/* Stored issue for check mode report */
typedef struct {
	char *file_path;
	int line_number;
	char *line_content;
	const char *pattern_desc;   /* Points into x11_patterns - don't free */
	const char *suggestion;     /* Points into x11_patterns - don't free */
	x11_severity_t severity;
	bool is_syntax_error;       /* If true, pattern_desc is dynamically allocated */
} check_issue_t;

/* Global state for check mode */
static check_issue_t check_issues[CHECK_MAX_ISSUES];
static int check_issue_count = 0;
static int check_counts[3] = {0, 0, 0};  /* info, warning, critical */

/** Reset check mode state */
static void
check_mode_reset(void)
{
	int i;
	for (i = 0; i < check_issue_count; i++) {
		free(check_issues[i].file_path);
		free(check_issues[i].line_content);
		if (check_issues[i].is_syntax_error)
			free((void *)check_issues[i].pattern_desc);
	}
	check_issue_count = 0;
	check_counts[0] = check_counts[1] = check_counts[2] = 0;
}

/** Store an issue found during check mode scan */
static void
check_mode_add_issue(const char *file_path, int line_num, const char *line_content,
                     const x11_pattern_t *pattern)
{
	check_issue_t *issue;

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(file_path);
	issue->line_number = line_num;
	issue->line_content = strdup(line_content);
	issue->pattern_desc = pattern->description;
	issue->suggestion = pattern->suggestion;
	issue->severity = pattern->severity;
	issue->is_syntax_error = false;

	check_counts[pattern->severity]++;
}

/** Store a syntax error found during check mode */
static void
check_mode_add_syntax_error(const char *file_path, const char *error_msg)
{
	check_issue_t *issue;
	int line_num = 0;
	const char *line_start;
	char *colon;

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	/* Try to extract line number from Lua error message format: "file:line: message" */
	colon = strrchr(file_path, '/');
	line_start = colon ? colon + 1 : file_path;
	colon = strstr(error_msg, line_start);
	if (colon) {
		colon = strchr(colon, ':');
		if (colon)
			line_num = atoi(colon + 1);
	}

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(file_path);
	issue->line_number = line_num;
	issue->line_content = strdup("");
	issue->pattern_desc = strdup(error_msg);
	issue->suggestion = "Fix the syntax error before running";
	issue->severity = SEVERITY_CRITICAL;
	issue->is_syntax_error = true;

	check_counts[SEVERITY_CRITICAL]++;
}

/** Store a missing module error found during check mode */
static void
check_mode_add_missing_module(const char *source_file, const char *module_name,
                              const char *tried_path1, const char *tried_path2)
{
	check_issue_t *issue;
	char desc[512];

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	snprintf(desc, sizeof(desc), "require('%s') - module not found", module_name);

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(source_file);
	issue->line_number = 0;
	issue->line_content = strdup("");
	issue->pattern_desc = strdup(desc);
	issue->suggestion = "Check module path or install missing dependency";
	issue->severity = SEVERITY_WARNING;
	issue->is_syntax_error = true;  /* pattern_desc is dynamically allocated */

	check_counts[SEVERITY_WARNING]++;
}

/* Track if luacheck is available (checked once) */
static int luacheck_available = -1;  /* -1 = unchecked, 0 = no, 1 = yes */

/** Check if luacheck is installed */
static bool
check_luacheck_available(void)
{
	if (luacheck_available < 0) {
		/* Check if luacheck exists in PATH */
		int ret = system("command -v luacheck >/dev/null 2>&1");
		luacheck_available = (ret == 0) ? 1 : 0;
	}
	return luacheck_available == 1;
}

/** Store a luacheck issue */
static void
check_mode_add_luacheck_issue(const char *file_path, int line_num,
                              const char *code, const char *message,
                              x11_severity_t severity)
{
	check_issue_t *issue;
	char desc[512];

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	snprintf(desc, sizeof(desc), "[%s] %s", code, message);

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(file_path);
	issue->line_number = line_num;
	issue->line_content = strdup("");
	issue->pattern_desc = strdup(desc);
	issue->suggestion = "See luacheck documentation for details";
	issue->severity = severity;
	issue->is_syntax_error = true;  /* pattern_desc is dynamically allocated */

	check_counts[severity]++;
}

/** Run luacheck on a file and collect issues
 * \param file_path Path to the Lua file to check
 * \return Number of issues found, or -1 if luacheck not available
 */
static int
check_mode_run_luacheck(const char *file_path)
{
	char cmd[PATH_MAX + 256];
	FILE *pipe;
	char line[1024];
	int issues_found = 0;

	if (!check_luacheck_available())
		return -1;

	/* Run luacheck with parseable output format
	 * File path must come first, then options
	 * --std luajit: use LuaJIT standard
	 * --no-color: plain text output
	 * --codes: include warning codes
	 * --quiet: don't print summary line
	 * --allow-defined-top: allow globals defined at top level (normal for rc.lua)
	 * --globals: AwesomeWM global objects
	 */
	snprintf(cmd, sizeof(cmd),
	         "luacheck '%s' --std luajit --no-color --codes --quiet "
	         "--allow-defined-top "
	         "--globals awesome client screen tag mouse root "
	         "beautiful awful gears wibox naughty menubar ruled "
	         "2>&1", file_path);

	pipe = popen(cmd, "r");
	if (!pipe)
		return -1;

	/* Parse luacheck output: "filename:line:col: (Wcode) message" */
	while (fgets(line, sizeof(line), pipe)) {
		char *colon1, *colon2, *colon3, *paren_open, *paren_close;
		char *nl;
		int line_num = 0;
		char code[16] = "";
		char *message;
		x11_severity_t severity = SEVERITY_WARNING;

		/* Skip lines that don't match the pattern */
		colon1 = strchr(line, ':');
		if (!colon1) continue;
		colon2 = strchr(colon1 + 1, ':');
		if (!colon2) continue;
		colon3 = strchr(colon2 + 1, ':');
		if (!colon3) continue;

		/* Extract line number */
		line_num = atoi(colon1 + 1);

		/* Find the code in parentheses */
		paren_open = strchr(colon3, '(');
		paren_close = paren_open ? strchr(paren_open, ')') : NULL;
		if (paren_open && paren_close) {
			size_t code_len = paren_close - paren_open - 1;
			if (code_len < sizeof(code)) {
				memcpy(code, paren_open + 1, code_len);
				code[code_len] = '\0';
			}
			message = paren_close + 2;  /* Skip ") " */
		} else {
			message = colon3 + 2;
		}

		/* Remove trailing newline */
		nl = strchr(message, '\n');
		if (nl) *nl = '\0';

		/* Determine severity based on code
		 * E = error (syntax errors, etc.)
		 * W = warning
		 */
		if (code[0] == 'E')
			severity = SEVERITY_CRITICAL;
		else
			severity = SEVERITY_WARNING;

		check_mode_add_luacheck_issue(file_path, line_num, code, message, severity);
		issues_found++;
	}

	pclose(pipe);
	return issues_found;
}

/** Check Lua syntax of a file using luaL_loadfile
 * Creates a temporary Lua state just for parsing.
 * \param file_path Path to the Lua file to check
 * \return true if syntax is valid, false if error (and adds issue)
 */
static bool
check_mode_syntax_check(const char *file_path)
{
	lua_State *L;
	int status;
	const char *err_msg;

	L = luaL_newstate();
	if (!L)
		return true;  /* Can't check, assume OK */

	status = luaL_loadfile(L, file_path);
	if (status != 0) {
		err_msg = lua_tostring(L, -1);
		if (err_msg)
			check_mode_add_syntax_error(file_path, err_msg);
		lua_close(L);
		return false;
	}

	lua_close(L);
	return true;
}

/* ANSI color codes */
#define COL_RESET   "\033[0m"
#define COL_RED     "\033[1;31m"
#define COL_YELLOW  "\033[1;33m"
#define COL_CYAN    "\033[1;36m"
#define COL_GREEN   "\033[1;32m"
#define COL_GRAY    "\033[0;37m"
#define COL_BOLD    "\033[1m"

/** Print check mode report to stdout with colors */
static void
check_mode_print_report(const char *config_path, bool use_color)
{
	int i;
	int total;
	const char *sev_colors[] = {COL_CYAN, COL_YELLOW, COL_RED};
	const char *sev_names[] = {"INFO", "WARNING", "CRITICAL"};
	const char *sev_symbols[] = {"i", "!", "X"};

	total = check_counts[0] + check_counts[1] + check_counts[2];

	printf("\n");
	if (use_color)
		printf("%ssomewm config compatibility report%s\n", COL_BOLD, COL_RESET);
	else
		printf("somewm config compatibility report\n");
	printf("====================================\n");
	printf("Config: %s\n\n", config_path);

	if (total == 0) {
		if (use_color)
			printf("%s✓ No compatibility issues found!%s\n\n", COL_GREEN, COL_RESET);
		else
			printf("✓ No compatibility issues found!\n\n");
		return;
	}

	/* Print issues grouped by severity (critical first) */
	for (int sev = SEVERITY_CRITICAL; sev >= SEVERITY_INFO; sev--) {
		bool printed_header = false;

		for (i = 0; i < check_issue_count; i++) {
			check_issue_t *issue = &check_issues[i];
			if ((int)issue->severity != sev)
				continue;

			if (!printed_header) {
				if (use_color)
					printf("%s%s %s:%s\n", sev_colors[sev],
					       sev_symbols[sev], sev_names[sev], COL_RESET);
				else
					printf("%s %s:\n", sev_symbols[sev], sev_names[sev]);
				printed_header = true;
			}

			/* File:line - description */
			if (use_color)
				printf("  %s%s:%d%s - %s\n",
				       COL_BOLD, issue->file_path, issue->line_number, COL_RESET,
				       issue->pattern_desc);
			else
				printf("  %s:%d - %s\n",
				       issue->file_path, issue->line_number,
				       issue->pattern_desc);

			/* Suggestion */
			if (use_color)
				printf("    %s→ %s%s\n", COL_GRAY, issue->suggestion, COL_RESET);
			else
				printf("    → %s\n", issue->suggestion);
		}
		if (printed_header)
			printf("\n");
	}

	/* Summary line */
	if (use_color) {
		printf("%sSummary:%s ", COL_BOLD, COL_RESET);
		if (check_counts[2] > 0)
			printf("%s%d critical%s", COL_RED, check_counts[2], COL_RESET);
		if (check_counts[1] > 0)
			printf("%s%s%d warnings%s",
			       check_counts[2] ? ", " : "",
			       COL_YELLOW, check_counts[1], COL_RESET);
		if (check_counts[0] > 0)
			printf("%s%s%d info%s",
			       (check_counts[2] || check_counts[1]) ? ", " : "",
			       COL_CYAN, check_counts[0], COL_RESET);
		printf("\n\n");
	} else {
		printf("Summary: ");
		if (check_counts[2] > 0)
			printf("%d critical", check_counts[2]);
		if (check_counts[1] > 0)
			printf("%s%d warnings",
			       check_counts[2] ? ", " : "", check_counts[1]);
		if (check_counts[0] > 0)
			printf("%s%d info",
			       (check_counts[2] || check_counts[1]) ? ", " : "",
			       check_counts[0]);
		printf("\n\n");
	}
}

/** Scan a file in check mode (all severities, no blocking) */
static void
check_mode_scan_file(const char *config_path, const char *config_dir, int depth);

/** Scan requires in check mode */
static void
check_mode_scan_requires(const char *content, const char *config_dir,
                         const char *source_file, int depth)
{
	const char *pos = content;
	char module_name[256];
	char module_path[256];
	char resolved_path[PATH_MAX];
	char resolved_path2[PATH_MAX];

	if (depth >= PRESCAN_MAX_DEPTH || !config_dir)
		return;

	while ((pos = strstr(pos, "require")) != NULL) {
		const char *start;
		const char *end;
		char quote;
		size_t len;

		/* Skip lgi.require, some_module.require, etc. */
		if (pos > content && *(pos - 1) == '.') {
			pos += 7;
			continue;
		}

		pos += 7;

		while (*pos == ' ' || *pos == '\t' || *pos == '(')
			pos++;

		if (*pos != '"' && *pos != '\'')
			continue;

		quote = *pos++;
		start = pos;
		end = strchr(pos, quote);
		if (!end || (end - start) >= (int)sizeof(module_name) - 1)
			continue;

		len = end - start;
		memcpy(module_name, start, len);
		module_name[len] = '\0';
		pos = end + 1;

		/* Skip standard Lua library modules */
		if (strcmp(module_name, "string") == 0 ||
		    strcmp(module_name, "table") == 0 ||
		    strcmp(module_name, "math") == 0 ||
		    strcmp(module_name, "io") == 0 ||
		    strcmp(module_name, "os") == 0 ||
		    strcmp(module_name, "debug") == 0 ||
		    strcmp(module_name, "coroutine") == 0 ||
		    strcmp(module_name, "package") == 0 ||
		    strcmp(module_name, "utf8") == 0 ||
		    strcmp(module_name, "bit") == 0 ||
		    strcmp(module_name, "bit32") == 0 ||
		    strcmp(module_name, "ffi") == 0 ||
		    strcmp(module_name, "jit") == 0)
			continue;

		/* Skip AwesomeWM library modules (they're in system paths) */
		if (strncmp(module_name, "awful", 5) == 0 ||
		    strncmp(module_name, "gears", 5) == 0 ||
		    strncmp(module_name, "wibox", 5) == 0 ||
		    strncmp(module_name, "naughty", 7) == 0 ||
		    strncmp(module_name, "beautiful", 9) == 0 ||
		    strncmp(module_name, "menubar", 7) == 0 ||
		    strcmp(module_name, "ruled") == 0 ||
		    strncmp(module_name, "ruled.", 6) == 0)
			continue;

		/* Skip common third-party modules (installed separately) */
		if (strcmp(module_name, "lgi") == 0 ||
		    strncmp(module_name, "lgi.", 4) == 0 ||
		    strcmp(module_name, "lain") == 0 ||
		    strncmp(module_name, "lain.", 5) == 0 ||
		    strcmp(module_name, "freedesktop") == 0 ||
		    strncmp(module_name, "freedesktop.", 12) == 0 ||
		    strcmp(module_name, "vicious") == 0 ||
		    strncmp(module_name, "vicious.", 8) == 0 ||
		    strcmp(module_name, "revelation") == 0 ||
		    strcmp(module_name, "collision") == 0 ||
		    strcmp(module_name, "tyrannical") == 0 ||
		    strcmp(module_name, "cyclefocus") == 0 ||
		    strcmp(module_name, "radical") == 0 ||
		    strcmp(module_name, "cairo") == 0 ||
		    strcmp(module_name, "posix") == 0 ||
		    strncmp(module_name, "posix.", 6) == 0 ||
		    strcmp(module_name, "cjson") == 0 ||
		    strcmp(module_name, "dkjson") == 0 ||
		    strcmp(module_name, "json") == 0 ||
		    strcmp(module_name, "socket") == 0 ||
		    strncmp(module_name, "socket.", 7) == 0 ||
		    strcmp(module_name, "http") == 0 ||
		    strncmp(module_name, "pl.", 3) == 0 ||
		    strcmp(module_name, "penlight") == 0 ||
		    strcmp(module_name, "inspect") == 0 ||
		    strcmp(module_name, "luassert") == 0 ||
		    strcmp(module_name, "busted") == 0)
			continue;

		/* Save original module name for error reporting */
		strncpy(module_path, module_name, sizeof(module_path) - 1);
		module_path[sizeof(module_path) - 1] = '\0';

		/* Convert module.name to module/name */
		for (char *p = module_name; *p; p++) {
			if (*p == '.') *p = '/';
		}

		/* Try module_name.lua */
		snprintf(resolved_path, sizeof(resolved_path),
		         "%s/%s.lua", config_dir, module_name);
		if (access(resolved_path, R_OK) == 0) {
			check_mode_scan_file(resolved_path, config_dir, depth + 1);
			continue;
		}

		/* Try module_name/init.lua */
		snprintf(resolved_path2, sizeof(resolved_path2),
		         "%s/%s/init.lua", config_dir, module_name);
		if (access(resolved_path2, R_OK) == 0) {
			check_mode_scan_file(resolved_path2, config_dir, depth + 1);
			continue;
		}

		/* Module not found - report it */
		check_mode_add_missing_module(source_file, module_path,
		                              resolved_path, resolved_path2);
	}
}

/** Check mode: scan a file and store all issues found */
static void
check_mode_scan_file(const char *config_path, const char *config_dir, int depth)
{
	FILE *fp;
	char *content = NULL;
	long file_size;
	const x11_pattern_t *pattern;

	if (depth >= PRESCAN_MAX_DEPTH)
		return;

	if (prescan_already_visited(config_path))
		return;
	prescan_mark_visited(config_path);

	/* Check Lua syntax first */
	check_mode_syntax_check(config_path);

	fp = fopen(config_path, "r");
	if (!fp)
		return;

	fseek(fp, 0, SEEK_END);
	file_size = ftell(fp);
	fseek(fp, 0, SEEK_SET);

	if (file_size <= 0 || file_size > 10 * 1024 * 1024) {
		fclose(fp);
		return;
	}

	content = malloc(file_size + 1);
	if (!content) {
		fclose(fp);
		return;
	}

	if (fread(content, 1, file_size, fp) != (size_t)file_size) {
		free(content);
		fclose(fp);
		return;
	}
	content[file_size] = '\0';
	fclose(fp);

	/* Scan for all patterns (not just critical) */
	for (pattern = x11_patterns; pattern->pattern != NULL; pattern++) {
		char *match_pos = strstr(content, pattern->pattern);
		if (match_pos) {
			int line_num = 1;
			char *line_start;
			char *newline;
			int line_len;
			char line_buf[201];

			/* Calculate line number */
			for (line_start = content; line_start < match_pos; line_start++) {
				if (*line_start == '\n')
					line_num++;
			}

			/* Find the actual line */
			line_start = match_pos;
			while (line_start > content && *(line_start - 1) != '\n')
				line_start--;
			newline = strchr(line_start, '\n');
			line_len = newline ? (int)(newline - line_start) : (int)strlen(line_start);
			if (line_len > 200) line_len = 200;

			/* Skip commented lines */
			{
				const char *p = line_start;
				while (p < match_pos && (*p == ' ' || *p == '\t'))
					p++;
				if (p[0] == '-' && p[1] == '-')
					continue;
			}

			memcpy(line_buf, line_start, line_len);
			line_buf[line_len] = '\0';

			check_mode_add_issue(config_path, line_num, line_buf, pattern);
		}
	}

	/* Recursively scan required files */
	if (config_dir)
		check_mode_scan_requires(content, config_dir, config_path, depth);

	free(content);
}

/** Public API: Run check mode on a config file
 * \param config_path Path to the main config file
 * \param use_color Whether to use ANSI colors in output
 * \return Exit code (0=ok, 1=warnings, 2=critical)
 */
int
luaA_check_config(const char *config_path, bool use_color)
{
	char dir_buf[PATH_MAX];
	const char *dir = NULL;
	char *last_slash;
	int result;

	/* Reset state */
	check_mode_reset();
	prescan_cleanup_visited();

	/* Derive config_dir from config_path */
	strncpy(dir_buf, config_path, sizeof(dir_buf) - 1);
	dir_buf[sizeof(dir_buf) - 1] = '\0';
	last_slash = strrchr(dir_buf, '/');
	if (last_slash) {
		*last_slash = '\0';
		dir = dir_buf;
	}

	/* Scan the config and all its dependencies */
	check_mode_scan_file(config_path, dir, 0);

	/* Run luacheck if available (gracefully skips if not installed) */
	check_mode_run_luacheck(config_path);

	/* Print the report */
	check_mode_print_report(config_path, use_color);

	/* Capture result before cleanup */
	if (check_counts[2] > 0)
		result = 2;  /* Critical issues */
	else if (check_counts[1] > 0)
		result = 1;  /* Warnings only */
	else
		result = 0;  /* No issues */

	/* Cleanup */
	check_mode_reset();
	prescan_cleanup_visited();

	return result;
}

/** Lua 5.3/5.4 syntax error hints for helpful error messages.
 * LuaJIT is Lua 5.1 compatible, so these features cause confusing errors.
 */
typedef struct {
	const char *pattern;     /* Substring to match in error message */
	const char *feature;     /* Human-readable feature name */
	const char *workaround;  /* How to fix it */
} lua_compat_hint_t;

static const lua_compat_hint_t lua_compat_hints[] = {
	/* Lua 5.3 features */
	{"unexpected symbol near '/'", "integer division operator (//) [Lua 5.3+]",
	 "Use math.floor(a/b) instead of a//b"},
	{"unexpected symbol near '&'", "bitwise AND operator (&) [Lua 5.3+]",
	 "Use bit.band(a,b) or require('gears.bitwise').band(a,b)"},
	{"unexpected symbol near '|'", "bitwise OR operator (|) [Lua 5.3+]",
	 "Use bit.bor(a,b) or require('gears.bitwise').bor(a,b)"},
	{"unexpected symbol near '~'", "bitwise XOR/NOT operator (~) [Lua 5.3+]",
	 "Use bit.bxor(a,b) or bit.bnot(a)"},
	{"unexpected symbol near '<<'", "bitwise left shift operator (<<) [Lua 5.3+]",
	 "Use bit.lshift(a,n)"},
	{"unexpected symbol near '>>'", "bitwise right shift operator (>>) [Lua 5.3+]",
	 "Use bit.rshift(a,n)"},
	/* Lua 5.4 features */
	{"syntax error near '<'", "variable attribute (<const> or <close>) [Lua 5.4]",
	 "Remove the attribute - somewm uses LuaJIT/Lua 5.1"},
	{NULL, NULL, NULL}
};

/** Check if an error message matches a Lua 5.3/5.4 pattern and enhance it.
 * \param err Original error message
 * \param buf Buffer for enhanced message
 * \param bufsize Size of buffer
 * \return true if pattern matched and buf was filled
 */
static bool
luaA_enhance_lua_compat_error(const char *err, char *buf, size_t bufsize)
{
	const lua_compat_hint_t *hint;

	if (!err)
		return false;

	for (hint = lua_compat_hints; hint->pattern != NULL; hint++) {
		if (strstr(err, hint->pattern) != NULL) {
			snprintf(buf, bufsize,
			         "%s\n\n"
			         "*** Modern Lua Syntax Detected ***\n"
			         "Feature: %s\n"
			         "somewm uses %s (Lua 5.1 compatible)\n"
			         "Workaround: %s",
			         err, hint->feature, LUA_VERSION, hint->workaround);
			return true;
		}
	}
	return false;
}

void
luaA_loadrc(void)
{
	char xdg_config_path[512];
	const char *xdg_config_home;
	const char *home;
	const char *config_paths[8];
	int path_count = 0;
	volatile int loaded = 0;  /* volatile: may be modified across siglongjmp */
	int load_result;
	int i;
	struct sigaction sa, old_sa;

	if (!globalconf_L) {
		fprintf(stderr, "somewm: Lua not initialized, cannot load config\n");
		return;
	}

	/* If custom config path was specified via -c flag, use only that */
	if (custom_confpath) {
		config_paths[path_count++] = custom_confpath;
		config_paths[path_count] = NULL;
	} else {
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

		/* Local fallback for development (check current directory) */
		config_paths[path_count++] = "./somewmrc.lua";

		/* System-wide fallback */
		config_paths[path_count++] = DATADIR "/somewm/somewmrc.lua";

		config_paths[path_count] = NULL;
	}

	/* Set up SIGALRM handler for config loading timeout.
	 * This allows graceful fallback when configs hang (e.g., blocking io.popen). */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = config_timeout_handler;
	sa.sa_flags = 0;  /* NO SA_RESTART - we want syscalls interrupted */
	sigemptyset(&sa.sa_mask);

	/* Try to load config file */
	for (i = 0; config_paths[i] != NULL; i++) {
		/* Pre-scan config for X11 patterns that may hang on Wayland */
		if (!luaA_prescan_config(config_paths[i], NULL)) {
			/* Dangerous patterns found - skip this config */
			luaA_startup_error("Config contains X11-specific patterns that may hang on Wayland");
			continue;
		}

		/* Use luaL_loadfile + lua_pcall with traceback for better errors */
		load_result = luaL_loadfile(globalconf_L, config_paths[i]);
		if (load_result != 0) {
			/* File doesn't exist or syntax error */
			const char *err = lua_tostring(globalconf_L, -1);
			char enhanced_err[2048];

			/* Check if this is just "file not found" - that's expected in fallback chain,
			 * not an error worth notifying about. Only real errors (syntax, etc.) should
			 * trigger notifications. */
			int is_file_not_found = (strstr(err, "cannot open") != NULL ||
			                         strstr(err, "No such file") != NULL);

			/* Check for Lua 5.3/5.4 syntax and provide helpful message */
			if (luaA_enhance_lua_compat_error(err, enhanced_err, sizeof(enhanced_err))) {
				luaA_startup_error(enhanced_err);
				fprintf(stderr, "somewm: error loading %s:\n%s\n",
					config_paths[i], enhanced_err);
				fprintf(stderr, "somewm: trying alternate configs...\n");
			} else if (!is_file_not_found) {
				/* Real error (syntax error, etc.) - notify user */
				luaA_startup_error(err);
				fprintf(stderr, "somewm: error loading %s: %s\n",
					config_paths[i], err);
				fprintf(stderr, "somewm: trying alternate configs...\n");
			}
			/* For file-not-found, silently try next config */
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

		/* Set up timeout for config execution.
		 * This catches hanging configs (infinite loops, multiple blocking calls).
		 * Uses siglongjmp for reliable abort - lua_sethook doesn't work with LuaJIT. */
		config_timeout_fired = 0;
		config_timeout_L = globalconf_L;
		sigaction(SIGALRM, &sa, &old_sa);

		/* Set up jump point for timeout abort */
		if (sigsetjmp(config_timeout_jmp, 1) != 0) {
			/* We jumped here from signal handler - config timed out */
			config_timeout_jmp_valid = 0;
			alarm(0);
			sigaction(SIGALRM, &old_sa, NULL);
			config_timeout_L = NULL;

			fprintf(stderr, "somewm: config %s FORCEFULLY ABORTED after timeout\n",
			        config_paths[i]);

			/* CRITICAL: Lua state is corrupted after siglongjmp.
			 * We must recreate it before trying the next config. */
			luaA_signal_cleanup();
			luaA_keybinding_cleanup();
			lua_close(globalconf_L);
			globalconf_L = NULL;
			globalconf.L = NULL;

			/* Reinitialize fresh Lua state */
			globalconf_L = luaA_create_fresh_state();

			if (!globalconf_L) {
				fprintf(stderr, "somewm: FATAL: failed to reinitialize Lua after timeout\n");
				break;
			}

			/* Record the error for notification */
			luaA_startup_error("Config loading timed out (exceeded 10 seconds)");

			continue;
		}
		config_timeout_jmp_valid = 1;

		alarm(10);  /* 10 second timeout */

		/* Execute with protected call using error handler */
		if (lua_pcall(globalconf_L, 0, 0, -2) == 0) {
			config_timeout_jmp_valid = 0;
			/* Success - cancel timeout and restore signal handler */
			alarm(0);
			sigaction(SIGALRM, &old_sa, NULL);
#ifdef LUAJIT_VERSION
			luaJIT_setmode(globalconf_L, 0, LUAJIT_MODE_ON);
#endif
			config_timeout_L = NULL;

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
			const char *err;

			/* Error - cancel timeout and restore signal handler */
			config_timeout_jmp_valid = 0;
			alarm(0);
			sigaction(SIGALRM, &old_sa, NULL);
#ifdef LUAJIT_VERSION
			luaJIT_setmode(globalconf_L, 0, LUAJIT_MODE_ON);
#endif
			config_timeout_L = NULL;

			/* Runtime error - already handled by error handler */
			err = lua_tostring(globalconf_L, -1);

			/* Check if this was a timeout */
			if (config_timeout_fired) {
				fprintf(stderr, "somewm: config %s timed out after 10 seconds\n",
					config_paths[i]);
				fprintf(stderr, "somewm: check for blocking io.popen() or os.execute() calls\n");
			}

			/* Accumulate runtime error for naughty notification */
			luaA_startup_error(err);

			if (i == 0 && !config_timeout_fired) {
				fprintf(stderr, "somewm: error executing %s:\n%s\n",
					config_paths[i], err);
				fprintf(stderr, "somewm: trying alternate configs...\n");
			}
			lua_pop(globalconf_L, 2);  /* Pop error and error handler */

			/* Clear naughty from package.loaded so it reloads fresh in the
			 * fallback config. This is necessary so naughty/init.lua runs
			 * again and can check startup_errors. We can't recreate the
			 * entire Lua state because screens are already registered. */
			lua_getglobal(globalconf_L, "package");
			lua_getfield(globalconf_L, -1, "loaded");
			lua_pushnil(globalconf_L);
			lua_setfield(globalconf_L, -2, "naughty");
			lua_pushnil(globalconf_L);
			lua_setfield(globalconf_L, -2, "naughty.core");
			lua_pushnil(globalconf_L);
			lua_setfield(globalconf_L, -2, "naughty.init");
			lua_pop(globalconf_L, 2);  /* Pop loaded and package */

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

/* ============================================================================
 * Lua State Recreation (for config timeout recovery)
 * ============================================================================ */

/** Create a fresh Lua state with all modules registered.
 * This is used when config loading times out and we need to try the next config.
 * It creates a new Lua state and registers all modules, but does NOT reset
 * globalconf arrays (no clients exist during initial config loading anyway).
 *
 * \return The new Lua state, or NULL on failure
 */
static lua_State *
luaA_create_fresh_state(void)
{
	lua_State *L;
	const char *cur_path;

	/* Create fresh Lua state */
	L = luaL_newstate();
	if (!L) {
		fprintf(stderr, "somewm: failed to create new Lua state\n");
		return NULL;
	}

	/* Update global pointers */
	globalconf_L = L;
	globalconf.L = L;

	/* Set error handling function */
	lualib_dofunction_on_error = luaA_dofunction_on_error;

	luaL_openlibs(L);

	/* Add AwesomeWM-compatible Lua extensions */
	luaA_fixups(L);

	/* Initialize the AwesomeWM object system */
	luaA_object_setup(L);

	/* Setup package.path */
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "path");
	cur_path = lua_tostring(L, -1);
	lua_pop(L, 1);

	lua_pushfstring(L,
		"./lua/?.lua;./lua/?/init.lua;./lua/lib/?.lua;./lua/lib/?/init.lua;"
		DATADIR "/somewm/lua/?.lua;" DATADIR "/somewm/lua/?/init.lua;"
		DATADIR "/somewm/lua/lib/?.lua;" DATADIR "/somewm/lua/lib/?/init.lua;%s",
		cur_path);
	lua_setfield(L, -2, "path");
	lua_pop(L, 1);

	/* Add user library directory */
	{
		const char *xdg_data_home = getenv("XDG_DATA_HOME");
		const char *home = getenv("HOME");
		const char *old_path;
		char user_data_dir[512];

		if (xdg_data_home && xdg_data_home[0] != '\0') {
			snprintf(user_data_dir, sizeof(user_data_dir), "%s/somewm", xdg_data_home);
		} else if (home && home[0] != '\0') {
			snprintf(user_data_dir, sizeof(user_data_dir), "%s/.local/share/somewm", home);
		} else {
			user_data_dir[0] = '\0';
		}

		if (user_data_dir[0] != '\0') {
			lua_getglobal(L, "package");
			lua_getfield(L, -1, "path");
			old_path = lua_tostring(L, -1);
			lua_pop(L, 1);

			lua_pushfstring(L, "%s/?.lua;%s/?/init.lua;%s",
				user_data_dir, user_data_dir, old_path);
			lua_setfield(L, -2, "path");
			lua_pop(L, 1);
		}
	}

	/* Re-register all Lua modules/classes */
	luaA_signal_setup(L);
	key_class_setup(L);
	tag_class_setup(L);
	window_class_setup(L);
	client_class_setup(L);
	screen_class_setup(L);
	luaA_drawable_setup(L);
	luaA_drawin_setup(L);
	luaA_timer_setup(L);
	luaA_spawn_setup(L);
	luaA_keybinding_setup(L);
	luaA_awesome_setup(L);
	luaA_root_setup(L);
	button_class_setup(L);

	/* Selection classes */
	selection_getter_class_setup(L);
	selection_acquire_class_setup(L);
	selection_transfer_class_setup(L);
	selection_watcher_class_setup(L);
	selection_setup(L);

	luaA_mouse_setup(L);
	luaA_wibox_setup(L);
	luaA_ipc_setup(L);

	/* D-Bus */
	luaA_registerlib(L, "dbus", awesome_dbus_lib);
	lua_pop(L, 1);  /* luaA_registerlib leaves table on stack */

	/* Keygrabber */
	lua_newtable(L);
	luaA_keygrabber_setup(L);
	lua_setglobal(L, "keygrabber");

	/* Mousegrabber */
	lua_newtable(L);
	luaA_mousegrabber_setup(L);
	lua_setglobal(L, "mousegrabber");

	return L;
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
