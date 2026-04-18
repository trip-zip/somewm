#include "luaa.h"
#include "draw.h"  /* Must be before globalconf.h to avoid type conflicts */
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
#include "objects/output.h"
#include "objects/drawin.h"
#include "objects/layer_surface.h"
#include "objects/drawable.h"
#include "objects/signal.h"
#include "objects/timer.h"
#include "objects/spawn.h"
#include "objects/key.h"
#include "objects/keybinding.h"
#include "objects/keygrabber.h"
#include "objects/mousegrabber.h"
#include "objects/gesture.h"
/* objects/awesome.h merged into this file */
#include "animation.h"
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
#include "objects/window.h"
#include "dbus.h"
#include "shadow.h"
#include "pam_auth.h"

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
#include <glib.h>
#include <gio/gio.h>
#include <limits.h>
#include <setjmp.h>
#include <dlfcn.h>

/* Includes merged from objects/awesome.c */
#include "systray.h"
#include "somewm_api.h"
#include "color.h"
#include <xkbcommon/xkbcommon.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/backend/wayland.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <drm_fourcc.h>
#include <cairo/cairo.h>

/* Config loading timeout state (for graceful fallback on hanging configs) */
static volatile sig_atomic_t config_timeout_fired = 0;
static lua_State *config_timeout_L = NULL;
static sigjmp_buf config_timeout_jmp;
static volatile sig_atomic_t config_timeout_jmp_valid = 0;


/* Legacy global Lua state pointer - now just an alias for globalconf.L */
lua_State *globalconf_L = NULL;

/* Global configuration structure instance */
awesome_t globalconf;

/* argv used to run somewm (stored separately from globalconf, matching
 * AwesomeWM's static awesome_argv pattern so memset of globalconf can't
 * clobber it). */
static char **somewm_argv;

void
luaA_set_argv(char **argv)
{
    somewm_argv = argv;
}

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

/* Strut Atom */
xcb_atom_t _NET_WM_STRUT_PARTIAL = 0;

/* UTF8_STRING atom for text properties */
xcb_atom_t UTF8_STRING = 0;
#endif /* XWAYLAND */

/* Global handler storage for object property miss handlers */
luaA_class_handlers_t client_handlers = {LUA_REFNIL, LUA_REFNIL};
luaA_class_handlers_t tag_handlers = {LUA_REFNIL, LUA_REFNIL};
luaA_class_handlers_t screen_handlers = {LUA_REFNIL, LUA_REFNIL};
luaA_class_handlers_t mouse_handlers = {LUA_REFNIL, LUA_REFNIL};

/* ==========================================================================
 * Lua Lock/Idle API State
 * ========================================================================== */

/* Lock state for Lua-controlled lockscreen */
static int lua_locked = 0;           /* Is session locked via Lua API? */
static int lua_authenticated = 0;    /* Has authenticate() succeeded since last lock? */
static drawin_t *lua_lock_surface = NULL;  /* Registered lock surface (wibox) */
static int lua_lock_surface_ref = LUA_NOREF;  /* Lua registry ref to prevent GC */

/* Lock cover surfaces for multi-monitor support */
#define MAX_LOCK_COVERS 16
static drawin_t *lua_lock_covers[MAX_LOCK_COVERS];
static int lua_lock_cover_refs[MAX_LOCK_COVERS];
static int lua_lock_cover_count = 0;

/* Lock/idle/DPMS API declarations in somewm_api.h */

/* Idle timeout management */
typedef struct {
    char *name;                      /* Timeout name (for lookup/removal) */
    int seconds;                     /* Timeout duration in seconds */
    int lua_callback_ref;            /* Lua registry reference to callback */
    struct wl_event_source *timer;   /* Wayland event loop timer */
    bool fired;                      /* Has this timeout fired since last activity? */
} IdleTimeout;

#define MAX_IDLE_TIMEOUTS 32
static IdleTimeout idle_timeouts[MAX_IDLE_TIMEOUTS];
static int idle_timeout_count = 0;
static bool user_is_idle = false;    /* Global idle state */

/* Flag whether idle timers have been inhibited. */
static bool idle_timers_inhibited = false;

/* Lua-level idle inhibition (set via awesome.idle_inhibit). */
static bool lua_idle_inhibited = false;

/* D-Bus library functions from dbus.c */
extern const struct luaL_Reg awesome_dbus_lib[];

/* Forward declaration */
static int luaA_dofunction_on_error(lua_State *L);

/* ==========================================================================
 * X11 compatibility stubs (AwesomeWM API parity)
 * ========================================================================== */

/** Check if a composite manager is running (X11-only stub).
 * X11: Checks _NET_WM_CM_Sn selection ownership.
 * Wayland: Always has compositing built-in.
 * \return true (Wayland always composites)
 */
static bool
composite_manager_running(void)
{
    /* X11-only: checks _NET_WM_CM_Sn selection.
     * Wayland always has compositing. */
    return true;
}

/* X11 modifier map indices (for get_modifier_name compatibility) */
#ifndef XCB_MAP_INDEX_SHIFT
#define XCB_MAP_INDEX_SHIFT   0
#define XCB_MAP_INDEX_LOCK    1
#define XCB_MAP_INDEX_CONTROL 2
#define XCB_MAP_INDEX_1       3  /* Mod1 / Alt */
#define XCB_MAP_INDEX_2       4
#define XCB_MAP_INDEX_3       5
#define XCB_MAP_INDEX_4       6  /* Super */
#define XCB_MAP_INDEX_5       7
#endif

/** Get modifier name from map index.
 * \param map_index X11 modifier map index (0-7).
 * \return Modifier name string or NULL.
 */
static const char *
get_modifier_name(int map_index)
{
    switch (map_index) {
        case XCB_MAP_INDEX_SHIFT:   return "Shift";
        case XCB_MAP_INDEX_LOCK:    return "Lock";
        case XCB_MAP_INDEX_CONTROL: return "Control";
        case XCB_MAP_INDEX_1:       return "Mod1"; /* Alt */
        case XCB_MAP_INDEX_2:       return "Mod2";
        case XCB_MAP_INDEX_3:       return "Mod3";
        case XCB_MAP_INDEX_4:       return "Mod4";
        case XCB_MAP_INDEX_5:       return "Mod5";
    }
    return NULL;
}

/** Get modifier key mappings (X11-only stub).
 * X11: Uses xcb_get_modifier_mapping to get keycodes for each modifier.
 * Wayland: Modifiers are handled via xkbcommon.
 * \return Table mapping modifier names to key tables (empty in Wayland)
 */
static int
luaA_get_modifiers(lua_State *L)
{
    /* X11-only: uses xcb_get_modifier_mapping.
     * Wayland uses xkbcommon for modifier handling. */
    lua_newtable(L);
    return 1;
}

/** Get currently active modifiers (X11-only stub).
 * X11: Queries XCB for current modifier state.
 * Wayland: Use xkbcommon state instead.
 * \return Table of active modifier names (empty in Wayland stub)
 */
static int
luaA_get_active_modifiers(lua_State *L)
{
    /* X11-only: uses XCB to query active modifiers.
     * Wayland gets modifier state from xkbcommon. */
    lua_newtable(L);
    return 1;
}

/* ==========================================================================
 * AwesomeWM API aliases (renamed functions)
 * ========================================================================== */

/* Forward declarations for aliased functions */
static int luaA_awesome_quit(lua_State *L);
static int luaA_awesome_sync(lua_State *L);
static int luaA_awesome_set_preferred_icon_size(lua_State *L);
static int luaA_awesome_get_key_name(lua_State *L);

/** AwesomeWM name: add_to_search_path (somewm: luaA_add_search_paths)
 * Note: somewm's luaA_add_search_paths() has a different signature and adds
 * all standard paths at once. This stub provides API symbol compatibility.
 */
static void
add_to_search_path(lua_State *L, const char *path)
{
    (void)L;
    (void)path;
}

/** AwesomeWM name: luaA_get_key_name (somewm: luaA_awesome_get_key_name) */
static int
luaA_get_key_name(lua_State *L)
{
    return luaA_awesome_get_key_name(L);
}

/** AwesomeWM name: luaA_quit (somewm: luaA_awesome_quit) */
static int
luaA_quit(lua_State *L)
{
    return luaA_awesome_quit(L);
}

/** AwesomeWM name: luaA_set_preferred_icon_size (somewm: luaA_awesome_set_preferred_icon_size) */
static int
luaA_set_preferred_icon_size(lua_State *L)
{
    return luaA_awesome_set_preferred_icon_size(L);
}

/** AwesomeWM name: luaA_sync (somewm: luaA_awesome_sync) */
static int
luaA_sync(lua_State *L)
{
    return luaA_awesome_sync(L);
}

/* ==========================================================================
 * Signal emitters (AwesomeWM API parity)
 * ========================================================================== */

/** Emit the "startup" signal.
 * Called after rc.lua is loaded to signal that startup is complete.
 */
void
luaA_emit_startup(void)
{
    lua_State *L = globalconf_get_lua_State();
    if (L)
        luaA_signal_emit(L, "startup", 0);
}

/** Emit the "refresh" signal.
 * Called before each display refresh to allow Lua to update state.
 */
void
luaA_emit_refresh(void)
{
    lua_State *L = globalconf_get_lua_State();
    if (L)
        luaA_signal_emit(L, "refresh", 0);
}

/* ==========================================================================
 * Debug handlers (AwesomeWM API parity)
 * ========================================================================== */

/** Handle missing property access on a Lua object.
 * Emits the "debug::index::miss" signal for debugging.
 * \param L The Lua state.
 * \param obj The object being accessed (may be NULL).
 * \return 0 (no return values).
 */
int
luaA_class_index_miss_property(lua_State *L, lua_object_t *obj)
{
    (void)obj;
    luaA_signal_emit(L, "debug::index::miss", 2);
    return 0;
}

/** Handle missing property assignment on a Lua object.
 * Emits the "debug::newindex::miss" signal for debugging.
 * \param L The Lua state.
 * \param obj The object being modified (may be NULL).
 * \return 0 (no return values).
 */
int
luaA_class_newindex_miss_property(lua_State *L, lua_object_t *obj)
{
    (void)obj;
    luaA_signal_emit(L, "debug::newindex::miss", 3);
    return 0;
}

/* ==========================================================================
 * Phase 2: Core functions (AwesomeWM API parity)
 * ========================================================================== */

/** Cleanup function called before exit or exec.
 * \param restart True if we're about to restart (exec self).
 */
void
awesome_atexit(bool restart)
{
    /* Reset signal handlers */
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGCHLD, SIG_DFL);

    /* Cleanup Lua state if not restarting (restart will exec over it) */
    if (!restart && globalconf.L) {
        luaA_cleanup();
    }
}

/** Cold-restart the compositor by exec'ing self.
 * Uses static somewm_argv (safe from globalconf memset wipe).
 * Only used as fallback; normal restart path is hot-reload.
 */
void
awesome_restart(void)
{
    awesome_atexit(true);
    execvp(somewm_argv[0], somewm_argv);
    /* If we get here, exec failed */
    warn("restart failed: execvp(%s) failed: %s", somewm_argv[0], strerror(errno));
}

/** GLib idle callback for deferred hot-reload.
 * We can't tear down the Lua state while inside a Lua pcall,
 * so we defer to the next idle iteration of the event loop.
 */
static gboolean
hot_reload_idle_callback(gpointer data)
{
    (void)data;
    luaA_hot_reload();
    return G_SOURCE_REMOVE;  /* One-shot */
}

/** awesome.exec(cmd) - Replace compositor with another program.
 * \param cmd Command to execute (parsed by shell).
 * \return Never returns on success.
 */
static int
luaA_exec(lua_State *L)
{
    const char *cmd = luaL_checkstring(L, 1);
    /* Use restart=true to skip luaA_cleanup() - we're still inside a Lua
     * call so destroying the Lua state here would be undefined behavior.
     * The exec will replace the process image anyway. */
    awesome_atexit(true);
    a_exec(cmd);
    return 0;  /* Never reached on success */
}

/** awesome.kill(pid, sig) - Send signal to a process.
 * \param pid Process ID.
 * \param sig Signal number.
 * \return true on success, false on error.
 */
static int
luaA_kill(lua_State *L)
{
    pid_t pid = luaL_checkinteger(L, 1);
    int sig = luaL_checkinteger(L, 2);
    int result = kill(pid, sig);
    lua_pushboolean(L, result == 0);
    return 1;
}

/** awesome.load_image(filename) - Load an image file.
 * \param filename Path to image file.
 * \return (surface, nil) on success, (nil, error_message) on failure.
 */
