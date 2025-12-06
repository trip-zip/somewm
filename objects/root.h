#ifndef SOMEWM_ROOT_H
#define SOMEWM_ROOT_H

#include <lua.h>
#include <stdbool.h>
#include <stdint.h>

void luaA_root_setup(lua_State *L);

/* Root button checking for global button bindings */
int luaA_root_button_check(lua_State *L, uint32_t button, uint32_t mods,
                           double x, double y, bool is_press);

#endif /* SOMEWM_ROOT_H */
