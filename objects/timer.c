/*
 * Timer bindings for Lua
 * Provides integration with wl_event_loop timers for gears.timer
 *
 * This provides minimal C bindings - the actual timer logic lives in
 * lua/gears/timer.lua for AwesomeWM API compatibility.
 */

#include <stdlib.h>
#include <wayland-server-core.h>
#include <lua.h>
#include <lauxlib.h>

#include "timer.h"
#include "luaa.h"
#include "../somewm_api.h"

#define TIMER_MT "somewm.timer"

/* Timer userdata structure */
typedef struct {
	struct wl_event_source *source;
	lua_State *L;
	int callback_ref;  /* LUA_REGISTRYINDEX reference */
	int self_ref;      /* Reference to keep userdata alive */
} Timer;

/* Forward declaration */
static int timer_callback(void *data);

/* Create a new timer userdata */
static int
luaA_timer_new(lua_State *L)
{
	Timer *timer = lua_newuserdata(L, sizeof(Timer));
	timer->source = NULL;
	timer->L = L;
	timer->callback_ref = LUA_NOREF;
	timer->self_ref = LUA_NOREF;

	luaL_getmetatable(L, TIMER_MT);
	lua_setmetatable(L, -2);

	return 1;
}

/* Start or update a timer */
static int
luaA_timer_start(lua_State *L)
{
	Timer *timer = luaL_checkudata(L, 1, TIMER_MT);
	int timeout_ms = luaL_checkinteger(L, 2);

	/* Argument 3 should be a function */
	luaL_checktype(L, 3, LUA_TFUNCTION);

	/* Store callback function in registry */
	if (timer->callback_ref != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX, timer->callback_ref);
	}
	lua_pushvalue(L, 3);  /* Push callback function */
	timer->callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Create or update timer source */
	if (timer->source == NULL) {
		struct wl_event_loop *event_loop = some_get_event_loop();
		timer->source = wl_event_loop_add_timer(event_loop, timer_callback, timer);

		/* Keep a reference to the userdata to prevent GC */
		lua_pushvalue(L, 1);  /* Push timer userdata */
		timer->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	}

	/* Arm the timer */
	if (timer->source) {
		wl_event_source_timer_update(timer->source, timeout_ms);
	}

	return 0;
}

/* Stop a timer */
static int
luaA_timer_stop(lua_State *L)
{
	Timer *timer = luaL_checkudata(L, 1, TIMER_MT);

	if (timer->source) {
		/* Disarm the timer (setting timeout to 0 stops it) */
		wl_event_source_timer_update(timer->source, 0);
	}

	return 0;
}

/* Destroy a timer (called by __gc) */
static int
luaA_timer_destroy(lua_State *L)
{
	Timer *timer = luaL_checkudata(L, 1, TIMER_MT);

	/* Remove event source */
	if (timer->source) {
		wl_event_source_remove(timer->source);
		timer->source = NULL;
	}

	/* Unreference callback */
	if (timer->callback_ref != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX, timer->callback_ref);
		timer->callback_ref = LUA_NOREF;
	}

	/* Unreference self */
	if (timer->self_ref != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX, timer->self_ref);
		timer->self_ref = LUA_NOREF;
	}

	return 0;
}

/* C callback invoked by wl_event_loop */
static int
timer_callback(void *data)
{
	Timer *timer = data;
	lua_State *L = timer->L;
	int continue_timer;

	/* Get the Lua callback from registry */
	lua_rawgeti(L, LUA_REGISTRYINDEX, timer->callback_ref);

	/* Call the Lua function */
	if (lua_pcall(L, 0, 1, 0) != 0) {
		/* Error occurred */
		fprintf(stderr, "Error in timer callback: %s\n", lua_tostring(L, -1));
		lua_pop(L, 1);
		return 0;  /* Stop timer on error */
	}

	/* Check return value - if false/nil, stop timer */
	continue_timer = 1;
	if (lua_isboolean(L, -1)) {
		continue_timer = lua_toboolean(L, -1);
	} else if (lua_isnil(L, -1)) {
		continue_timer = 0;
	}
	lua_pop(L, 1);

	return continue_timer ? 1 : 0;
}

/* Check if timer is running */
static int
luaA_timer_is_started(lua_State *L)
{
	Timer *timer = luaL_checkudata(L, 1, TIMER_MT);
	lua_pushboolean(L, timer->source != NULL);
	return 1;
}

/* Timer methods */
static const luaL_Reg timer_methods[] = {
	{ "new", luaA_timer_new },
	{ NULL, NULL }
};

/* Timer metamethods */
static const luaL_Reg timer_meta[] = {
	{ "start", luaA_timer_start },
	{ "stop", luaA_timer_stop },
	{ "is_started", luaA_timer_is_started },
	{ "__gc", luaA_timer_destroy },
	{ NULL, NULL }
};

/* Setup timer bindings */
void
luaA_timer_setup(lua_State *L)
{
	/* Create metatable */
	luaL_newmetatable(L, TIMER_MT);

	/* metatable.__index = metatable */
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");

	/* Register metamethods */
	luaL_register(L, NULL, timer_meta);
	lua_pop(L, 1);  /* Pop metatable */

	/* Create global table */
	lua_newtable(L);
	luaL_register(L, NULL, timer_methods);
	lua_setglobal(L, "_timer");
}