static int
luaA_load_image(lua_State *L)
{
    const char *filename = luaL_checkstring(L, 1);
    GError *error = NULL;
    cairo_surface_t *surface = draw_load_image(L, filename, &error);

    if (surface) {
        /* Push the surface - the draw module handles the Lua userdata wrapper */
        lua_pushlightuserdata(L, surface);
        lua_pushnil(L);
    } else {
        lua_pushnil(L);
        if (error) {
            lua_pushstring(L, error->message);
            g_error_free(error);
        } else {
            lua_pushliteral(L, "unknown error");
        }
    }
    return 2;
}

/** Lua panic handler - called on unprotected errors.
 * \param L The Lua state.
 * \return 0 (never returns normally).
 */
static int
luaA_panic(lua_State *L)
{
    warn("unprotected error in call to Lua API: %s", lua_tostring(L, -1));
    return 0;
}

/** awesome.restart() - Hot-reload the Lua state.
 * Defers the reload to the next idle iteration of the event loop
 * so we're not tearing down Lua while inside a Lua pcall.
 * Wayland clients survive; only the Lua VM is rebuilt.
 */
static int
luaA_restart(lua_State *L)
{
    (void)L;
    /* Defer to next event loop iteration */
    g_idle_add(hot_reload_idle_callback, NULL);
    return 0;
}

/** Convert Lua value to string (Lua 5.1 compatibility).
 * \param L The Lua state.
 * \param idx Stack index.
 * \param len Output: string length.
 * \return String representation.
 */
static const char *
luaA_tolstring(lua_State *L, int idx, size_t *len)
{
#if LUA_VERSION_NUM >= 502
    return luaL_tolstring(L, idx, len);
#else
    /* Manual conversion for Lua 5.1 */
    if (luaL_callmeta(L, idx, "__tostring")) {
        if (!lua_isstring(L, -1))
            luaL_error(L, "'__tostring' must return a string");
    } else {
        switch (lua_type(L, idx)) {
            case LUA_TNUMBER:
                lua_pushfstring(L, "%s", lua_tostring(L, idx));
                break;
            case LUA_TSTRING:
                lua_pushvalue(L, idx);
                break;
            case LUA_TBOOLEAN:
                lua_pushstring(L, lua_toboolean(L, idx) ? "true" : "false");
                break;
            case LUA_TNIL:
                lua_pushliteral(L, "nil");
                break;
            default:
                lua_pushfstring(L, "%s: %p", luaL_typename(L, idx),
                                lua_topointer(L, idx));
                break;
        }
    }
    return lua_tolstring(L, -1, len);
#endif
}

/** Convert single UTF-8 character to UTF-32 codepoint.
 * \param input UTF-8 encoded string.
 * \param length Length of input.
 * \return UTF-32 codepoint, or 0 on error.
 */
static uint32_t
one_utf8_to_utf32(const char *input, const size_t length)
{
    gunichar c = g_utf8_get_char_validated(input, length);
    if (c == (gunichar)-1 || c == (gunichar)-2)
        return 0;
    /* Verify it's a single character by checking round-trip length */
    char buf[8];
    if ((size_t)g_unichar_to_utf8(c, buf) != length)
        return 0;
    return (uint32_t)c;
}

/** Setup Unix signal name/number table in awesome.unix_signal.
 * Called during Lua initialization to populate the signal table.
 * \param L The Lua state.
 */
static void
setup_awesome_signals(lua_State *L)
{
    /* Signal setup is handled by luaA_signal_setup() in objects/signal.c */
    /* This is an alias for AwesomeWM API parity */
    luaA_signal_setup(L);
}

/** Typedef for config file validation callback (AwesomeWM pattern). */
typedef bool luaA_config_callback(const char *);

/** Find configuration file path.
 * \param xdg XDG handle (unused in somewm, kept for API compat).
 * \param confpatharg User-specified config path (or NULL).
 * \param callback Validation callback (or NULL).
 * \return Path to config file, or NULL if not found.
 */
const char *
luaA_find_config(void *xdg, const char *confpatharg,
                 luaA_config_callback *callback)
{
    (void)xdg;
    (void)callback;

    /* If user specified a path, use it */
    if (confpatharg)
        return confpatharg;

    /* custom_confpath is defined later in this file as a static variable */
    return NULL;  /* Caller should handle NULL by using default paths */
}

/** Parse rc.lua configuration file.
 * \param xdg XDG handle (unused in somewm).
 * \param confpatharg User-specified config path (or NULL).
 * \return true on success.
 */
bool
luaA_parserc(void *xdg, const char *confpatharg)
{
    (void)xdg;
    (void)confpatharg;
    /* Delegates to luaA_loadrc() which is the somewm implementation */
    luaA_loadrc();
    return true;
}

/* ==========================================================================
 * AwesomeWM API parity symbol table
 * ==========================================================================
 * These symbols exist for API parity with AwesomeWM. They're exported or
 * referenced here to ensure they're available for the api-parity tool and
 * for any code that expects AwesomeWM's exact symbol names.
 */
__attribute__((used)) static const void *awesomewm_api_parity_symbols[] = {
    (void *)composite_manager_running,
    (void *)get_modifier_name,
    (void *)luaA_get_modifiers,
    (void *)luaA_get_active_modifiers,
    (void *)add_to_search_path,
    (void *)luaA_get_key_name,
    (void *)luaA_quit,
    (void *)luaA_set_preferred_icon_size,
    (void *)luaA_sync,
    (void *)luaA_tolstring,
    (void *)one_utf8_to_utf32,
    (void *)setup_awesome_signals,
    NULL
};

/* ==========================================================================
 * awesome module (merged from objects/awesome.c)
 * ==========================================================================
 * The "awesome" global provides compositor control functions.
 * This matches AwesomeWM's luaa.c structure where the awesome module is
 * defined alongside other Lua infrastructure.
 */

/* Forward declarations for awesome module */
static int luaA_awesome_index(lua_State *L);

/** awesome.xrdb_get_value(resource_class, resource_name) - Get xrdb value
 * Delegates to Lua implementation for xrdb compatibility in Wayland.
 * \param resource_class Resource class (usually empty string)
 * \param resource_name Resource name (e.g., "background", "Xft.dpi")
 * \return Resource value string or nil if not found
 */
static int
luaA_awesome_xrdb_get_value(lua_State *L)
{
	const char *resource_class;
	const char *resource_name;

	resource_class = luaL_optstring(L, 1, "");
	resource_name = luaL_checkstring(L, 2);

	lua_getglobal(L, "require");
	lua_pushliteral(L, "gears.xresources");
	lua_call(L, 1, 1);

	lua_getfield(L, -1, "get_value");
	lua_pushstring(L, resource_class);
	lua_pushstring(L, resource_name);
	lua_call(L, 2, 1);

	return 1;
}

/** awesome.quit([code]) - Quit the compositor with an optional exit code.
 * \param L The Lua VM state.
 * \lparam code Optional exit code (default 0). Use 1 for cold restart,
 *              2 for rebuild+restart (handled by somewm-session wrapper).
 */
static int
luaA_awesome_quit(lua_State *L)
{
	globalconf.exit_code = luaL_optinteger(L, 1, 0);
	some_compositor_quit();
	return 0;
}

/** awesome.new_client_placement - Get/set new client placement mode */
static int
luaA_awesome_new_client_placement(lua_State *L)
{
	if (lua_gettop(L) >= 1) {
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
	lua_pushnumber(L, some_get_new_client_placement());
	return 1;
}

/** awesome.get_cursor_position() - Get current cursor position */
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

/** awesome.get_cursor_monitor() - Get monitor under cursor */
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

/** awesome.connect_signal(name, callback) - Connect to a global signal */
static int
luaA_awesome_connect_signal(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	const void *ref;
	luaL_checktype(L, 2, LUA_TFUNCTION);

	lua_pushvalue(L, 2);
	ref = luaA_object_ref(L, -1);

	luaA_signal_connect(name, ref);

	return 0;
}

/** awesome.disconnect_signal(name, callback) - Disconnect from a global signal */
static int
luaA_awesome_disconnect_signal(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	const void *ref;
	luaL_checktype(L, 2, LUA_TFUNCTION);

	ref = lua_topointer(L, 2);
	if (luaA_signal_disconnect(name, ref))
		luaA_object_unref(L, ref);

	return 0;
}

/** awesome.emit_signal(name, ...) - Emit a global signal */
static int
luaA_awesome_emit_signal(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	int nargs = lua_gettop(L) - 1;

	luaA_signal_emit(L, name, nargs);

	return 0;
}

/** awesome._get_key_name(keysym) - Get human-readable key name */
static int
luaA_awesome_get_key_name(lua_State *L)
{
	xkb_keysym_t keysym;
	char keysym_name[64];
	char utf8[8] = {0};

	if (lua_isnumber(L, 1)) {
		keysym = (xkb_keysym_t)lua_tonumber(L, 1);
	} else if (lua_isstring(L, 1)) {
		const char *key_str = lua_tostring(L, 1);
		keysym = xkb_keysym_from_name(key_str, XKB_KEYSYM_CASE_INSENSITIVE);
		if (keysym == XKB_KEY_NoSymbol) {
			lua_pushnil(L);
			lua_pushnil(L);
			return 2;
		}
	} else {
		lua_pushnil(L);
		lua_pushnil(L);
		return 2;
	}

	xkb_keysym_get_name(keysym, keysym_name, sizeof(keysym_name));
	lua_pushstring(L, keysym_name);

	if (xkb_keysym_to_utf8(keysym, utf8, sizeof(utf8)) > 0 && utf8[0]) {
		lua_pushstring(L, utf8);
	} else {
		lua_pushnil(L);
	}

	return 2;
}

/** awesome.xkb_get_group_names() - Get keyboard layout symbols string */
static int
luaA_awesome_xkb_get_group_names(lua_State *L)
{
	const char *symbols = some_xkb_get_group_names();

	if (symbols) {
		lua_pushstring(L, symbols);
	} else {
		const char *layout = globalconf.keyboard.xkb_layout;
		if (layout && *layout) {
			lua_pushfstring(L, "pc+%s", layout);
		} else {
			lua_pushliteral(L, "pc+us");
		}
	}
	return 1;
}

/** awesome.xkb_get_layout_group() - Get current keyboard layout index */
static int
luaA_awesome_xkb_get_layout_group(lua_State *L)
{
	struct xkb_state *state = some_xkb_get_state();
	xkb_layout_index_t group;

	if (!state) {
		lua_pushinteger(L, 0);
		return 1;
	}

	group = xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE);
	lua_pushinteger(L, (int)group);
	return 1;
}

/** awesome.xkb_set_layout_group(num) - Switch keyboard layout */
static int
luaA_awesome_xkb_set_layout_group(lua_State *L)
{
	xkb_layout_index_t group = (xkb_layout_index_t)luaL_checkinteger(L, 1);

	if (!some_xkb_set_layout_group(group)) {
		luaL_error(L, "Failed to set keyboard layout group %d", (int)group);
	}

	return 0;
}

/** awesome.register_xproperty() - Stub for AwesomeWM compatibility */
static int
luaA_awesome_register_xproperty(lua_State *L)
{
	luaL_checkstring(L, 1);
	luaL_checkstring(L, 2);
	return 0;
}

/** awesome.pixbuf_to_surface() - Convert GdkPixbuf to cairo surface */
static int
luaA_pixbuf_to_surface(lua_State *L)
{
	GdkPixbuf *pixbuf = (GdkPixbuf *) lua_touserdata(L, 1);
	cairo_surface_t *surface;

	if (!pixbuf) {
		lua_pushnil(L);
		lua_pushliteral(L, "Invalid pixbuf (expected light userdata)");
		return 2;
	}

	surface = draw_surface_from_pixbuf(pixbuf);
	if (!surface) {
		lua_pushnil(L);
		lua_pushliteral(L, "Failed to create cairo surface from pixbuf");
		return 2;
	}

	lua_pushlightuserdata(L, surface);
	return 1;
}

/** Rebuild keyboard keymap with current XKB settings */
static void
rebuild_keyboard_keymap(void)
{
	some_rebuild_keyboard_keymap();
}

/** awesome.sync() - Synchronize with the compositor */
static int
luaA_awesome_sync(lua_State *L)
{
	struct wl_display *display = some_get_display();
	if (display) {
		wl_display_flush_clients(display);
	}
	return 0;
}

