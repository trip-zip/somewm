#ifndef SPAWN_H
#define SPAWN_H

#include <lua.h>
#include <wlr/types/wlr_xdg_activation_v1.h>

/* XDG Activation protocol for startup notification */
extern struct wlr_xdg_activation_v1 *activation;

/* Token management functions */
char *activation_token_create(const char *app_id);
void activation_token_cleanup(const char *token);


/* Spawn a program with full async support
 * Returns: pid, snid, stdin, stdout, stderr
 * See spawn.c for full documentation
 */
int luaA_spawn(lua_State *L);

/* Called when a spawned child process exits (AwesomeWM pattern).
 * This should be called from the central SIGCHLD handler in somewm.c.
 * \param pid Process ID of the exited child
 * \param status Exit status from waitpid()
 */
void spawn_child_exited(pid_t pid, int status);

/* Setup function (legacy - no longer used) */
void luaA_spawn_setup(lua_State *L);

#endif /* SPAWN_H */
