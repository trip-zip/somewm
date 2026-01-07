#ifndef SPAWN_H
#define SPAWN_H

#include "objects/client.h"

#include <lua.h>
#include <wlr/types/wlr_xdg_activation_v1.h>

/* XDG Activation protocol for startup notification */
extern struct wlr_xdg_activation_v1 *activation;

/* Token management functions */
char *activation_token_create(const char *app_id);
void activation_token_cleanup(const char *token);

void spawn_init(void);
void spawn_start_notify(client_t*, const char*);
int luaA_spawn(lua_State*);
void spawn_child_exited(pid_t, int);

/* Setup function (legacy - no longer used) */
void luaA_spawn_setup(lua_State *L);

#endif /* SPAWN_H */