/** Set a libinput pointer/touchpad setting */
static int
luaA_awesome_set_input_setting(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);

	if (strcmp(key, "tap_to_click") == 0) {
		globalconf.input.tap_to_click = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "tap_and_drag") == 0) {
		globalconf.input.tap_and_drag = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "drag_lock") == 0) {
		globalconf.input.drag_lock = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "tap_3fg_drag") == 0) {
		globalconf.input.tap_3fg_drag = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "natural_scrolling") == 0) {
		globalconf.input.natural_scrolling = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "disable_while_typing") == 0) {
		globalconf.input.disable_while_typing = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "dwtp") == 0) {
		globalconf.input.dwtp = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "left_handed") == 0) {
		globalconf.input.left_handed = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "middle_button_emulation") == 0) {
		globalconf.input.middle_button_emulation = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "scroll_method") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.scroll_method);
		globalconf.input.scroll_method = val ? strdup(val) : NULL;
	} else if (strcmp(key, "scroll_button") == 0) {
		globalconf.input.scroll_button = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "scroll_button_lock") == 0) {
		globalconf.input.scroll_button_lock = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "click_method") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.click_method);
		globalconf.input.click_method = val ? strdup(val) : NULL;
	} else if (strcmp(key, "send_events_mode") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.send_events_mode);
		globalconf.input.send_events_mode = val ? strdup(val) : NULL;
	} else if (strcmp(key, "accel_profile") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.accel_profile);
		globalconf.input.accel_profile = val ? strdup(val) : NULL;
	} else if (strcmp(key, "accel_speed") == 0) {
		globalconf.input.accel_speed = lua_tonumber(L, 2);
		globalconf.input.accel_speed_set = true;
	} else if (strcmp(key, "tap_button_map") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.tap_button_map);
		globalconf.input.tap_button_map = val ? strdup(val) : NULL;
	} else if (strcmp(key, "clickfinger_button_map") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.clickfinger_button_map);
		globalconf.input.clickfinger_button_map = val ? strdup(val) : NULL;
	} else {
		return luaL_error(L, "Unknown input setting: %s", key);
	}

	apply_input_settings_to_all_devices();
	return 0;
}

/** Free all input rules and reset the count */
static void
input_rules_free(void)
{
	for (int i = 0; i < globalconf.input_rules_count; i++) {
		InputRule *r = &globalconf.input_rules[i];
		free(r->type);
		free(r->name);
		free(r->properties.scroll_method);
		free(r->properties.click_method);
		free(r->properties.clickfinger_button_map);
		free(r->properties.send_events_mode);
		free(r->properties.accel_profile);
		free(r->properties.tap_button_map);
	}
	free(globalconf.input_rules);
	globalconf.input_rules = NULL;
	globalconf.input_rules_count = 0;
}

/** Initialize an InputSettings struct with "not set" sentinel values */
static void
input_settings_init_unset(InputSettings *s)
{
	s->tap_to_click = -2;
	s->tap_and_drag = -2;
	s->drag_lock = -2;
	s->tap_3fg_drag = -2;
	s->natural_scrolling = -2;
	s->disable_while_typing = -2;
	s->dwtp = -2;
	s->left_handed = -2;
	s->middle_button_emulation = -2;
	s->scroll_method = NULL;
	s->scroll_button = -2;
	s->scroll_button_lock = -2;
	s->click_method = NULL;
	s->clickfinger_button_map = NULL;
	s->send_events_mode = NULL;
	s->accel_profile = NULL;
	s->accel_speed = 0.0;
	s->tap_button_map = NULL;
	s->accel_speed_set = false;
}

/** Read an optional int field from a Lua table on the stack.
 * Returns the value if present, or the default sentinel if absent. */
static int
input_rule_get_int(lua_State *L, int idx, const char *field, int sentinel)
{
	int result = sentinel;
	lua_getfield(L, idx, field);
	if (!lua_isnil(L, -1))
		result = lua_tointeger(L, -1);
	lua_pop(L, 1);
	return result;
}

/** Read an optional string field from a Lua table, returning strdup'd copy or NULL. */
static char *
input_rule_get_string(lua_State *L, int idx, const char *field)
{
	char *result = NULL;
	lua_getfield(L, idx, field);
	if (lua_isstring(L, -1))
		result = strdup(lua_tostring(L, -1));
	lua_pop(L, 1);
	return result;
}

/** Set input rules from Lua.
 * Expects a table of { rule = { type=..., name=... }, properties = { ... } } entries.
 * \param L Lua state. Stack: [1] = rules table (array).
 */
static int
luaA_awesome_set_input_rules(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);

	/* Free old rules */
	input_rules_free();

	int count = luaA_rawlen(L, 1);
	if (count == 0) {
		apply_input_settings_to_all_devices();
		return 0;
	}

	globalconf.input_rules = calloc(count, sizeof(InputRule));
	if (!globalconf.input_rules)
		return luaL_error(L, "Failed to allocate input rules");
	globalconf.input_rules_count = count;

	for (int i = 1; i <= count; i++) {
		InputRule *r = &globalconf.input_rules[i - 1];
		input_settings_init_unset(&r->properties);

		lua_rawgeti(L, 1, i);  /* rules[i] */
		if (!lua_istable(L, -1)) {
			lua_pop(L, 1);
			continue;
		}

		/* Parse rule = { type = ..., name = ... } */
		lua_getfield(L, -1, "rule");
		if (lua_istable(L, -1)) {
			r->type = input_rule_get_string(L, -1, "type");
			r->name = input_rule_get_string(L, -1, "name");
		}
		lua_pop(L, 1);  /* pop rule */

		/* Parse properties = { natural_scrolling = 1, ... } */
		lua_getfield(L, -1, "properties");
		if (lua_istable(L, -1)) {
			int pidx = lua_gettop(L);
			InputSettings *p = &r->properties;

			p->tap_to_click = input_rule_get_int(L, pidx, "tap_to_click", -2);
			p->tap_and_drag = input_rule_get_int(L, pidx, "tap_and_drag", -2);
			p->drag_lock = input_rule_get_int(L, pidx, "drag_lock", -2);
			p->tap_3fg_drag = input_rule_get_int(L, pidx, "tap_3fg_drag", -2);
			p->natural_scrolling = input_rule_get_int(L, pidx, "natural_scrolling", -2);
			p->disable_while_typing = input_rule_get_int(L, pidx, "disable_while_typing", -2);
			p->dwtp = input_rule_get_int(L, pidx, "dwtp", -2);
			p->left_handed = input_rule_get_int(L, pidx, "left_handed", -2);
			p->middle_button_emulation = input_rule_get_int(L, pidx, "middle_button_emulation", -2);
			p->scroll_button = input_rule_get_int(L, pidx, "scroll_button", -2);
			p->scroll_button_lock = input_rule_get_int(L, pidx, "scroll_button_lock", -2);

			p->scroll_method = input_rule_get_string(L, pidx, "scroll_method");
			p->click_method = input_rule_get_string(L, pidx, "click_method");
			p->clickfinger_button_map = input_rule_get_string(L, pidx, "clickfinger_button_map");
			p->send_events_mode = input_rule_get_string(L, pidx, "send_events_mode");
			p->accel_profile = input_rule_get_string(L, pidx, "accel_profile");
			p->tap_button_map = input_rule_get_string(L, pidx, "tap_button_map");

			lua_getfield(L, pidx, "accel_speed");
			if (!lua_isnil(L, -1)) {
				p->accel_speed = lua_tonumber(L, -1);
				p->accel_speed_set = true;
			}
			lua_pop(L, 1);
		}
		lua_pop(L, 1);  /* pop properties */

		lua_pop(L, 1);  /* pop rules[i] */
	}

	apply_input_settings_to_all_devices();
	return 0;
}

/** Set a keyboard setting */
static int
luaA_awesome_set_keyboard_setting(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);

	if (strcmp(key, "keyboard_repeat_rate") == 0) {
		globalconf.keyboard.repeat_rate = luaL_checkinteger(L, 2);
		some_apply_keyboard_repeat_info();
	} else if (strcmp(key, "keyboard_repeat_delay") == 0) {
		globalconf.keyboard.repeat_delay = luaL_checkinteger(L, 2);
		some_apply_keyboard_repeat_info();
	} else if (strcmp(key, "xkb_layout") == 0) {
		const char *val = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
		free(globalconf.keyboard.xkb_layout);
		globalconf.keyboard.xkb_layout = strdup(val);
		rebuild_keyboard_keymap();
	} else if (strcmp(key, "xkb_variant") == 0) {
		const char *val = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
		free(globalconf.keyboard.xkb_variant);
		globalconf.keyboard.xkb_variant = strdup(val);
		rebuild_keyboard_keymap();
	} else if (strcmp(key, "xkb_options") == 0) {
		const char *val = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
		free(globalconf.keyboard.xkb_options);
		globalconf.keyboard.xkb_options = strdup(val);
		rebuild_keyboard_keymap();
	} else if (strcmp(key, "numlock") == 0) {
		some_set_numlock(lua_toboolean(L, 2));
	} else {
		return luaL_error(L, "Unknown keyboard setting: %s", key);
	}

	return 0;
}

/** Set the preferred size for client icons */
static int
luaA_awesome_set_preferred_icon_size(lua_State *L)
{
	lua_Integer size = luaL_checkinteger(L, 1);
	if (size < 0 || size > UINT32_MAX) {
		return luaL_error(L, "icon size must be between 0 and %u", UINT32_MAX);
	}
	globalconf.preferred_icon_size = (uint32_t)size;
	return 0;
}

/** awesome._test_add_output: Add a headless output for integration testing.
 * Triggers the real createmon() → updatemons() code path.
 * \param width Output width in pixels
 * \param height Output height in pixels
 * \return Output name string
 */
static int
luaA_awesome_test_add_output(lua_State *L)
{
	unsigned int width = (unsigned int)luaL_checkinteger(L, 1);
	unsigned int height = (unsigned int)luaL_checkinteger(L, 2);

	const char *name = some_test_add_output(width, height);
	if (!name)
		return luaL_error(L, "Failed to add headless output "
			"(requires headless or multi backend)");

	lua_pushstring(L, name);
	return 1;
}

/** Reload shadow settings from beautiful theme.
 * Call this after changing beautiful.shadow_* values to apply them.
 * Regenerates shadow textures and updates all existing shadows.
 */
static int
luaA_awesome_shadow_reload(lua_State *L)
{
	/* Reload config from beautiful */
	shadow_load_beautiful_defaults(L);

	/* Update all existing client shadows */
	foreach(c, globalconf.clients) {
		const shadow_config_t *config = shadow_get_effective_config(
			(*c)->shadow_config, false);
		shadow_update_config(&(*c)->shadow, (*c)->scene, config,
			(*c)->geometry.width, (*c)->geometry.height);
	}

	/* Update all existing drawin shadows */
	foreach(d, globalconf.drawins) {
		drawin_t *drawin = *d;
		const shadow_config_t *config = shadow_get_effective_config(
			drawin->shadow_config, true);
		shadow_update_config(&drawin->shadow, drawin->scene_tree, config,
			drawin->width, drawin->height);
	}

	return 0;
}

/* ==========================================================================
 * Lock API Methods
 * ========================================================================== */

/** awesome.lock() - Lock the session
 * Emits "lock::activate" signal with source="user"
 * Resets authenticated to false
 * Routes input exclusively to lock surface
 */
static int
luaA_awesome_lock(lua_State *L)
{
	if (lua_locked) {
		/* Already locked, do nothing */
		lua_pushboolean(L, 1);
		return 1;
	}

	/* EDGE-1: Refuse to lock without a registered lock surface.
	 * Locking without a surface leaves the user with no way to authenticate
	 * and no recovery path (VT switch is also blocked). */
	if (!lua_lock_surface) {
		fprintf(stderr, "somewm: lock() called without a registered lock surface, refusing to lock\n");
		lua_pushboolean(L, 0);
		return 1;
	}

	/* EDGE-3: Refuse to lock if ext-session-lock is active.
	 * Two independent lock mechanisms competing causes undefined behavior. */
	if (some_is_ext_session_locked()) {
		fprintf(stderr, "somewm: lock() called while ext-session-lock is active, refusing\n");
		lua_pushboolean(L, 0);
		return 1;
	}

	lua_locked = 1;
	lua_authenticated = 0;  /* Reset auth on new lock */

	/* Activate lock in compositor (input routing, layer changes) */
	some_activate_lua_lock();

	/* Emit lock::activate signal with source="user" */
	lua_pushliteral(L, "user");
	luaA_emit_signal_global_with_stack(L, "lock::activate", 1);

	lua_pushboolean(L, 1);
	return 1;
}

/** awesome.unlock() - Unlock the session
 * ONLY succeeds if authenticated=true (C-enforced security)
 * Returns: boolean (true if unlocked, false if auth required)
 */
static int
luaA_awesome_unlock(lua_State *L)
{
	if (!lua_locked) {
		/* Not locked, trivially "unlocked" */
		lua_pushboolean(L, 1);
		return 1;
	}

	if (!lua_authenticated) {
		/* Auth required - refuse to unlock */
		lua_pushboolean(L, 0);
		return 1;
	}

	/* Clear lock state BEFORE deactivating so focusclient() works */
	lua_locked = 0;
	lua_authenticated = 0;

	/* Deactivate lock in compositor (restores focus) */
	some_deactivate_lua_lock();

	/* Emit lock::deactivate signal */
	luaA_emit_signal_global("lock::deactivate");

	lua_pushboolean(L, 1);
	return 1;
}

