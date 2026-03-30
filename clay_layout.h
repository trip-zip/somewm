#ifndef CLAY_LAYOUT_H
#define CLAY_LAYOUT_H

#include <lua.h>

/* Register the _somewm_clay global table with Lua bindings */
void luaA_clay_setup(lua_State *L);

/* Free all per-screen Clay contexts and arena memory (hot-reload) */
void clay_cleanup(void);

#endif
