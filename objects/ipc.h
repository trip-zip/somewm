#ifndef LUAA_IPC_H
#define LUAA_IPC_H

#include <lua.h>

/**
 * Setup IPC Lua bindings
 * Registers the _ipc_dispatch function that Lua can call
 */
void luaA_ipc_setup(lua_State *L);

/* Run an IPC command in Lua and send the reply to client_fd */
void ipc_dispatch_to_lua(int client_fd, const char *command);

#endif /* LUAA_IPC_H */