/** Resolve a drawin from either a drawin directly or a wibox table with a
 * .drawin field. Returns NULL if the argument is neither. */
static drawin_t *
resolve_drawin_arg(lua_State *L, int arg)
{
	drawin_t *d = luaA_todrawin(L, arg);
	if (!d && lua_istable(L, arg)) {
		lua_getfield(L, arg, "drawin");
		if (!lua_isnil(L, -1))
			d = luaA_todrawin(L, -1);
		lua_pop(L, 1);
	}
	return d;
}

/** awesome.set_lock_surface(wibox) - Register the interactive lock surface.
 * When locked, only this surface (and registered covers) receive input.
 * Accepts either a drawin directly or a wibox table (which has a .drawin field).
 */
static int
luaA_awesome_set_lock_surface(lua_State *L)
{
	int arg = 1;
	drawin_t *d = resolve_drawin_arg(L, arg);

	if (!d) {
		return luaL_error(L, "expected drawin or wibox, got %s",
		                  luaL_typename(L, arg));
	}

	/* Clear old reference if any */
	if (lua_lock_surface_ref != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX, lua_lock_surface_ref);
		lua_lock_surface_ref = LUA_NOREF;
	}

	/* Store reference to prevent GC (store the original arg, wibox or drawin) */
	lua_pushvalue(L, arg);
	lua_lock_surface_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_lock_surface = d;

	return 0;
}

/** awesome.clear_lock_surface() - Unregister the lock surface */
static int
luaA_awesome_clear_lock_surface(lua_State *L)
{
	if (lua_lock_surface_ref != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX, lua_lock_surface_ref);
		lua_lock_surface_ref = LUA_NOREF;
	}
	lua_lock_surface = NULL;

	return 0;
}

/** Remove a lock cover at the given index and shift remaining entries down. */
static void
remove_lock_cover_at(lua_State *L, int idx)
{
	luaL_unref(L, LUA_REGISTRYINDEX, lua_lock_cover_refs[idx]);
	for (int j = idx; j < lua_lock_cover_count - 1; j++) {
		lua_lock_covers[j] = lua_lock_covers[j + 1];
		lua_lock_cover_refs[j] = lua_lock_cover_refs[j + 1];
	}
	lua_lock_cover_count--;
}

/** awesome.add_lock_cover(wibox) - Register a cover surface for multi-monitor lock.
 * Cover surfaces are promoted to LyrBlock on lock activation to hide desktop
 * content on secondary monitors. */
static int
luaA_awesome_add_lock_cover(lua_State *L)
{
	int arg = 1;
	drawin_t *d = resolve_drawin_arg(L, arg);

	if (!d)
		return luaL_error(L, "expected drawin or wibox, got %s",
		                  luaL_typename(L, arg));

	/* Check if already registered */
	for (int i = 0; i < lua_lock_cover_count; i++) {
		if (lua_lock_covers[i] == d)
			return 0;
	}

	if (lua_lock_cover_count >= MAX_LOCK_COVERS)
		return luaL_error(L, "too many lock covers (max %d)", MAX_LOCK_COVERS);

	lua_pushvalue(L, arg);
	lua_lock_cover_refs[lua_lock_cover_count] = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_lock_covers[lua_lock_cover_count] = d;
	lua_lock_cover_count++;

	if (lua_locked)
		some_promote_lock_cover(d);

	return 0;
}

/** awesome.remove_lock_cover(wibox) - Unregister a cover surface */
static int
luaA_awesome_remove_lock_cover(lua_State *L)
{
	int arg = 1;
	drawin_t *d = resolve_drawin_arg(L, arg);

	if (!d)
		return 0;

	for (int i = 0; i < lua_lock_cover_count; i++) {
		if (lua_lock_covers[i] == d) {
			remove_lock_cover_at(L, i);
			return 0;
		}
	}

	return 0;
}

/** awesome.clear_lock_covers() - Unregister all cover surfaces */
static int
luaA_awesome_clear_lock_covers(lua_State *L)
{
	for (int i = 0; i < lua_lock_cover_count; i++) {
		luaL_unref(L, LUA_REGISTRYINDEX, lua_lock_cover_refs[i]);
		lua_lock_covers[i] = NULL;
	}
	lua_lock_cover_count = 0;

	return 0;
}

/** awesome.authenticate(password) - Verify password via PAM
 * Returns true if password matches current user
 * On success, sets authenticated=true (allowing unlock())
 * On failure, authenticated remains false
 */
static int
luaA_awesome_authenticate(lua_State *L)
{
	const char *password = luaL_checkstring(L, 1);

	/* Authenticate via PAM (from pam_auth.c)
	 * Note: pam_authenticate_user() clears the password from memory */
	int success = pam_authenticate_user(password);

	if (success) {
		lua_authenticated = 1;
	} else {
		luaA_emit_signal_global_with_stack(L, "lock::auth_failed", 0);
	}

	lua_pushboolean(L, success);
	return 1;
}

/* ==========================================================================
 * Idle Timeout API
 * ========================================================================== */

