/*
 * wibox.h - Wibox (widget box) support for somewm
 *
 * This provides the bridge between Wayland surfaces and Lua drawing via LGI.
 * Wiboxes are layer shell surfaces that can be drawn on from Lua using Cairo.
 */
#ifndef WIBOX_H
#define WIBOX_H

#include <lua.h>

void luaA_wibox_setup(lua_State *L);

#endif /* WIBOX_H */