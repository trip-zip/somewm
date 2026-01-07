/*
 * spawn.c - Process spawning with async support
 *
 * Adapted from AwesomeWM spawn.c
 * Copyright © 2009 Julien Danjou <julien@danjou.info>
 * Copyright © 2024 somewm contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "objects/spawn.h"
#include "globalconf.h"
#include "luaa.h"
#include "objects/signal.h"

#include <stdbool.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <glib.h>
#include <string.h>

/* Tracking structure for child processes with exit callbacks */
typedef struct {
	GPid pid;
	int exit_callback;  /* Lua registry reference */
} running_child_t;

/* Array of running children (for exit callback tracking) */
static GArray *running_children = NULL;

/** Initialize program spawner.
 * X11-only: Sets up libstartup-notification monitor.
 * Wayland uses XDG Activation protocol instead.
 */
void
spawn_init(void)
{
    /* X11-only: sn_xcb_display_new(), sn_monitor_context_new().
     * Wayland startup notification is handled via wlr_xdg_activation_v1. */
}

/** Tell the spawn module that an app has been started.
 * \param c The client that just started.
 * \param startup_id The startup id of the started application.
 *
 * X11-only: Matches client to pending startup sequence.
 * Wayland uses XDG Activation token matching instead.
 */
void
spawn_start_notify(client_t *c, const char *startup_id)
{
    /* X11-only: Matches client class/instance to pending sn sequences.
     * Wayland activation token matching is done in somewm.c. */
    (void)c;
    (void)startup_id;
}

/* Helper: Find child by PID */
static running_child_t *
find_child(GPid pid)
{
	running_child_t *result = NULL;
	guint i;

	if (!running_children || running_children->len == 0)
		return NULL;

	/* Linear search */
	for (i = 0; i < running_children->len; i++) {
		running_child_t *child = &g_array_index(running_children, running_child_t, i);
		if (child->pid == pid) {
			result = child;
			break;
		}
	}
	return result;
}

/** Convert a Lua table of strings to a char** array.
 * \param L The Lua VM state.
 * \param idx The index of the table that we should parse.
 * \param error GError pointer for error reporting
 * \return The argv array.
 */