/** Timer callback when an idle timeout fires */
static int
idle_timeout_callback(void *data)
{
	IdleTimeout *timeout = data;
	lua_State *L = globalconf_get_lua_State();

	/* Mark as fired so it doesn't fire again until activity resets it */
	timeout->fired = true;

	/* Emit idle::start signal on first timeout (user became idle) */
	if (!user_is_idle) {
		user_is_idle = true;
		luaA_emit_signal_global_with_stack(L, "idle::start", 0);
	}

	/* Call the Lua callback */
	lua_rawgeti(L, LUA_REGISTRYINDEX, timeout->lua_callback_ref);
	if (lua_pcall(L, 0, 0, 0) != 0) {
		warn("idle timeout '%s' callback error: %s",
		     timeout->name, lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	return 0;  /* Don't repeat (one-shot timer) */
}

/** Find an idle timeout by name, returns index or -1 if not found */
static int
find_idle_timeout(const char *name)
{
	for (int i = 0; i < idle_timeout_count; i++) {
		if (idle_timeouts[i].name && strcmp(idle_timeouts[i].name, name) == 0)
			return i;
	}
	return -1;
}

/** Remove an idle timeout at a given index */
static void
remove_idle_timeout_at(int idx)
{
	lua_State *L = globalconf_get_lua_State();

	if (idx < 0 || idx >= idle_timeout_count)
		return;

	IdleTimeout *timeout = &idle_timeouts[idx];

	/* Clean up resources */
	if (timeout->timer)
		wl_event_source_remove(timeout->timer);
	if (timeout->lua_callback_ref != LUA_NOREF)
		luaL_unref(L, LUA_REGISTRYINDEX, timeout->lua_callback_ref);
	free(timeout->name);

	/* Shift remaining timeouts down */
	for (int i = idx; i < idle_timeout_count - 1; i++)
		idle_timeouts[i] = idle_timeouts[i + 1];

	idle_timeout_count--;
}

static void
reset_idle_timer(IdleTimeout *timeout) {
	timeout->fired = false;
	if (timeout->timer) {
		/* Disable timer if idle timers are inhibited. */
		int ms_delay = idle_timers_inhibited ? 0 : timeout->seconds * 1000;
		wl_event_source_timer_update(timeout->timer, ms_delay);
	}
}

/* Update all idle timers, i.e., update timer with 0 or timeout depending on
 * inhibition. */
static void
reset_all_idle_timers()
{
	for (int i = 0; i < idle_timeout_count; i++) {
		IdleTimeout *timeout = &idle_timeouts[i];
		reset_idle_timer(timeout);
	}
}

/* Set inhibit state for all idle timers and reset timers. */
void
some_idle_timers_set_inhibit(bool inhibit)
{
	idle_timers_inhibited = inhibit;
	reset_all_idle_timers();
}

/* Query Lua-level idle inhibition (for somewm.c idle notifier). */
bool
some_is_lua_idle_inhibited(void)
{
	return lua_idle_inhibited;
}

/** awesome.set_idle_timeout(name, seconds, callback)
 * Add or update a named idle timeout.
 * Multiple timeouts can be active simultaneously.
 * Callbacks fire in order when idle (shortest first).
 */
static int
luaA_awesome_set_idle_timeout(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	int seconds = luaL_checkinteger(L, 2);
	luaL_checktype(L, 3, LUA_TFUNCTION);

	if (seconds <= 0)
		return luaL_error(L, "idle timeout seconds must be positive");

	/* Check if timeout with this name already exists */
	int existing = find_idle_timeout(name);
	if (existing >= 0) {
		/* Remove existing timeout before adding new one */
		remove_idle_timeout_at(existing);
	}

	if (idle_timeout_count >= MAX_IDLE_TIMEOUTS)
		return luaL_error(L, "maximum number of idle timeouts (%d) reached", MAX_IDLE_TIMEOUTS);

	/* Store callback in registry */
	lua_pushvalue(L, 3);
	int callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Create the timeout entry */
	IdleTimeout *timeout = &idle_timeouts[idle_timeout_count];
	timeout->name = strdup(name);
	timeout->seconds = seconds;
	timeout->lua_callback_ref = callback_ref;

	/* Create and arm the timer */
	timeout->timer = wl_event_loop_add_timer(some_get_event_loop(), idle_timeout_callback, timeout);
	reset_idle_timer(timeout);

	idle_timeout_count++;

	return 0;
}

/** awesome.clear_idle_timeout(name)
 * Remove a named idle timeout.
 */
static int
luaA_awesome_clear_idle_timeout(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);

	int idx = find_idle_timeout(name);
	if (idx >= 0)
		remove_idle_timeout_at(idx);

	return 0;
}

/** awesome.clear_all_idle_timeouts()
 * Remove all idle timeouts.
 */
static int
luaA_awesome_clear_all_idle_timeouts(lua_State *L)
{
	(void)L;

	while (idle_timeout_count > 0)
		remove_idle_timeout_at(idle_timeout_count - 1);

	return 0;
}

/** Internal DPMS wake function (no signal emission).
 * Wakes all monitors that are currently asleep.
 * Returns true if any monitor was woken.
 */
static bool
dpms_wake_all_monitors(void)
{
	struct wl_list *monitors = some_get_monitors();
	Monitor *m;
	struct wlr_output_state state;
	bool any_woken = false;

	wl_list_for_each(m, monitors, link) {
		if (!m->asleep)
			continue;

		m->gamma_lut_changed = 1;
		m->asleep = 0;

		if (!wlr_output_is_wl(m->wlr_output)) {
			wlr_output_state_init(&state);
			wlr_output_state_set_enabled(&state, true);
			wlr_output_commit_state(m->wlr_output, &state);
			wlr_output_state_finish(&state);
		}
		any_woken = true;
	}
	return any_woken;
}

/** Called from somewm.c when user activity is detected.
 * Wakes DPMS, resets all idle timers, and emits idle::stop if user was idle.
 */
void
some_notify_activity(void)
{
	lua_State *L = globalconf_get_lua_State();

	/* Wake displays from DPMS if any are asleep */
	if (dpms_wake_all_monitors()) {
		luaA_emit_signal_global_with_stack(L, "dpms::on", 0);
	}

	/* Emit idle::stop signal if user was idle */
	if (user_is_idle) {
		user_is_idle = false;
		luaA_emit_signal_global_with_stack(L, "idle::stop", 0);
	}

	/* Reset all idle timers */
	if (!idle_timers_inhibited)
		reset_all_idle_timers();
}

/* ==========================================================================
 * DPMS (Display Power Management) API
 * ========================================================================== */

/** awesome.dpms_off() - Turn off all displays
 * Sets all monitors to DPMS off (sleep) state
 */
static int
luaA_awesome_dpms_off(lua_State *L)
{
	struct wl_list *monitors = some_get_monitors();
	Monitor *m;
	struct wlr_output_state state;
	bool any_changed = false;

	wl_list_for_each(m, monitors, link) {
		if (m->asleep)
			continue;  /* Already off */

		m->gamma_lut_changed = 1;  /* Reapply gamma when re-enabling */
		m->asleep = 1;

		/* Actually disable the output for backends that support it.
		 * Skip Wayland backend: wlr_output_commit_state blocks on
		 * re-enable because it needs a protocol roundtrip. */
		if (!wlr_output_is_wl(m->wlr_output)) {
			wlr_output_state_init(&state);
			wlr_output_state_set_enabled(&state, false);
			wlr_output_commit_state(m->wlr_output, &state);
			wlr_output_state_finish(&state);
		}
		any_changed = true;
	}

	if (any_changed)
		luaA_emit_signal_global_with_stack(L, "dpms::off", 0);
	return 0;
}

/** awesome.dpms_on() - Turn on all displays
 * Wakes all monitors from DPMS off state
 */
static int
luaA_awesome_dpms_on(lua_State *L)
{
	if (dpms_wake_all_monitors())
		luaA_emit_signal_global_with_stack(L, "dpms::on", 0);
	return 0;
}

/** Notify that a drawin is being destroyed.
 * Clears any lock surface/cover pointers that reference this drawin.
 * Called from drawin_wipe() to prevent dangling pointers (EDGE-2).
 */
void
some_notify_drawin_destroyed(drawin_t *w)
{
	if (!w)
		return;

	lua_State *L = globalconf_get_lua_State();

	/* Check if this was the lock surface */
	if (w == lua_lock_surface) {
		if (lua_lock_surface_ref != LUA_NOREF) {
			luaL_unref(L, LUA_REGISTRYINDEX, lua_lock_surface_ref);
			lua_lock_surface_ref = LUA_NOREF;
		}
		lua_lock_surface = NULL;

		/* If locked with no lock surface, force-unlock to avoid
		 * bricking the session (no UI, no VT switch, no recovery) */
		if (lua_locked) {
			fprintf(stderr, "somewm: CRITICAL: lock surface destroyed while locked, forcing unlock\n");
			lua_locked = 0;
			lua_authenticated = 0;
			some_deactivate_lua_lock();
			luaA_emit_signal_global("lock::deactivate");
		}
	}

	/* Check if this was a lock cover */
	for (int i = 0; i < lua_lock_cover_count; i++) {
		if (lua_lock_covers[i] == w) {
			remove_lock_cover_at(L, i);
			break;
		}
	}
}

/* Getter functions for somewm.c to query lock state */
int some_is_lua_locked(void) { return lua_locked; }
drawin_t *some_get_lua_lock_surface(void) { return lua_lock_surface; }
drawin_t **some_get_lua_lock_covers(int *count) {
	*count = lua_lock_cover_count;
	return lua_lock_covers;
}

bool some_is_lock_drawin(drawin_t *d) {
	if (!d) return false;
	if (d == lua_lock_surface) return true;
	for (int i = 0; i < lua_lock_cover_count; i++) {
		if (lua_lock_covers[i] == d)
			return true;
	}
	return false;
}

/* awesome module methods */
#ifdef SOMEWM_BENCH
void bench_frame_stats_get(uint64_t *count, uint64_t *min_ns, uint64_t *max_ns,
                           uint64_t *avg_ns, uint64_t *p99_ns);
void bench_frame_stats_reset(void);

static int
luaA_awesome_bench_stats(lua_State *L)
{
    lua_newtable(L);

    /* Signal counters */
    lua_pushinteger(L, (lua_Integer)bench_signal_emit_count);
    lua_setfield(L, -2, "signal_emit_count");
    lua_pushinteger(L, (lua_Integer)bench_signal_handler_calls);
    lua_setfield(L, -2, "signal_handler_calls");
    lua_pushinteger(L, (lua_Integer)bench_signal_lookup_misses);
    lua_setfield(L, -2, "signal_lookup_misses");

    /* Frame timing */
    uint64_t count, min_ns, max_ns, avg_ns, p99_ns;
    bench_frame_stats_get(&count, &min_ns, &max_ns, &avg_ns, &p99_ns);
    lua_pushinteger(L, (lua_Integer)count);
    lua_setfield(L, -2, "refresh_count");
    lua_pushnumber(L, (double)min_ns / 1000.0);
    lua_setfield(L, -2, "refresh_min_us");
    lua_pushnumber(L, (double)max_ns / 1000.0);
    lua_setfield(L, -2, "refresh_max_us");
    lua_pushnumber(L, (double)avg_ns / 1000.0);
    lua_setfield(L, -2, "refresh_avg_us");
    lua_pushnumber(L, (double)p99_ns / 1000.0);
    lua_setfield(L, -2, "refresh_p99_us");

    /* Lua memory */
    lua_pushnumber(L, lua_gc(L, LUA_GCCOUNT, 0) + lua_gc(L, LUA_GCCOUNTB, 0) / 1024.0);
    lua_setfield(L, -2, "lua_memory_kb");

    return 1;
}

static int
luaA_awesome_bench_reset(lua_State *L)
{
    (void)L;
    bench_signal_counters_reset();
    bench_frame_stats_reset();
    return 0;
}
#endif

const luaL_Reg awesome_methods[] = {
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
	{ "xkb_get_layout_group", luaA_awesome_xkb_get_layout_group },
	{ "xkb_set_layout_group", luaA_awesome_xkb_set_layout_group },
	{ "xrdb_get_value", luaA_awesome_xrdb_get_value },
	{ "register_xproperty", luaA_awesome_register_xproperty },
	{ "pixbuf_to_surface", luaA_pixbuf_to_surface },
	{ "systray", luaA_systray },
	{ "sync", luaA_awesome_sync },
	{ "_set_input_setting", luaA_awesome_set_input_setting },
	{ "_set_input_rules", luaA_awesome_set_input_rules },
	{ "_set_keyboard_setting", luaA_awesome_set_keyboard_setting },
	{ "set_preferred_icon_size", luaA_awesome_set_preferred_icon_size },
	{ "exec", luaA_exec },
	{ "kill", luaA_kill },
	{ "load_image", luaA_load_image },
	{ "restart", luaA_restart },
	{ "shadow_reload", luaA_awesome_shadow_reload },
	{ "_test_add_output", luaA_awesome_test_add_output },
	/* Lock API methods */
	{ "lock", luaA_awesome_lock },
	{ "unlock", luaA_awesome_unlock },
	{ "set_lock_surface", luaA_awesome_set_lock_surface },
	{ "clear_lock_surface", luaA_awesome_clear_lock_surface },
	{ "add_lock_cover", luaA_awesome_add_lock_cover },
	{ "remove_lock_cover", luaA_awesome_remove_lock_cover },
	{ "clear_lock_covers", luaA_awesome_clear_lock_covers },
	{ "authenticate", luaA_awesome_authenticate },
	/* Idle timeout API methods */
	{ "set_idle_timeout", luaA_awesome_set_idle_timeout },
	{ "clear_idle_timeout", luaA_awesome_clear_idle_timeout },
	{ "clear_all_idle_timeouts", luaA_awesome_clear_all_idle_timeouts },
	/* Animation API */
	{ "start_animation", luaA_start_animation },
	/* DPMS (display power management) API methods */
	{ "dpms_off", luaA_awesome_dpms_off },
	{ "dpms_on", luaA_awesome_dpms_on },
#ifdef SOMEWM_BENCH
	{ "bench_stats", luaA_awesome_bench_stats },
	{ "bench_reset", luaA_awesome_bench_reset },
#endif
	{ NULL, NULL }
};

/** awesome.__index handler for property access */
static int
luaA_awesome_index(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	if (A_STREQ(key, "version")) {
		lua_pushstring(L, VERSION);
		return 1;
	}

	if (A_STREQ(key, "release")) {
		lua_pushliteral(L, "somewm");
		return 1;
	}

	if (A_STREQ(key, "startup_errors")) {
		if (globalconf.startup_errors.len == 0)
			return 0;
		lua_pushstring(L, globalconf.startup_errors.s);
		return 1;
	}

	if (A_STREQ(key, "x11_fallback_info")) {
		if (!globalconf.x11_fallback.config_path)
			return 0;

		lua_newtable(L);

		lua_pushstring(L, globalconf.x11_fallback.config_path);
		lua_setfield(L, -2, "config_path");

		lua_pushinteger(L, globalconf.x11_fallback.line_number);
		lua_setfield(L, -2, "line_number");

		lua_pushstring(L, globalconf.x11_fallback.pattern_desc);
		lua_setfield(L, -2, "pattern");

		lua_pushstring(L, globalconf.x11_fallback.suggestion);
		lua_setfield(L, -2, "suggestion");

		if (globalconf.x11_fallback.line_content) {
			lua_pushstring(L, globalconf.x11_fallback.line_content);
			lua_setfield(L, -2, "line_content");
		}

		return 1;
	}

	if (A_STREQ(key, "log_level")) {
		const char *level_str = "error";
		switch (globalconf.log_level) {
			case 0: level_str = "silent"; break;
			case 1: level_str = "error"; break;
			case 2: level_str = "info"; break;
			case 3: level_str = "debug"; break;
		}
		lua_pushstring(L, level_str);
		return 1;
	}

	if (A_STREQ(key, "api_level")) {
		lua_pushinteger(L, globalconf.api_level);
		return 1;
	}

	if (A_STREQ(key, "bypass_surface_visibility")) {
		lua_pushboolean(L, globalconf.appearance.bypass_surface_visibility);
		return 1;
	}

	if (A_STREQ(key, "startup")) {
		lua_pushboolean(L, globalconf.loop == NULL);
		return 1;
	}

	/* Lock API properties */
	if (A_STREQ(key, "locked")) {
		lua_pushboolean(L, lua_locked);
		return 1;
	}

	if (A_STREQ(key, "lock_surface")) {
		if (lua_lock_surface) {
			luaA_object_push(L, lua_lock_surface);
		} else {
			lua_pushnil(L);
		}
		return 1;
	}

	if (A_STREQ(key, "lock_mechanism")) {
		if (lua_locked)
			lua_pushliteral(L, "lua");
		else if (some_is_ext_session_locked())
			lua_pushliteral(L, "ext");
		else
			lua_pushnil(L);
		return 1;
	}

	/* Idle API properties */
	if (A_STREQ(key, "idle")) {
		lua_pushboolean(L, user_is_idle);
		return 1;
	}

	if (A_STREQ(key, "idle_inhibit")) {
		lua_pushboolean(L, lua_idle_inhibited);
		return 1;
	}

	if (A_STREQ(key, "idle_inhibited")) {
		lua_pushboolean(L, some_is_idle_inhibited() || lua_idle_inhibited);
		return 1;
	}

	if (A_STREQ(key, "inhibitors")) {
		return some_push_idle_inhibitors(L);
	}

	if (A_STREQ(key, "inhibitor_count")) {
		lua_pushinteger(L, some_idle_inhibitor_count());
		return 1;
	}

	if (A_STREQ(key, "idle_timeouts")) {
		/* Return table of {name = {seconds = N, fired = bool}, ...} */
		lua_createtable(L, 0, idle_timeout_count);
		for (int i = 0; i < idle_timeout_count; i++) {
			lua_createtable(L, 0, 2);
			lua_pushinteger(L, idle_timeouts[i].seconds);
			lua_setfield(L, -2, "seconds");
			lua_pushboolean(L, idle_timeouts[i].fired);
			lua_setfield(L, -2, "fired");
			lua_setfield(L, -2, idle_timeouts[i].name);
		}
		return 1;
	}

	/* DPMS state property */
	if (A_STREQ(key, "dpms_state")) {
		/* Return table of {output_name = "on"/"off", ...} */
		struct wl_list *monitors = some_get_monitors();
		Monitor *m;
		lua_newtable(L);
		wl_list_for_each(m, monitors, link) {
			lua_pushstring(L, m->asleep ? "off" : "on");
			lua_setfield(L, -2, m->wlr_output->name);
		}
		return 1;
	}

	lua_rawget(L, 1);
	return 1;
}

/** awesome.__newindex handler for property setting */
static int
luaA_awesome_newindex(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	if (A_STREQ(key, "log_level")) {
		const char *val = luaL_checkstring(L, 3);
		int new_level = 1;

		if (strcmp(val, "silent") == 0)      new_level = 0;
		else if (strcmp(val, "error") == 0)  new_level = 1;
		else if (strcmp(val, "info") == 0)   new_level = 2;
		else if (strcmp(val, "debug") == 0)  new_level = 3;

		globalconf.log_level = new_level;
		wlr_log_init(new_level, NULL);

		return 0;
	}

	if (A_STREQ(key, "bypass_surface_visibility")) {
		globalconf.appearance.bypass_surface_visibility = lua_toboolean(L, 3);
		return 0;
	}

	if (A_STREQ(key, "idle_inhibit")) {
		lua_idle_inhibited = lua_toboolean(L, 3);
		some_recompute_idle_inhibit();
		return 0;
	}

	lua_rawset(L, 1);
	return 0;
}

/** Setup the awesome Lua module */
void
luaA_awesome_setup(lua_State *L)
{
	luaA_openlib(L, "awesome", awesome_methods, NULL);

	lua_getglobal(L, "awesome");
	lua_newtable(L);
	lua_pushcfunction(L, luaA_awesome_index);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, luaA_awesome_newindex);
	lua_setfield(L, -2, "__newindex");
	lua_setmetatable(L, -2);
	lua_pop(L, 1);

	lua_getglobal(L, "awesome");

	lua_newtable(L);

	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe1);
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Shift");

	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe3);
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Control");

	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe9);
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod1");

	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffeb);
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod4");

	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xfe03);
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod5");

	lua_setfield(L, -2, "_modifiers");

	lua_newtable(L);
	lua_setfield(L, -2, "_active_modifiers");

	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "composite_manager_running");

	lua_pushstring(L, DATADIR "/somewm/themes");
	lua_setfield(L, -2, "themes_path");

	lua_pushliteral(L, "");
	lua_setfield(L, -2, "conffile");

	lua_pop(L, 1);
}

