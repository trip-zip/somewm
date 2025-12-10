#ifndef KEYBINDING_H
#define KEYBINDING_H

#include <lua.h>
#include <xkbcommon/xkbcommon.h>
#include <stdint.h>

/* Forward declare client_t */
typedef struct client_t client_t;

void luaA_keybinding_setup(lua_State *L);

/* NEW AwesomeWM-compatible system: key objects with signals */
int luaA_key_check_and_emit(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);

/* Client-specific keybindings - checks client's keys array and passes client as arg */
int luaA_client_key_check_and_emit(client_t *c, uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);

/* OLD DEPRECATED system: direct callback storage */
int luaA_keybind_check(uint32_t mods, xkb_keysym_t sym, xkb_keysym_t base_sym);

void luaA_keybinding_cleanup(void);

#endif /* KEYBINDING_H */
