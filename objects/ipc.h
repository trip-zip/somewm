#ifndef LUAA_IPC_H
#define LUAA_IPC_H

#include <lua.h>

/**
 * Setup IPC Lua bindings
 * Registers the _ipc_dispatch function that Lua can call
 */
void luaA_ipc_setup(lua_State *L);

#endif /* LUAA_IPC_H */