/** Set the conffile path in awesome.conffile */
void
luaA_awesome_set_conffile(lua_State *L, const char *conffile)
{
	lua_getglobal(L, "awesome");
	lua_pushstring(L, conffile);
	lua_setfield(L, -2, "conffile");
	lua_pop(L, 1);
}

/* End of awesome module code */

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

	/* Strut Atom */
	cookies[i++] = xcb_intern_atom(conn, 0, 21, "_NET_WM_STRUT_PARTIAL");

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

	/* Strut Atom */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { _NET_WM_STRUT_PARTIAL = reply->atom; free(reply); }

	/* UTF8_STRING */
	reply = xcb_intern_atom_reply(conn, cookies[i++], NULL);
	if (reply) { UTF8_STRING = reply->atom; free(reply); }

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

	/* Set panic handler for unprotected errors (AwesomeWM API parity) */
	lua_atpanic(globalconf_L, luaA_panic);

	/* Initialize globalconf structure */
	globalconf_init(globalconf_L);

	/* Keep globalconf_L in sync with globalconf.L for legacy code */
	globalconf_L = globalconf.L;

	/* Set error handling function */
	lualib_dofunction_on_error = luaA_dofunction_on_error;

	luaL_openlibs(globalconf_L);

	/* Add AwesomeWM-compatible Lua extensions */
	luaA_fixups(globalconf_L);

	log_info("Lua %s initialized", LUA_VERSION);

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
	output_class_setup(globalconf_L);
	luaA_drawable_setup(globalconf_L);
	luaA_drawin_setup(globalconf_L);
	layer_surface_class_setup(globalconf_L);  /* Layer shell surface class */
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

	/* Setup gesture module (somewm-specific: touchpad gesture bridge) */
	lua_newtable(globalconf_L);
	luaA_gesture_setup(globalconf_L);
	lua_setglobal(globalconf_L, "_gesture");

	/* Setup keygrabber test helper (somewm-specific: inject for tests) */
	lua_newtable(globalconf_L);
	luaA_keygrabber_test_setup(globalconf_L);
	lua_setglobal(globalconf_L, "_keygrabber");

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

	/* GTK/GDK loading via LGI - display init during config load.
	 * GTK: somewm preloads empty lgi.override.Gtk to prevent deadlock,
	 *       but display-dependent GTK features won't work.
	 * GDK: no mitigation exists, will deadlock. */
	{"lgi.require(\"Gtk", "lgi.require(\"Gtk\") - GTK loading (partially mitigated)",
	 "somewm prevents the deadlock, but display-dependent GTK features won't work", SEVERITY_WARNING},
	{"lgi.require('Gtk", "lgi.require('Gtk') - GTK loading (partially mitigated)",
	 "somewm prevents the deadlock, but display-dependent GTK features won't work", SEVERITY_WARNING},
	{"lgi.require(\"Gdk", "lgi.require(\"Gdk\") - GDK initialization deadlock",
	 "GDK init connects to display server and will deadlock. Load lazily after startup", SEVERITY_CRITICAL},
	{"lgi.require('Gdk", "lgi.require('Gdk') - GDK initialization deadlock",
	 "GDK init connects to display server and will deadlock. Load lazily after startup", SEVERITY_CRITICAL},

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

/** Check if a line contains "somewm:ignore" suppression marker.
 * Allows users to suppress pattern detection on specific lines, e.g.:
 *   local cmd = "flameshot gui" -- somewm:ignore guarded by runtime check
 */
