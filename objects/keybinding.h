#ifndef KEYBINDING_H
#define KEYBINDING_H

#include <lua.h>
#include <xkbcommon/xkbcommon.h>
#include <stdint.h>

void luaA_keybinding_setup(lua_State *L);

/* NEW AwesomeWM-compatible system: key objects with signals */
int luaA_key_check_and_emit(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);

/* OLD DEPRECATED system: direct callback storage */
int luaA_keybind_check(uint32_t mods, xkb_keysym_t sym, xkb_keysym_t base_sym);

void luaA_keybinding_cleanup(void);

#endif /* KEYBINDING_H */
