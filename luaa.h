#ifndef LUAA_H
#define LUAA_H

#include <stdbool.h>
#include <assert.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdarg.h>
#include <stdio.h>

extern lua_State *globalconf_L;

/* globalconf_get_lua_State() is now in globalconf.h (matches AwesomeWM) */

/** Lua 5.1/5.2 compatibility for uservalue functions */
static inline void
luaA_getuservalue(lua_State *L, int idx)
{
#if LUA_VERSION_NUM >= 502
    lua_getuservalue(L, idx);
#else
    lua_getfenv(L, idx);
#endif
}

static inline void
luaA_setuservalue(lua_State *L, int idx)
{
#if LUA_VERSION_NUM >= 502
    lua_setuservalue(L, idx);
#else
    lua_setfenv(L, idx);
#endif
}

/** Lua 5.1/5.2 compatible registerlib (from AwesomeWM luaa.h)
 * \param L The Lua VM state.
 * \param libname The library name.
 * \param l The table of functions.
 */
static inline void
luaA_registerlib(lua_State *L, const char *libname, const luaL_Reg *l)
{
    assert(libname);
#if LUA_VERSION_NUM >= 502
    lua_newtable(L);
    luaL_setfuncs(L, l, 0);
    lua_pushvalue(L, -1);
    lua_setglobal(L, libname);
#else
    luaL_register(L, libname, l);
#endif
}

/** Lua 5.1/5.2 compatible setfuncs (from AwesomeWM luaa.h)
 * \param L The Lua VM state.
 * \param l The table of functions.
 */
static inline void
luaA_setfuncs(lua_State *L, const luaL_Reg *l)
{
    if (l == NULL)
        return;
#if LUA_VERSION_NUM >= 502
    luaL_setfuncs(L, l, 0);
#else
    luaL_register(L, NULL, l);
#endif
}

/* Forward declaration for luaA_registerfct */
void luaA_checkfunction(lua_State *, int);

/** Register a function in the Lua registry.
 * \param L The Lua VM state.
 * \param idx The function index on the stack.
 * \param fct A int address: it will be filled with the int
 * registered. If the address points to an already registered function, it will
 * be unregistered.
 * \return 0.
 */