static bool
line_has_suppression(const char *line_start, int line_len)
{
	if (line_len < 13)  /* strlen("somewm:ignore") */
		return false;
	int len = line_len < 200 ? line_len : 200;
	char buf[201];
	memcpy(buf, line_start, len);
	buf[len] = '\0';
	return strstr(buf, "somewm:ignore") != NULL;
}

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

			/* Skip lines with somewm:ignore suppression */
			if (line_has_suppression(line_start, line_len))
				continue;

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

		/* Skip if line is a Lua comment (starts with -- after whitespace) */
		{
			const char *line_start = pos;
			while (line_start > content && *(line_start - 1) != '\n')
				line_start--;
			const char *p = line_start;
			while (p < pos && (*p == ' ' || *p == '\t'))
				p++;
			if (p[0] == '-' && p[1] == '-') {
				pos += 7;
				continue;
			}
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
		    strncmp(module_name, "cjson.", 6) == 0 ||
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
		snprintf(module_path, sizeof(module_path), "%s", module_name);

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

			/* Skip lines with somewm:ignore suppression */
			if (line_has_suppression(line_start, line_len))
				continue;

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
 * \param min_severity Minimum severity for non-zero exit (0=info, 1=warning, 2=critical)
 * \return Exit code (0=ok, 1=warnings, 2=critical)
 */
int
luaA_check_config(const char *config_path, bool use_color, int min_severity)
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

	/* Determine exit code based on min_severity filter.
	 * The report always shows all issues; the filter only affects exit code.
	 * min_severity: 0=info, 1=warning, 2=critical */
	{
		int highest = -1;
		if (check_counts[SEVERITY_CRITICAL] > 0)
			highest = SEVERITY_CRITICAL;
		else if (check_counts[SEVERITY_WARNING] > 0)
			highest = SEVERITY_WARNING;
		else if (check_counts[SEVERITY_INFO] > 0)
			highest = SEVERITY_INFO;

		if (highest >= 0 && highest >= min_severity)
			result = (highest == SEVERITY_CRITICAL) ? 2 : 1;
		else
			result = 0;
	}

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

/** Remove all GLib sources registered by Lua code and bump the Lgi closure
 * guard generation. This prevents stale FFI closures from dispatching against
 * a dead Lua state (either closed after config timeout or leaked after
 * hot-reload).
 *
 * \param label Caller label for the log message (e.g. "config-timeout" or "hot-reload").
 */
static void
luaA_cleanup_stale_glib_sources(const char *label)
{
	/* Remove all GLib sources registered by Lua code (Lgi, awful.spawn,
	 * dbus watchers, timers, etc.). These sources hold FFI closures with
	 * lua_State* pointers to the old Lua VM. If GLib dispatches them after
	 * state teardown, lua_rawgeti(freed_L, ...) -> SEGV.
	 *
	 * Probe first to get the exact upper bound - all Lua-registered sources
	 * have IDs in [baseline+1, probe_id-1]. No guesswork needed. */
	{
		GMainContext *ctx = g_main_context_default();
		guint baseline = globalconf.glib_source_baseline;
		GSource *probe = g_idle_source_new();
		guint upper = g_source_attach(probe, ctx);
		g_source_destroy(probe);
		g_source_unref(probe);

		guint removed = 0;
		for (guint id = baseline + 1; id < upper; id++) {
			GSource *src = g_main_context_find_source_by_id(ctx, id);
			if (src) {
				g_source_destroy(src);
				removed++;
			}
		}
		globalconf.glib_source_baseline = upper;
		fprintf(stderr, "somewm: %s: removed %u stale GLib sources "
			"(baseline=%u, new_baseline=%u)\n", label, removed, baseline, upper);
	}

	/* Bump Lgi closure generation - all old closures become no-ops.
	 * lgi_closure_guard.so must be LD_PRELOADed for this to work. */
	{
		void (*bump)(void) = dlsym(RTLD_DEFAULT, "lgi_guard_bump_generation");
		if (bump) {
			bump();
		} else {
			fprintf(stderr, "somewm: %s: WARNING: lgi_closure_guard.so "
				"not preloaded, stale closures may crash\n", label);
		}
	}
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

	/* Install require() hooks for Wayland compatibility.
	 * 1. Track filepath in gears.surface.load_uncached_silently (for cache miss path)
	 * 2. Track screen in gears.wallpaper.maximized (for per-screen caching)
	 * 3. Short-circuit gears.wallpaper.maximized on cache hit (skip all Lua work)
	 * 4. No-op awful.client.shape updates (X11 Shape Extension unavailable on Wayland) */
	if (luaL_dostring(globalconf_L,
		"local original_require = require\n"
		"local surface_patched = false\n"
		"local wallpaper_patched = false\n"
		"local shape_patched = false\n"
		"require = function(name)\n"
		"    local mod = original_require(name)\n"
		"    -- Patch gears.surface to track filepath\n"
		"    if name == 'gears.surface' and not surface_patched then\n"
		"        surface_patched = true\n"
		"        local orig_load = mod.load_uncached_silently\n"
		"        mod.load_uncached_silently = function(surf, default)\n"
		"            if type(surf) == 'string' then\n"
		"                rawset(_G, '_somewm_last_wallpaper_path', surf)\n"
		"            end\n"
		"            return orig_load(surf, default)\n"
		"        end\n"
		"    end\n"
		"    -- Patch gears.wallpaper.maximized for per-screen caching\n"
		"    if name == 'gears.wallpaper' and not wallpaper_patched then\n"
		"        wallpaper_patched = true\n"
		"        -- Nested table: path -> screen_index -> geometry\n"
		"        -- Allows same wallpaper on multiple screens without overwriting\n"
		"        rawset(_G, '_somewm_wallpaper_screen_info', {})\n"
		"        local orig_maximized = mod.maximized\n"
		"        mod.maximized = function(surf, s, ignore_aspect, offset)\n"
		"            -- Get screen for per-screen caching\n"
		"            local scr = s and screen[s]\n"
		"            local scr_index = scr and scr.index or nil\n"
		"            -- Store geometry in nested table: [path][screen_index] = geometry\n"
		"            if type(surf) == 'string' and scr_index and scr.geometry then\n"
		"                local g = scr.geometry\n"
		"                _somewm_wallpaper_screen_info[surf] = _somewm_wallpaper_screen_info[surf] or {}\n"
		"                _somewm_wallpaper_screen_info[surf][scr_index] = {\n"
		"                    x = g.x, y = g.y,\n"
		"                    width = g.width, height = g.height\n"
		"                }\n"
		"            end\n"
		"            -- If surf is a filepath, screen is valid, and cached, show directly\n"
		"            if type(surf) == 'string' and scr_index and root.wallpaper_cache_show(surf, scr_index) then\n"
		"                return\n"
		"            end\n"
		"            -- Cache miss: fall through to original implementation\n"
		"            return orig_maximized(surf, s, ignore_aspect, offset)\n"
		"        end\n"
		"    end\n"
		"    -- No-op client shape updates (X11 Shape Extension not available on Wayland)\n"
		"    -- See: ideas/Shapes.md, #157, #342\n"
		"    if name == 'awful.client.shape' and not shape_patched then\n"
		"        shape_patched = true\n"
		"        mod.update.all = function() end\n"
		"        mod.update.bounding = function() end\n"
		"        mod.update.clip = function() end\n"
		"        mod.update.input = function() end\n"
		"    end\n"
		"    return mod\n"
		"end\n"
	) != 0) {
		fprintf(stderr, "somewm: warning: failed to install wallpaper caching hooks: %s\n",
			lua_tostring(globalconf_L, -1));
		lua_pop(globalconf_L, 1);
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
			 * We must recreate it before trying the next config.
			 *
			 * Clean up GLib sources FIRST - they hold FFI closures
			 * with lua_State* pointers. Without this, g_main_loop_run()
			 * dispatches stale closures against freed memory -> SEGV.
			 * Skip GDBus close here (it calls g_bus_get_sync which
			 * could itself block if D-Bus was what caused the timeout). */
			luaA_cleanup_stale_glib_sources("config-timeout");
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

			log_info("loaded config from %s", config_paths[i]);

			/* Automatically load IPC module for CLI support (somewm extension) */
			lua_getglobal(globalconf_L, "require");
			lua_pushstring(globalconf_L, "awful.ipc");
			if (lua_pcall(globalconf_L, 1, 0, 0) != 0) {
				fprintf(stderr, "Warning: Failed to load IPC module: %s\n",
					lua_tostring(globalconf_L, -1));
				lua_pop(globalconf_L, 1);
			}

			/* Load shadow defaults from beautiful theme */
			shadow_load_beautiful_defaults(globalconf_L);

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

	/* Re-apply extra search paths from -L/--search command line options.
	 * These are only applied in luaA_init() during initial startup, so
	 * a fresh state after hot-reload would lose them. The static array
	 * survives across reloads. */
	if (num_extra_search_paths > 0) {
		lua_getglobal(L, "package");
		for (int i = 0; i < num_extra_search_paths; i++) {
			const char *dir = extra_search_paths[i];

			lua_getfield(L, -1, "path");
			cur_path = lua_tostring(L, -1);
			lua_pop(L, 1);
			lua_pushfstring(L, "%s/?.lua;%s/?/init.lua;%s",
				dir, dir, cur_path);
			lua_setfield(L, -2, "path");

			lua_getfield(L, -1, "cpath");
			cur_path = lua_tostring(L, -1);
			lua_pop(L, 1);
			lua_pushfstring(L, "%s/?.so;%s",
				dir, cur_path);
			lua_setfield(L, -2, "cpath");
		}
		lua_pop(L, 1);  /* pop package table */
	}

	/* Re-register all Lua modules/classes */
	luaA_signal_setup(L);
	key_class_setup(L);
	tag_class_setup(L);
	window_class_setup(L);
	client_class_setup(L);
	screen_class_setup(L);
	output_class_setup(L);
	luaA_drawable_setup(L);
	luaA_drawin_setup(L);
	layer_surface_class_setup(L);
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
	systray_item_class_setup(L);

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

	/* Gesture */
	lua_newtable(L);
	luaA_gesture_setup(L);
	lua_setglobal(L, "_gesture");

	/* Keygrabber test helper */
	lua_newtable(L);
	luaA_keygrabber_test_setup(L);
	lua_setglobal(L, "_keygrabber");

	return L;
}

/* ============================================================================
 * Hot-Reload: In-process Lua state rebuild
 * ============================================================================
 *
 * Tears down the Lua VM, creates a fresh one, re-executes rc.lua, and
 * re-announces existing clients - all while wlroots keeps running and
 * Wayland clients survive.
 *
 * The key insight: client_t is Lua userdata with embedded wl_listener fields.
 * If lua_close() frees the userdata, the listener links dangle and wlroots
 * crashes. So we must:
 * 1. Detach all listeners from wlroots signals (client_remove_all_listeners)
 * 2. Copy client state to heap snapshots
 * 3. NULL owned resources in old userdata so client_wipe is safe during GC
 * 4. Close old Lua state
 * 5. Create fresh Lua state, recreate objects, reattach listeners
 */

/* Snapshot structs for preserving state across Lua state rebuild */

typedef struct {
	/* Full copy of client_t fields we need to preserve */
	client_t data;
	/* Was client mapped (had scene tree)? */
	bool was_mapped;
	/* Screen index for remapping (0-based, -1 if none) */
	int screen_index;
	/* Was this the focused client? */
	bool was_focused;
	/* transient_for client ID (since pointer becomes invalid after lua_close) */
	uint32_t transient_for_id;
	bool has_transient_for;
} client_snapshot_t;

typedef struct {
	Monitor *monitor;
	int index;
	struct wlr_box geometry;
	struct wlr_box workarea;
	char *name;
	screen_lifecycle_t lifecycle;
} screen_snapshot_t;

typedef struct {
	/* Owns the name string (transferred from old tag_t to prevent
	 * double-free during GC). Freed in cleanup. */
	char *name;
} tag_snapshot_t;

typedef struct {
	char *bus_name;
	char *object_path;
} systray_snapshot_t;

/** Perform in-process hot-reload of the Lua state.
 * Must be called from an idle callback, NOT from within a Lua pcall.
 */
void
luaA_hot_reload(void)
{
	lua_State *L = globalconf_get_lua_State();
	int i, j;

	/* Snapshot arrays */
	client_snapshot_t *client_snaps = NULL;
	int num_clients = 0;
	screen_snapshot_t *screen_snaps = NULL;
	int num_screens = 0;
	tag_snapshot_t *tag_snaps = NULL;
	int num_tags = 0;
	systray_snapshot_t *systray_snaps = NULL;
	int num_systray = 0;

	if (!L) {
		fprintf(stderr, "somewm: hot-reload: no Lua state to reload\n");
		return;
	}

	fprintf(stderr, "somewm: hot-reload: starting in-process Lua state rebuild\n");

	/* Freeze GC immediately. Lgi closures store a lua_State* (coroutine)
	 * in their FfiClosureBlock. If GC collects a coroutine, Lgi's
	 * closure_invalidate sets block->L = NULL. Any subsequent GLib dispatch
	 * of that closure SEGVs on lua_status(NULL). Freezing GC before ANY
	 * teardown ensures no Lua objects are collected during or after reload. */
	lua_gc(L, LUA_GCSTOP, 0);

	/* ================================================================
	 * Phase A: Teardown - clean up Lua-owned state
	 * ================================================================
	 * IMPORTANT: Do NOT call luaL_unref on the old state. The old state
	 * is leaked (not lua_close'd), so unrefs just corrupt the registry's
	 * free list. Lgi closures store callable/thread refs in the same
	 * registry. If an unref'd slot overlaps with an Lgi ref, the Lgi
	 * closure finds nil instead of its callable -> SEGV.
	 */

	/* Snapshot systray item bus names for re-probing after reload.
	 * Must happen before "exit" signal since systray._cleanup() clears
	 * the Lua-side item tables. The C array is still intact here. */
	{
		systray_item_array_t *items = systray_get_items();
		num_systray = items->len;
		if (num_systray > 0) {
			systray_snaps = calloc(num_systray, sizeof(systray_snapshot_t));
			if (systray_snaps) {
				for (i = 0; i < num_systray; i++) {
					systray_item_t *item = items->tab[i];
					if (item->bus_name)
						systray_snaps[i].bus_name = strdup(item->bus_name);
					if (item->object_path)
						systray_snaps[i].object_path = strdup(item->object_path);
				}
				fprintf(stderr, "somewm: hot-reload: snapshotted %d systray items\n",
					num_systray);
			} else {
				num_systray = 0;
			}
		}
	}

	/* Emit "exit" signal so Lua code can clean up */
	lua_pushboolean(L, true);
	luaA_signal_emit(L, "exit", 1);

	/* Cancel in-flight animations */
	animation_cleanup();

	/* NOTE: We skip luaA_awesome_clear_all_idle_timeouts,
	 * luaA_awesome_clear_lock_surface, luaA_awesome_clear_lock_covers,
	 * and luaA_keybinding_cleanup here. These call luaL_unref which
	 * corrupts the registry free list. Safe to skip since the old state
	 * is leaked anyway. */

	/* Wipe C-level signal/class arrays (no luaL_unref, just frees C memory).
	 * Class signals must be wiped so the new state doesn't fire stale handlers.
	 * Also resets the luaA_classes registry so class_setup doesn't duplicate. */
	luaA_signal_cleanup();
	luaA_class_cleanup_all();

	/* ================================================================
	 * Phase B1: Snapshot screens FIRST (needed for index lookups)
	 * ================================================================
	 * Screens are stored in screen.c's internal screen_refs array,
	 * not in globalconf.screens. Use luaA_screen_get_all() to access them.
	 */
	{
		/* 64 is far beyond any real multi-monitor setup */
		screen_t *screen_ptrs[64];
		num_screens = 64;
		luaA_screen_get_all(L, screen_ptrs, &num_screens);

		if (num_screens > 0) {
			screen_snaps = calloc(num_screens, sizeof(screen_snapshot_t));
			if (!screen_snaps) {
				fprintf(stderr, "somewm: hot-reload: failed to allocate screen snapshots\n");
				return;
			}
			/* Also temporarily populate globalconf.screens for index lookups */
			for (i = 0; i < num_screens; i++) {
				screen_array_push(&globalconf.screens, screen_ptrs[i]);
			}
		}

		for (i = 0; i < num_screens; i++) {
			screen_t *s = screen_ptrs[i];
			screen_snaps[i].monitor = s->monitor;
			screen_snaps[i].index = s->index;
			screen_snaps[i].geometry = s->geometry;
			screen_snaps[i].workarea = s->workarea;
			screen_snaps[i].name = s->name;
			screen_snaps[i].lifecycle = s->lifecycle;
			/* NULL name in old userdata so screen_wipe doesn't free it */
			s->name = NULL;
		}
	}

	/* ================================================================
	 * Phase B2: Snapshot and detach clients
	 * ================================================================ */

	num_clients = globalconf.clients.len;
	if (num_clients > 0) {
		client_snaps = calloc(num_clients, sizeof(client_snapshot_t));
		if (!client_snaps) {
			fprintf(stderr, "somewm: hot-reload: failed to allocate client snapshots\n");
			free(screen_snaps);
			return;
		}
	}

	for (i = 0; i < num_clients; i++) {
		client_t *c = globalconf.clients.tab[i];
		client_snapshot_t *snap = &client_snaps[i];

		/* Remove all wlroots listeners */
		client_remove_all_listeners(c);

		/* Copy entire client_t via memcpy */
		memcpy(&snap->data, c, sizeof(client_t));
		snap->was_mapped = (c->scene != NULL);
		snap->was_focused = (globalconf.focus.client == c);

		/* Find screen index */
		snap->screen_index = -1;
		if (c->screen) {
			for (j = 0; j < num_screens; j++) {
				if (globalconf.screens.tab[j] == c->screen) {
					snap->screen_index = j;
					break;
				}
			}
		}

		/* Save transient_for ID before we lose access to old pointers */
		snap->has_transient_for = (c->transient_for != NULL);
		snap->transient_for_id = c->transient_for ? c->transient_for->id : 0;

		/* Update surface->data back-pointer to snapshot.
		 * If a wlroots event fires between now and re-registration,
		 * the handler (e.g. destroynotify) will find the snapshot copy. */
		if (c->client_type == XDGShell) {
			if (c->surface.xdg)
				c->surface.xdg->data = &snap->data;
		}
#ifdef XWAYLAND
		else {
			if (c->surface.xwayland)
				c->surface.xwayland->data = &snap->data;
		}
#endif
		/* Also update scene tree data pointers */
		if (c->scene)
			c->scene->node.data = &snap->data;

		/* NULL out owned resources in the OLD Lua userdata so that
		 * client_wipe (called during lua_close GC) doesn't free them.
		 * The snapshot's copy holds the real pointers. */
		c->name = NULL;
		c->alt_name = NULL;
		c->class = NULL;
		c->instance = NULL;
		c->icon_name = NULL;
		c->alt_icon_name = NULL;
		c->machine = NULL;
		c->startup_id = NULL;
		c->role = NULL;
		c->keys.tab = NULL; c->keys.len = c->keys.size = 0;
		c->icons.tab = NULL; c->icons.len = c->icons.size = 0;
		c->buttons.tab = NULL; c->buttons.len = c->buttons.size = 0;
		c->protocols.atoms = NULL; c->protocols.atoms_len = 0;
		/* Don't let GC touch shadow textures - snapshot owns them */
		for (j = 0; j < SHADOW_TEXTURE_COUNT; j++)
			c->shadow.textures[j] = NULL;
		c->shadow_config = NULL;
		/* Don't let GC destroy the scene tree */
		c->scene = NULL;
	}

	/* ================================================================
	 * Phase B3: Snapshot tags
	 * ================================================================ */

	num_tags = globalconf.tags.len;
	if (num_tags > 0) {
		tag_snaps = calloc(num_tags, sizeof(tag_snapshot_t));
		if (!tag_snaps) {
			fprintf(stderr, "somewm: hot-reload: failed to allocate tag snapshots\n");
			free(client_snaps);
			free(screen_snaps);
			return;
		}
	}

	for (i = 0; i < num_tags; i++) {
		tag_t *t = globalconf.tags.tab[i];

		/* Transfer name ownership to snapshot so tag_wipe doesn't free it.
		 * Tags are recreated from rc.lua defaults, not restored from snapshots. */
		tag_snaps[i].name = t->name;
		t->name = NULL;

		/* Clear clients array so tag_wipe doesn't iterate stale pointers */
		t->clients.tab = NULL;
		t->clients.len = t->clients.size = 0;
	}

	/* ================================================================
	 * Phase C: Close old Lua state
	 * ================================================================ */

	globalconf.hot_reload_in_progress = true;

	/* Invalidate spawn exit callbacks so they don't try to call
	 * stale registry refs in the new Lua state. */
	spawn_invalidate_callbacks();

	/* Clear arrays so GC doesn't try to access stale data.
	 * We've already snapshotted everything and NULL'd owned resources. */
	globalconf.clients.len = 0;
	globalconf.stack.len = 0;
	globalconf.tags.len = 0;
	globalconf.screens.len = 0;
	globalconf.focus.client = NULL;

	/* Destroy old drawin scene trees so they don't persist as duplicates.
	 * During normal shutdown, drawin_wipe() handles this via GC, but
	 * hot-reload leaks the old state with GC frozen. */
	foreach(d, globalconf.drawins) {
		drawin_t *w = *d;
		for (int si = 0; si < SHADOW_TEXTURE_COUNT; si++) {
			if (w->shadow.textures[si]) {
				wlr_buffer_drop(w->shadow.textures[si]);
				w->shadow.textures[si] = NULL;
			}
		}
		if (w->scene_tree) {
			wlr_scene_node_destroy(&w->scene_tree->node);
			w->scene_tree = NULL;
			w->scene_buffer = NULL;
			w->border_buffer = NULL;
		}
	}
	globalconf.drawins.len = 0;

	/* Reset screen_refs before closing (entries become invalid) */
	luaA_screen_refs_reset();

	/* Cancel compositor-owned GLib sources that have IDs above baseline
	 * (e.g., activation token timeouts). These are C callbacks, not Lua,
	 * but their IDs fall in the scan range and must not be destroyed. */
	extern void activation_tokens_cancel_all(void);
	activation_tokens_cancel_all();

	/* Close the GDBus session bus connection BEFORE the source scan.
	 * This prevents GDBus internal sources from being created in the gap. */
	{
		GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
		if (bus) {
			g_dbus_connection_close_sync(bus, NULL, NULL);
			g_object_unref(bus);
		}
	}

	/* Remove stale GLib sources and bump Lgi closure generation. */
	luaA_cleanup_stale_glib_sources("hot-reload");

	/* Leak the old Lua state. lua_close() is unsafe because client
	 * snapshots, screens, and other C objects still reference Lua
	 * userdata memory. GC is kept frozen so Lgi closures retain
	 * their block->L pointers (non-NULL but stale). The GLib source
	 * sweep above prevents most dispatches. ~1-2MB leak per reload. */
	globalconf_L = NULL;
	globalconf.L = NULL;

	fprintf(stderr, "somewm: hot-reload: old Lua state leaked, creating fresh state\n");

	/* ================================================================
	 * Phase D: Create fresh Lua state
	 * ================================================================ */

	L = luaA_create_fresh_state();
	if (!L) {
		fprintf(stderr, "somewm: hot-reload: FATAL: failed to create fresh Lua state\n");
		/* Try to gracefully quit */
		some_compositor_quit();
		goto cleanup;
	}

	/* ================================================================
	 * Phase E: Re-create client objects in new Lua state
	 * ================================================================
	 * We do NOT recreate screens or tags here. The normal startup flow
	 * (screen scanning + rc.lua) creates them. We only recreate clients
	 * because they own wlroots listeners that must be attached to valid
	 * Lua userdata. After rc.lua creates tags, we reassign clients.
	 */

	{
		client_t **new_clients = num_clients > 0
			? calloc(num_clients, sizeof(client_t *)) : NULL;
		int focused_idx = -1;

		for (i = 0; i < num_clients; i++) {
			client_snapshot_t *cs = &client_snaps[i];
			client_t *c;
			signal_array_t fresh_signals;

			c = client_new(L);
			fresh_signals = c->signals;
			memcpy(c, &cs->data, sizeof(client_t));
			c->signals = fresh_signals;

			/* Clear all Lua userdata pointers from the old state.
			 * These survive memcpy but reference dead Lua objects.
			 * Layout/placement/rules code crashes on stale drawables. */
			c->buttons.tab = NULL; c->buttons.len = c->buttons.size = 0;
			c->keys.tab = NULL; c->keys.len = c->keys.size = 0;
			c->toplevel_handle = NULL;
			c->screen = NULL;
			c->transient_for = NULL;
			for (int tb = 0; tb < CLIENT_TITLEBAR_COUNT; tb++) {
				c->titlebar[tb].drawable = NULL;
				c->titlebar[tb].size = 0;
				if (c->titlebar[tb].scene_buffer) {
					wlr_scene_node_destroy(&c->titlebar[tb].scene_buffer->node);
					c->titlebar[tb].scene_buffer = NULL;
				}
			}

			/* Re-register wlroots listeners */
			client_reregister_listeners(c);

			/* Update surface->data to point to new userdata */
			if (c->client_type == XDGShell) {
				if (c->surface.xdg)
					c->surface.xdg->data = c;
			}
#ifdef XWAYLAND
			else {
				if (c->surface.xwayland)
					c->surface.xwayland->data = c;
			}
#endif
			if (c->scene) {
				c->scene->node.data = c;
				if (c->scene_surface)
					c->scene_surface->node.data = c;
			}

			/* Reference and push to arrays */
			lua_pushvalue(L, -1);
			client_array_append(&globalconf.clients, luaA_object_ref(L, -1));
			stack_client_append(c);

			new_clients[i] = c;
			if (cs->was_focused)
				focused_idx = i;

			lua_pop(L, 1);
		}

		/* Remap transient_for pointers using saved client IDs */
		for (i = 0; i < num_clients; i++) {
			if (!client_snaps[i].has_transient_for || !new_clients[i])
				continue;
			for (j = 0; j < num_clients; j++) {
				if (client_snaps[j].data.id == client_snaps[i].transient_for_id) {
					new_clients[i]->transient_for = new_clients[j];
					break;
				}
			}
		}

		/* Restore focus */
		if (focused_idx >= 0 && focused_idx < num_clients)
			globalconf.focus.client = new_clients[focused_idx];

		free(new_clients);
	}

	/* ================================================================
	 * Phase F: Reload config
	 * ================================================================
	 * Signal ordering relies on the ::connected pattern (luaclass.c):
	 * when rc.lua connects a handler for request::desktop_decoration,
	 * the C class system auto-emits ::connected, which triggers
	 * awful.screen to call the handler for ALL existing screens.
	 *
	 * 1. Set awesome._restart = true
	 * 2. Create screens from snapshots (must exist before rc.lua)
	 * 3. luaA_loadrc() - ::connected fires handlers for existing screens
	 * 4. screen_emit_scanned() - sets flag, DPI handler runs
	 * 5. client_emit_scanning() - keybinding/mouse/rules setup
	 * 6. Per-client: set screen, emit property + request::manage
	 * 7. client_emit_scanned(), startup, some_refresh()
	 *
	 * No screen_emit_scanning() or luaA_screen_emit_all_added() needed.
	 */

	/* Set awesome._restart = true BEFORE loading rc.lua */
	lua_getglobal(L, "awesome");
	if (lua_istable(L, -1)) {
		lua_pushboolean(L, 1);
		lua_setfield(L, -2, "_restart");

		/* Set awesome._systray_snapshot for Lua-side re-probing */
		if (num_systray > 0 && systray_snaps) {
			lua_newtable(L);
			for (i = 0; i < num_systray; i++) {
				if (systray_snaps[i].bus_name) {
					lua_newtable(L);
					lua_pushstring(L, systray_snaps[i].bus_name);
					lua_setfield(L, -2, "bus_name");
					lua_pushstring(L, systray_snaps[i].object_path
						? systray_snaps[i].object_path
						: "/StatusNotifierItem");
					lua_setfield(L, -2, "object_path");
					lua_rawseti(L, -2, i + 1);
				}
			}
			lua_setfield(L, -2, "_systray_snapshot");
		}
	}
	lua_pop(L, 1);

	/* Recreate screen objects from snapshots BEFORE screen scanning signals.
	 * Screens must exist when rc.lua loads because awful.screen, awful.tag,
	 * naughty etc. all need screens during initialization. */
	for (i = 0; i < num_screens; i++) {
		screen_snapshot_t *ss = &screen_snaps[i];
		screen_t *screen = luaA_screen_new(L, ss->monitor, ss->index);
		if (screen) {
			screen->geometry = ss->geometry;
			screen->workarea = ss->workarea;
			screen->lifecycle = ss->lifecycle;
			if (ss->name) {
				screen->name = ss->name;
				ss->name = NULL;  /* Transferred ownership */
			}
			screen_array_push(&globalconf.screens, screen);
		}
		lua_pop(L, 1);  /* luaA_screen_new leaves screen on stack */
	}

	/* Outputs are independent of screens (disabled monitors still have
	 * outputs). Must exist before rc.lua so added::connected works. */
	luaA_output_hot_reload(L);

	/* Load and execute rc.lua.
	 * Screens already exist (created above). When rc.lua registers handlers
	 * for request::desktop_decoration etc., the ::connected pattern
	 * (luaclass.c:308-332) auto-fires them for all existing screens.
	 * This is the same mechanism initial startup uses - no scanning or
	 * _added signals needed. */
	luaA_loadrc();

	/* Emit scanned so awful.screen knows screen discovery is done */
	screen_emit_scanned();

	/* Client scanning: triggers awful.mouse/keyboard/rules setup */
	client_emit_scanning();

	/* Save client array order before manage signals. Rule callbacks
	 * (e.g. to_secondary_section) call client:swap() which reorders
	 * globalconf.clients. We need the manage loop to run for tags and
	 * properties, but must preserve the pre-reload tiling order. */
	client_t **saved_order = NULL;
	if (num_clients > 0) {
		saved_order = malloc(num_clients * sizeof(client_t *));
		if (saved_order)
			memcpy(saved_order, globalconf.clients.tab,
				num_clients * sizeof(client_t *));
	}

	for (i = 0; i < num_clients; i++) {
		client_t *c = globalconf.clients.tab[i];

		if (!client_snaps[i].was_mapped)
			continue;

		/* Assign client to first screen if not already set */
		if (!c->screen && globalconf.screens.len > 0) {
			int si = client_snaps[i].screen_index;
			if (si >= 0 && si < globalconf.screens.len)
				c->screen = globalconf.screens.tab[si];
			else
				c->screen = globalconf.screens.tab[0];
		}

		luaA_object_push(L, c);

		/* Emit property signals */
		luaA_object_emit_signal(L, -1, "property::x", 0);
		luaA_object_emit_signal(L, -1, "property::y", 0);
		luaA_object_emit_signal(L, -1, "property::width", 0);
		luaA_object_emit_signal(L, -1, "property::height", 0);
		luaA_object_emit_signal(L, -1, "property::geometry", 0);
		luaA_object_emit_signal(L, -1, "property::name", 0);
		luaA_object_emit_signal(L, -1, "property::type", 0);
		luaA_object_emit_signal(L, -1, "property::screen", 0);

		/* Emit request::manage so awful.rules applies tags etc. */
		lua_pushliteral(L, "restart");
		lua_newtable(L);
		luaA_object_emit_signal(L, -3, "request::manage", 2);
		luaA_object_emit_signal(L, -1, "manage", 0);

		lua_pop(L, 1);
	}

	/* Restore pre-reload client order. The manage loop may have
	 * reordered via to_secondary_section()/swap(), but clients
	 * should keep their original tiling positions across reload. */
	if (saved_order && globalconf.clients.len == num_clients) {
		memcpy(globalconf.clients.tab, saved_order,
			num_clients * sizeof(client_t *));
	}
	free(saved_order);

	client_emit_scanned();

	/* Emit startup signal */
	luaA_signal_emit(L, "startup", 0);

	/* Flush visual state */
	some_refresh();

	globalconf.hot_reload_in_progress = false;

	fprintf(stderr, "somewm: hot-reload: complete (%d clients, %d screens, %d tags reset)\n",
		num_clients, num_screens, num_tags);

	/* Mark new Lgi closures as ready - allows guard to dispatch them.
	 * Must be called AFTER rc.lua is fully loaded and Lgi is stable. */
	{
		void (*ready)(void) = dlsym(RTLD_DEFAULT, "lgi_guard_mark_ready");
		if (ready)
			ready();
	}

cleanup:
	/* Free snapshot arrays */
	for (i = 0; i < num_tags; i++)
		free(tag_snaps[i].name);
	for (i = 0; i < num_screens; i++)
		free(screen_snaps[i].name);
	for (i = 0; i < num_systray; i++) {
		free(systray_snaps[i].bus_name);
		free(systray_snaps[i].object_path);
	}
	free(client_snaps);
	free(screen_snaps);
	free(tag_snaps);
	free(systray_snaps);
}

void
luaA_cleanup(void)
{
	if (globalconf_L) {
		/* Clean up signal and keybinding systems first */
		luaA_signal_cleanup();
		luaA_keybinding_cleanup();

		/* Clean up lock/idle state before closing Lua */
		luaA_awesome_clear_all_idle_timeouts(globalconf_L);
		lua_idle_inhibited = false;
		some_recompute_idle_inhibit();
		luaA_awesome_clear_lock_surface(globalconf_L);
		luaA_awesome_clear_lock_covers(globalconf_L);

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
	layer_surface_array_init(&globalconf.layer_surfaces);

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

	/* Clean up input rules */
	input_rules_free();

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
