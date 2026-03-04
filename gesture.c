#include "objects/gesture.h"
#include "luaa.h"
#include "common/lualib.h" /* luaA_setfuncs, luaA_default_{index,newindex} */
#include "common/util.h"
#include "globalconf.h"

#include <lauxlib.h>
#include <stdbool.h>

/* Lua registry ref for the gesture handler function */
static int gesture_handler_ref = LUA_REFNIL;

/** Set the gesture handler function.
 * Called from Lua: _gesture.set_handler(fn)
 */
static int
luaA_gesture_set_handler(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TFUNCTION);

    /* Unref old handler if any */
    if (gesture_handler_ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, gesture_handler_ref);
    }

    /* Store new handler */
    lua_pushvalue(L, 1);
    gesture_handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    return 0;
}

/** Inject a gesture event for testing.
 * Called from Lua: _gesture.inject(event_table)
 * Returns: boolean (consumed)
 */
static int
luaA_gesture_inject(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);

    if (gesture_handler_ref == LUA_REFNIL) {
        lua_pushboolean(L, 0);
        return 1;
    }

    /* Call handler with the event table */
    lua_rawgeti(L, LUA_REGISTRYINDEX, gesture_handler_ref);
    lua_pushvalue(L, 1);

    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        warn("gesture handler error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
        lua_pushboolean(L, 0);
        return 1;
    }

    /* Handler returns boolean (consumed) */
    if (!lua_isboolean(L, -1)) {
        lua_pop(L, 1);
        lua_pushboolean(L, 0);
    }

    return 1;
}

/** Call the gesture handler with an event table.
 * Returns 1 if consumed, 0 for passthrough.
 */
static int
gesture_call_handler(lua_State *L)
{
    /* Event table is already on top of stack */
    if (gesture_handler_ref == LUA_REFNIL) {
        lua_pop(L, 1);
        return 0;
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX, gesture_handler_ref);
    lua_insert(L, -2); /* put handler below event table */

    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        warn("gesture handler error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
        return 0;
    }

    int consumed = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return consumed;
}

int
luaA_gesture_check_swipe_begin(uint32_t time_msec, uint32_t fingers)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "swipe_begin");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushinteger(L, fingers);
    lua_setfield(L, -2, "fingers");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_swipe_update(uint32_t time_msec, uint32_t fingers, double dx, double dy)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "swipe_update");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushinteger(L, fingers);
    lua_setfield(L, -2, "fingers");
    lua_pushnumber(L, dx);
    lua_setfield(L, -2, "dx");
    lua_pushnumber(L, dy);
    lua_setfield(L, -2, "dy");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_swipe_end(uint32_t time_msec, bool cancelled)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "swipe_end");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushboolean(L, cancelled);
    lua_setfield(L, -2, "cancelled");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_pinch_begin(uint32_t time_msec, uint32_t fingers)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "pinch_begin");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushinteger(L, fingers);
    lua_setfield(L, -2, "fingers");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_pinch_update(uint32_t time_msec, uint32_t fingers, double dx, double dy, double scale, double rotation)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "pinch_update");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushinteger(L, fingers);
    lua_setfield(L, -2, "fingers");
    lua_pushnumber(L, dx);
    lua_setfield(L, -2, "dx");
    lua_pushnumber(L, dy);
    lua_setfield(L, -2, "dy");
    lua_pushnumber(L, scale);
    lua_setfield(L, -2, "scale");
    lua_pushnumber(L, rotation);
    lua_setfield(L, -2, "rotation");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_pinch_end(uint32_t time_msec, bool cancelled)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "pinch_end");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushboolean(L, cancelled);
    lua_setfield(L, -2, "cancelled");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_hold_begin(uint32_t time_msec, uint32_t fingers)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "hold_begin");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushinteger(L, fingers);
    lua_setfield(L, -2, "fingers");

    return gesture_call_handler(L);
}

int
luaA_gesture_check_hold_end(uint32_t time_msec, bool cancelled)
{
    lua_State *L = globalconf_get_lua_State();

    lua_newtable(L);
    lua_pushstring(L, "hold_end");
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, time_msec);
    lua_setfield(L, -2, "time");
    lua_pushboolean(L, cancelled);
    lua_setfield(L, -2, "cancelled");

    return gesture_call_handler(L);
}

const struct luaL_Reg awesome_gesture_lib[] =
{
    { "set_handler", luaA_gesture_set_handler },
    { "inject", luaA_gesture_inject },
    { "__index", luaA_default_index },
    { "__newindex", luaA_default_newindex },
    { NULL, NULL }
};

void
luaA_gesture_setup(lua_State *L)
{
    luaA_setfuncs(L, awesome_gesture_lib);
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
