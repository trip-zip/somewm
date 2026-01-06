/*
 * mouse.c - Mouse object bindings for Lua
 * Provides the global 'mouse' object with coordinate and detection functions
 */

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <string.h>

#include "somewm_api.h"
#include "somewm_types.h"
#include "common/lualib.h"
#include "luaa.h"
#include "objects/mouse.h"
#include "objects/client.h"
#include "objects/screen.h"

/** Get or set mouse coordinates
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 *
 * Usage:
 *   local coords = mouse.coords()  -- Returns {x=X, y=Y, buttons={...}}
 *   mouse.coords({x=100, y=200})   -- Warp mouse to position
 */
static int
luaA_mouse_coords(lua_State *L)
{
	double x, y;
	int button_states[5];
	int i;

	/* If table argument provided, set cursor position */
	if (lua_gettop(L) >= 1 && lua_istable(L, 1)) {
		lua_getfield(L, 1, "x");
		lua_getfield(L, 1, "y");

		if (lua_isnumber(L, -2) && lua_isnumber(L, -1)) {
			x = lua_tonumber(L, -2);
			y = lua_tonumber(L, -1);

			/* TODO: Handle 'silent' parameter */
			some_set_cursor_position(x, y, 0);
		}

		lua_pop(L, 2); /* Pop x and y */
	}

	/* Always return current position and button states */
	some_get_cursor_position(&x, &y);
	some_get_button_states(button_states);

	/* Create return table {x=X, y=Y, buttons={1=bool, 2=bool, ...}} */
	lua_newtable(L);

	lua_pushnumber(L, x);
	lua_setfield(L, -2, "x");

	lua_pushnumber(L, y);
	lua_setfield(L, -2, "y");

	/* Create buttons sub-table */
	lua_newtable(L);
	for (i = 0; i < 5; i++) {
		lua_pushboolean(L, button_states[i]);
		lua_rawseti(L, -2, i + 1); /* Lua uses 1-based indexing */
	}
	lua_setfield(L, -2, "buttons");

	return 1;
}

/** Get object under mouse pointer
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 *
 * Usage:
 *   local obj = mouse.object_under_pointer()  -- Returns client or nil
 */
static int
luaA_mouse_object_under_pointer(lua_State *L)
{
	Client *c = some_object_under_cursor();
	drawin_t *d;

	if (c) {
		/* Push client object */
		luaA_object_push(L, c);
		return 1;
	}

	/* Check for drawin (wibox) under cursor */
	d = some_drawin_under_cursor();
	if (d) {
		/* Push drawin object */
		luaA_object_push(L, d);
		return 1;
	}

	/* Nothing under cursor */
	lua_pushnil(L);
	return 1;
}

/** Property getter for mouse object
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 *
 * Handles: mouse.screen
 */
static int
luaA_mouse_index(lua_State *L)
{
	const char *prop;
	Monitor *m;

	/* Check if accessing a method first */
	lua_getmetatable(L, 1);
	lua_pushvalue(L, 2);
	lua_rawget(L, -2);

	if (!lua_isnil(L, -1))
		return 1;

	lua_pop(L, 2);

	/* Handle property access */
	if (lua_type(L, 2) != LUA_TSTRING)
		return 0;

	prop = lua_tostring(L, 2);

	if (strcmp(prop, "screen") == 0) {
		/* Return screen under cursor */
		screen_t *screen;

		m = some_monitor_at_cursor();
		if (m) {
			/* Convert Monitor* to screen_t* object */
			screen = luaA_screen_get_by_monitor(L, m);
			if (screen && screen->valid) {
				luaA_screen_push(L, screen);
				return 1;
			}
		}

		/* Fallback: Return primary screen (never return nil) */
		screen = luaA_screen_get_primary_screen(L);
		if (screen && screen->valid) {
			luaA_screen_push(L, screen);
			return 1;
		}

		/* Last resort: should never happen in normal operation */
		fprintf(stderr, "somewm: WARNING: mouse.screen has no valid screens available\n");
		lua_pushnil(L);
		return 1;
	}

	return 0;
}

/** Property setter for mouse object
 * \param L The Lua VM state
 * \return Number of elements pushed on stack
 *
 * Handles: mouse.screen = s
 */
static int
luaA_mouse_newindex(lua_State *L)
{
	const char *prop;
	Monitor *m;

	if (lua_type(L, 2) != LUA_TSTRING)
		return 0;

	prop = lua_tostring(L, 2);

	if (strcmp(prop, "screen") == 0) {
		/* Warp cursor to specified screen */
		m = (Monitor *)lua_touserdata(L, 3);
		if (m) {
			some_warp_cursor_to_monitor(m);
		}
		return 0;
	}

	return 0;
}

/** AwesomeWM compatibility: mouse.set_index_miss_handler */
static int
luaA_mouse_set_index_miss_handler(lua_State *L)
{
	return luaA_registerfct(L, 1, &mouse_handlers.index_miss_handler);
}

/** AwesomeWM compatibility: mouse.set_newindex_miss_handler */
static int
luaA_mouse_set_newindex_miss_handler(lua_State *L)
{
	return luaA_registerfct(L, 1, &mouse_handlers.newindex_miss_handler);
}

/* Mouse object methods table */
static const luaL_Reg mouse_methods[] = {
	{ "__index", luaA_mouse_index },
	{ "__newindex", luaA_mouse_newindex },
	{ "coords", luaA_mouse_coords },
	{ "object_under_pointer", luaA_mouse_object_under_pointer },
	{ "set_index_miss_handler", luaA_mouse_set_index_miss_handler },
	{ "set_newindex_miss_handler", luaA_mouse_set_newindex_miss_handler },
	{ NULL, NULL }
};

/** Initialize the mouse object for Lua
 * Creates global 'mouse' object and capi.mouse
 */
void
luaA_mouse_setup(lua_State *L)
{
	/* Get or create capi table */
	lua_getglobal(L, "capi");
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setglobal(L, "capi");
	}

	/* Create the mouse object */
	lua_newtable(L);

	/* Set metatable */
	lua_newtable(L);
	luaA_setfuncs(L, mouse_methods);
	lua_setmetatable(L, -2);

	/* Duplicate the mouse table */
	lua_pushvalue(L, -1);

	/* Set capi.mouse = mouse_table */
	lua_setfield(L, -3, "mouse");

	/* Also set global mouse for compatibility */
	lua_setglobal(L, "mouse");

	lua_pop(L, 1);  /* Pop capi table */
}