static gchar **
parse_table_array(lua_State *L, int idx, GError **error)
{
	gchar **argv = NULL;
	size_t i, len;

	luaL_checktype(L, idx, LUA_TTABLE);
	len = luaA_rawlen(L, idx);

	/* Verify table contains only strings */
	for (i = 0; i < len; i++) {
		lua_rawgeti(L, idx, i + 1);
		if (lua_type(L, -1) != LUA_TSTRING) {
			lua_pop(L, len - i);  /* Pop remaining items */
			g_set_error(error, G_SPAWN_ERROR, 0,
					"Non-string argument at table index %zu", i + 1);
			return NULL;
		}
	}

	/* Allocate and fill argv array */
	argv = g_new0(gchar *, len + 1);
	for (i = 0; i < len; i++) {
		argv[len - i - 1] = g_strdup(lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	return argv;
}

/** Parse a command line.
 * \param L The Lua VM state.
 * \param idx The index of the argument that we should parse.
 * \param error GError pointer for error reporting
 * \return The argv array for the new process.
 */
static gchar **
parse_command(lua_State *L, int idx, GError **error)
{
	gchar **argv = NULL;

	if (lua_isstring(L, idx)) {
		const char *cmd = luaL_checkstring(L, idx);
		if (!g_shell_parse_argv(cmd, NULL, &argv, error))
			return NULL;
	} else if (lua_istable(L, idx)) {
		argv = parse_table_array(L, idx, error);
	} else {
		g_set_error_literal(error, G_SPAWN_ERROR, 0,
				"Invalid argument to spawn(), expected string or table");
		return NULL;
	}

	return argv;
}

/** Called when a spawned process exits (AwesomeWM pattern).
 * This is called from somewm.c's reap_children() callback.
 * \param pid Process ID of the exited child
 * \param status Exit status from waitpid()
 */
void
spawn_child_exited(pid_t pid, int status)
{
	lua_State *L = globalconf_get_lua_State();
	running_child_t *child;
	int exit_callback;
	guint i;

	child = find_child(pid);

	if (!child) {
		/* Not a tracked child - could be from startup command or other source.
		 * This is normal and expected, don't warn. */
		return;
	}

	exit_callback = child->exit_callback;

	/* Remove from tracking array */
	for (i = 0; i < running_children->len; i++) {
		if (g_array_index(running_children, running_child_t, i).pid == pid) {
			g_array_remove_index(running_children, i);
			break;
		}
	}

	/* Decode exit status and call Lua callback */
	if (WIFEXITED(status)) {
		lua_pushliteral(L, "exit");
		lua_pushinteger(L, WEXITSTATUS(status));
	} else if (WIFSIGNALED(status)) {
		lua_pushliteral(L, "signal");
		lua_pushinteger(L, WTERMSIG(status));
	} else {
		lua_pushliteral(L, "unknown");
		lua_pushinteger(L, status);
	}

	/* Call the exit callback */
	lua_rawgeti(L, LUA_REGISTRYINDEX, exit_callback);
	lua_insert(L, -3);  /* Move function before arguments */

	if (lua_pcall(L, 2, 0, 0) != 0) {
		fprintf(stderr, "somewm: error in exit callback: %s\n",
				lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	/* Unref the callback */
	luaL_unref(L, LUA_REGISTRYINDEX, exit_callback);
}

/** Child setup callback - just call setsid()
 * This runs in the child process before exec
 */
static void
spawn_child_setup(gpointer user_data)
{
	char *token;
	
	setsid();
	
	/* Set XDG_ACTIVATION_TOKEN for Wayland startup notification
	 * (matches AwesomeWM's DESKTOP_STARTUP_ID pattern for X11) */
	token = (char *)user_data;
	if (token) {
		setenv("XDG_ACTIVATION_TOKEN", token, 1);
	}
}

/** Spawn a program.
 *
 * @tparam string|table cmd The command to launch.
 * @tparam[opt=true] boolean use_sn Use startup-notification? (ignored on Wayland)
 * @tparam[opt="DEV_NULL"] boolean|string stdin Pass `true` to return a fd for stdin,
 *   "DEV_NULL" to redirect to /dev/null, or "INHERIT" to inherit parent's stdin
 * @tparam[opt="INHERIT"] boolean|string stdout Pass `true` to return a fd for stdout,
 *   "DEV_NULL" to redirect to /dev/null, or "INHERIT" to inherit parent's stdout
 * @tparam[opt="INHERIT"] boolean|string stderr Pass `true` to return a fd for stderr,
 *   "DEV_NULL" to redirect to /dev/null, or "INHERIT" to inherit parent's stderr
 * @tparam[opt=nil] function exit_callback Function to call on process exit with
 *   arguments (reason, code) where reason is "exit" or "signal"
 * @tparam[opt=nil] table envp Environment variables for the spawned program
 * @treturn[1] integer Process ID if successful
 * @treturn[1] nil Startup notification ID (always nil on Wayland)
 * @treturn[1] integer|nil stdin fd if requested
 * @treturn[1] integer|nil stdout fd if requested
 * @treturn[1] integer|nil stderr fd if requested
 * @treturn[2] string Error message if spawn failed
 */
int
luaA_spawn(lua_State *L)
{
	gchar **argv = NULL, **envp = NULL;
	bool return_stdin = false, return_stdout = false, return_stderr = false;
	bool use_sn = true;  /* Default: enable startup notification */
	char *activation_token = NULL;  /* XDG activation token for Wayland */
	int stdin_fd = -1, stdout_fd = -1, stderr_fd = -1;
	int *stdin_ptr = NULL, *stdout_ptr = NULL, *stderr_ptr = NULL;
	GSpawnFlags flags = 0;
	gboolean retval;
	GPid pid;
	GError *error = NULL;

	/* Parse use_sn argument (arg 2) */
	if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
		luaL_checktype(L, 2, LUA_TBOOLEAN);
		use_sn = lua_toboolean(L, 2);
	}

	/* Parse stdin argument (arg 3) */
	if (lua_gettop(L) >= 3) {
		if (lua_isstring(L, 3)) {
			const char *str = lua_tostring(L, 3);
			if (strcmp(str, "DEV_NULL") == 0) {
#if GLIB_CHECK_VERSION(2, 74, 0)
				flags |= G_SPAWN_STDIN_FROM_DEV_NULL;
#endif
			} else if (strcmp(str, "INHERIT") == 0) {
				flags |= G_SPAWN_CHILD_INHERITS_STDIN;
			} else {
				return luaL_error(L, "stdin: expected boolean, 'DEV_NULL', or 'INHERIT'");
			}
		} else if (lua_isboolean(L, 3)) {
			return_stdin = lua_toboolean(L, 3);
		} else if (!lua_isnil(L, 3)) {
			return luaL_error(L, "stdin: expected boolean or string");
		}
	}

	/* Parse stdout argument (arg 4) */
	if (lua_gettop(L) >= 4) {
		if (lua_isstring(L, 4)) {
			const char *str = lua_tostring(L, 4);
			if (strcmp(str, "DEV_NULL") == 0) {
				flags |= G_SPAWN_STDOUT_TO_DEV_NULL;
			} else if (strcmp(str, "INHERIT") == 0) {
#if GLIB_CHECK_VERSION(2, 74, 0)
				flags |= G_SPAWN_CHILD_INHERITS_STDOUT;
#endif
			} else {
				return luaL_error(L, "stdout: expected boolean, 'DEV_NULL', or 'INHERIT'");
			}
		} else if (lua_isboolean(L, 4)) {
			return_stdout = lua_toboolean(L, 4);
		} else if (!lua_isnil(L, 4)) {
			return luaL_error(L, "stdout: expected boolean or string");
		}
	}

	/* Parse stderr argument (arg 5) */
	if (lua_gettop(L) >= 5) {
		if (lua_isstring(L, 5)) {
			const char *str = lua_tostring(L, 5);
			if (strcmp(str, "DEV_NULL") == 0) {
				flags |= G_SPAWN_STDERR_TO_DEV_NULL;
			} else if (strcmp(str, "INHERIT") == 0) {
#if GLIB_CHECK_VERSION(2, 74, 0)
				flags |= G_SPAWN_CHILD_INHERITS_STDERR;
#endif
			} else {
				return luaL_error(L, "stderr: expected boolean, 'DEV_NULL', or 'INHERIT'");
			}
		} else if (lua_isboolean(L, 5)) {
			return_stderr = lua_toboolean(L, 5);
		} else if (!lua_isnil(L, 5)) {
			return luaL_error(L, "stderr: expected boolean or string");
		}
	}

	/* Parse exit_callback argument (arg 6) */
	if (!lua_isnoneornil(L, 6)) {
		luaL_checktype(L, 6, LUA_TFUNCTION);
		flags |= G_SPAWN_DO_NOT_REAP_CHILD;
	}

	/* Setup pipe pointers */
	if (return_stdin)
		stdin_ptr = &stdin_fd;
	if (return_stdout)
		stdout_ptr = &stdout_fd;
	if (return_stderr)
		stderr_ptr = &stderr_fd;

	/* Parse command (arg 1) */
	argv = parse_command(L, 1, &error);
	if (!argv || !argv[0]) {
		g_strfreev(argv);
		if (error) {
			lua_pushfstring(L, "spawn: parse error: %s", error->message);
			g_error_free(error);
		} else {
			lua_pushliteral(L, "spawn: There is nothing to execute");
		}
		return 1;
	}

	/* Parse environment variables (arg 7) */
	if (!lua_isnoneornil(L, 7)) {
		envp = parse_table_array(L, 7, &error);
		if (error) {
			g_strfreev(argv);
			g_strfreev(envp);
			lua_pushfstring(L, "spawn: environment parse error: %s", error->message);
			g_error_free(error);
			return 1;
		}
	}


	/* Generate XDG activation token for startup notification (Wayland) */
	if (use_sn && argv[0]) {
		activation_token = activation_token_create(argv[0]);
	}
		/* Emit spawn::initiated signal (matches AwesomeWM spawn.c:155) */
		if (activation_token) {
			luaA_emit_signal_global_with_table("spawn::initiated", 4,
				"id", activation_token,
				"name", argv[0]);
		}

	/* Spawn the process */
	flags |= G_SPAWN_SEARCH_PATH | G_SPAWN_CLOEXEC_PIPES;
	retval = g_spawn_async_with_pipes(NULL, argv, envp, flags,
			spawn_child_setup, activation_token, &pid,
			stdin_ptr, stdout_ptr, stderr_ptr, &error);

	g_strfreev(argv);
	g_strfreev(envp);

	if (!retval) {
		lua_pushstring(L, error->message);
		g_error_free(error);
		return 1;
	}

	/* Setup exit callback if requested */
	if (flags & G_SPAWN_DO_NOT_REAP_CHILD) {
		int callback_ref;
		running_child_t child;

		/* Initialize array on first use */
		if (!running_children)
			running_children = g_array_new(FALSE, FALSE, sizeof(running_child_t));

		/* Store callback in registry */
		lua_pushvalue(L, 6);
		callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

		/* Track this child */
		child.pid = pid;
		child.exit_callback = callback_ref;
		g_array_append_val(running_children, child);

		/* Note: No g_child_watch_add() here - child reaping is unified
		 * in somewm.c's reap_children() callback (AwesomeWM pattern) */
	}

	/* Return: pid, snid, stdin, stdout, stderr */
	lua_pushinteger(L, pid);
	/* Return startup notification ID (XDG activation token on Wayland) */
	if (activation_token)
		lua_pushstring(L, activation_token);
	else
		lua_pushnil(L);

	if (return_stdin)
		lua_pushinteger(L, stdin_fd);
	else
		lua_pushnil(L);

	if (return_stdout)
		lua_pushinteger(L, stdout_fd);
	else
		lua_pushnil(L);

	if (return_stderr)
		lua_pushinteger(L, stderr_fd);
	else
		lua_pushnil(L);

	return 5;
}

/** Setup the spawn module
 * Registers awesome.spawn() function
 */
void
luaA_spawn_setup(lua_State *L)
{
	/* Note: This function is no longer used - awesome.spawn is registered
	 * directly in awesome.c's methods table. Kept for compatibility. */
}
