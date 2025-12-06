/*
 * Timer bindings for Lua
 * Provides integration with wl_event_loop timers
 */

#ifndef TIMER_H
#define TIMER_H

#include <lua.h>

void luaA_timer_setup(lua_State *L);

#endif /* TIMER_H */
