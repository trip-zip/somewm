#ifndef SPAWN_H
#define SPAWN_H

#include "objects/client.h"

#include <lua.h>
#include <wlr/types/wlr_xdg_activation_v1.h>

int luaA_spawn(lua_State*);
void spawn_child_exited(pid_t, int);
void spawn_invalidate_callbacks(lua_State *L);

#endif /* SPAWN_H */