static inline int
luaA_registerfct(lua_State *L, int idx, int *fct)
{
    luaA_checkfunction(L, idx);
    lua_pushvalue(L, idx);
    if (*fct != LUA_REFNIL)
        luaL_unref(L, LUA_REGISTRYINDEX, *fct);
    *fct = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

/** Unregister a reference to a Lua object.
 * \param L The Lua VM state.
 * \param ref A reference to an Lua object.
 */
static inline void
luaA_unregister(lua_State *L, int *ref)
{
    luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    *ref = LUA_REFNIL;
}

/* Core initialization */
void luaA_init(void);
void luaA_loadrc(void);
void luaA_cleanup(void);

/* awesome module (merged from objects/awesome.c) */
void luaA_awesome_setup(lua_State *L);
void luaA_awesome_set_conffile(lua_State *L, const char *conffile);

/* Config scanner (somewm --check) */
int luaA_check_config(const char *config_path, bool use_color);

/* Note: luaA_checkudata and luaA_toudata are functions declared in common/luaclass.h
 * They use the AwesomeWM lua_class_t system for type-safe userdata access.
 * The old macro versions have been removed in favor of the AwesomeWM class system.
 */

/* Helper functions for module/class registration */
void luaA_openlib(lua_State *L, const char *name,
                  const luaL_Reg methods[], const luaL_Reg meta[]);
int luaA_dofunction_from_file(lua_State *L, const char *path);

/* AwesomeWM compatibility: Object property miss handlers
 * Stores handlers for dynamic property access on C objects
 */
typedef struct {
	int index_miss_handler;      /* Lua registry ref for __index miss handler */
	int newindex_miss_handler;   /* Lua registry ref for __newindex miss handler */
} luaA_class_handlers_t;

/* Global handler storage - one per class */
extern luaA_class_handlers_t client_handlers;
extern luaA_class_handlers_t tag_handlers;
extern luaA_class_handlers_t screen_handlers;
extern luaA_class_handlers_t mouse_handlers;

/* Handler helper functions */
int luaA_registerfct(lua_State *L, int idx, int *ref);

/* Lua version compatibility - matches AwesomeWM pattern */
#if !(501 <= LUA_VERSION_NUM && LUA_VERSION_NUM < 505)
#error "somewm only supports Lua versions 5.1-5.4 and LuaJIT"
#endif

/* Lua version compatibility helpers */
static inline size_t
luaA_rawlen(lua_State *L, int idx)
{
#if LUA_VERSION_NUM >= 502
    return lua_rawlen(L, idx);
#else
    return lua_objlen(L, idx);
#endif
}

/* luaA_getuservalue and luaA_setuservalue are now defined in common/luaclass.h */

/* Warning helper (simplified version without timestamps) */
static inline void
luaA_warn(lua_State *L, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

static inline void
luaA_warn(lua_State *L, const char *fmt, ...)
{
    va_list ap;
    luaL_where(L, 1);
    fprintf(stderr, "W: %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

static inline int
luaA_typerror(lua_State *L, int narg, const char *tname)
{
    const char *msg = lua_pushfstring(L, "%s expected, got %s",
                                      tname, luaL_typename(L, narg));
#if LUA_VERSION_NUM >= 502
    luaL_traceback(L, L, NULL, 2);
    lua_concat(L, 2);
#endif
    return luaL_argerror(L, narg, msg);
}

static inline int
luaA_rangerror(lua_State *L, int narg, double min, double max)
{
    const char *msg = lua_pushfstring(L, "value in [%f, %f] expected, got %f",
                                      min, max, (double) lua_tonumber(L, narg));
#if LUA_VERSION_NUM >= 502
    luaL_traceback(L, L, NULL, 2);
    lua_concat(L, 2);
#endif
    return luaL_argerror(L, narg, msg);
}

static inline lua_Number
luaA_checknumber_range(lua_State *L, int n, lua_Number min, lua_Number max)
{
    lua_Number result = lua_tonumber(L, n);
    if (result < min || result > max)
        luaA_rangerror(L, n, min, max);
    return result;
}

static inline lua_Number
luaA_optnumber_range(lua_State *L, int narg, lua_Number def, lua_Number min, lua_Number max)
{
    if (lua_isnoneornil(L, narg))
        return def;
    return luaA_checknumber_range(L, narg, min, max);
}

static inline lua_Number
luaA_getopt_number_range(lua_State *L, int idx, const char *name, lua_Number def, lua_Number min, lua_Number max)
{
    lua_getfield(L, idx, name);
    if (lua_isnil(L, -1) || lua_isnumber(L, -1))
        def = luaA_optnumber_range(L, -1, def, min, max);
    lua_pop(L, 1);
    return def;
}

int luaA_default_index(lua_State *L);
int luaA_default_newindex(lua_State *L);

/* X11 atom extern declarations (defined in objects/luaa.c) */
#include <xcb/xcb.h>

#ifdef XWAYLAND
/* EWMH atom initialization */
void init_ewmh_atoms(xcb_connection_t *conn);
#endif

extern xcb_atom_t WM_TAKE_FOCUS;
extern xcb_atom_t _NET_STARTUP_ID;
extern xcb_atom_t WM_DELETE_WINDOW;
extern xcb_atom_t WM_PROTOCOLS;

#ifdef XWAYLAND
/* EWMH atoms - Extended Window Manager Hints for XWayland compatibility */

/* Root Window Atoms (WM capabilities) */
extern xcb_atom_t _NET_SUPPORTED;
extern xcb_atom_t _NET_SUPPORTING_WM_CHECK;
extern xcb_atom_t _NET_CLIENT_LIST;
extern xcb_atom_t _NET_CLIENT_LIST_STACKING;
extern xcb_atom_t _NET_NUMBER_OF_DESKTOPS;
extern xcb_atom_t _NET_DESKTOP_NAMES;
extern xcb_atom_t _NET_CURRENT_DESKTOP;
extern xcb_atom_t _NET_ACTIVE_WINDOW;
extern xcb_atom_t _NET_CLOSE_WINDOW;
extern xcb_atom_t _NET_WM_NAME;
extern xcb_atom_t _NET_WM_VISIBLE_NAME;
extern xcb_atom_t _NET_WM_ICON_NAME;
extern xcb_atom_t _NET_WM_VISIBLE_ICON_NAME;
extern xcb_atom_t _NET_DESKTOP_GEOMETRY;
extern xcb_atom_t _NET_DESKTOP_VIEWPORT;
extern xcb_atom_t _NET_WORKAREA;

/* Client Window Atoms (client properties) */
extern xcb_atom_t _NET_WM_DESKTOP;
extern xcb_atom_t _NET_WM_STATE;
extern xcb_atom_t _NET_WM_STATE_STICKY;
extern xcb_atom_t _NET_WM_STATE_SKIP_TASKBAR;
extern xcb_atom_t _NET_WM_STATE_FULLSCREEN;
extern xcb_atom_t _NET_WM_STATE_MAXIMIZED_HORZ;
extern xcb_atom_t _NET_WM_STATE_MAXIMIZED_VERT;
extern xcb_atom_t _NET_WM_STATE_ABOVE;
extern xcb_atom_t _NET_WM_STATE_BELOW;
extern xcb_atom_t _NET_WM_STATE_MODAL;
extern xcb_atom_t _NET_WM_STATE_HIDDEN;
extern xcb_atom_t _NET_WM_STATE_DEMANDS_ATTENTION;

/* Window Type Atoms */
extern xcb_atom_t _NET_WM_WINDOW_TYPE;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_DESKTOP;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_DOCK;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_TOOLBAR;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_MENU;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_UTILITY;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_SPLASH;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_DIALOG;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_DROPDOWN_MENU;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_POPUP_MENU;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_TOOLTIP;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_NOTIFICATION;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_COMBO;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_DND;
extern xcb_atom_t _NET_WM_WINDOW_TYPE_NORMAL;

/* Icon & PID Atoms */
extern xcb_atom_t _NET_WM_ICON;
extern xcb_atom_t _NET_WM_PID;

/* Strut Atom */
extern xcb_atom_t _NET_WM_STRUT_PARTIAL;

/* UTF8_STRING atom for text properties */
extern xcb_atom_t UTF8_STRING;
#endif /* XWAYLAND */

#endif /* LUAA_H */
