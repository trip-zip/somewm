/**
 * objects/ipc.c - Lua bindings for IPC system
 *
 * This bridges the C IPC socket layer with the Lua command dispatcher.
 * When a command is received via the socket, it's passed to Lua for processing.
 */

#include "ipc.h"
#include "luaa.h"
#include <string.h>
#include <unistd.h>

/* Functions from ../ipc.c */
extern void ipc_send_response(int client_fd, const char *response);
extern void ipc_subscribe_client(int client_fd);
extern void ipc_broadcast(const char *message);

/**
 * Dispatch IPC command to Lua
 * Called from C when a complete command is received from the socket.
 * Calls the Lua function _ipc_dispatch(command_string, client_fd)
 */
void
ipc_dispatch_to_lua(int client_fd, const char *command)
{
	lua_State *L = globalconf_L;
	const char *result;

	if (!L) {
		ipc_send_response(client_fd, "ERROR Lua not initialized\n\n");
		return;
	}

	/* Get the _ipc_dispatch function from global scope */
	lua_getglobal(L, "_ipc_dispatch");
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 1);
		ipc_send_response(client_fd, "ERROR IPC dispatcher not initialized\n\n");
		return;
	}

	/* Push arguments: command string and client fd */
	lua_pushstring(L, command);
	lua_pushinteger(L, client_fd);

	/* Call _ipc_dispatch(command, client_fd) */
	if (lua_pcall(L, 2, 1, 0) != 0) {
		/* Error in Lua code */
		const char *error = lua_tostring(L, -1);
		char response[1024];
		snprintf(response, sizeof(response), "ERROR %s\n\n", error);
		ipc_send_response(client_fd, response);
		lua_pop(L, 1);
		return;
	}

	/* Get result from Lua (should be a string like "OK\n\n" or "ERROR msg\n\n") */
	result = lua_tostring(L, -1);
	if (result) {
		ipc_send_response(client_fd, result);
	} else {
		ipc_send_response(client_fd, "ERROR No response from dispatcher\n\n");
	}
	lua_pop(L, 1);
}

/**
 * Lua: _ipc_send_response(client_fd, response)
 * Send response directly from Lua (if needed for advanced use cases)
 */
static int
luaA_ipc_send_response(lua_State *L)
{
	int client_fd = luaL_checkinteger(L, 1);
	const char *response = luaL_checkstring(L, 2);

	ipc_send_response(client_fd, response);
	return 0;
}

/**
 * Lua: _ipc_subscribe(client_fd)
 * Mark a client as subscribed for event broadcasts
 */
static int
luaA_ipc_subscribe(lua_State *L)
{
	int client_fd = luaL_checkinteger(L, 1);
	ipc_subscribe_client(client_fd);
	return 0;
}

/**
 * Lua: _ipc_broadcast(message)
 * Broadcast a message to all subscribed clients
 */
static int
luaA_ipc_broadcast(lua_State *L)
{
	const char *message = luaL_checkstring(L, 1);
	ipc_broadcast(message);
	return 0;
}

/**
 * Setup IPC Lua module
 * Registers functions that Lua can call
 */
void
luaA_ipc_setup(lua_State *L)
{
	/* Register _ipc_send_response as global function (for advanced use) */
	lua_pushcfunction(L, luaA_ipc_send_response);
	lua_setglobal(L, "_ipc_send_response");

	/* Register _ipc_subscribe for event subscription */
	lua_pushcfunction(L, luaA_ipc_subscribe);
	lua_setglobal(L, "_ipc_subscribe");

	/* Register _ipc_broadcast for broadcasting events */
	lua_pushcfunction(L, luaA_ipc_broadcast);
	lua_setglobal(L, "_ipc_broadcast");

	/* Note: _ipc_dispatch will be defined in Lua (lua/awful/ipc.lua) */
}
