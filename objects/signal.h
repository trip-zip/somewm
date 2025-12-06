#ifndef SIGNAL_H
#define SIGNAL_H

#include <lua.h>
#include <stdint.h>
#include "../somewm_types.h"

/* Forward declarations - client_t is declared in somewm_types.h */

/* Signal array structures (exposed for use by other modules) */
typedef struct {
	char *name;
	intptr_t *refs;  /* Changed from int* to intptr_t* to store 64-bit pointers */
	size_t ref_count;
	size_t ref_capacity;
} signal_t;

typedef struct {
	signal_t *signals;
	size_t count;
	size_t capacity;
} signal_array_t;

void luaA_signal_setup(lua_State *L);
void luaA_signal_cleanup(void);

/* Emit a global signal from C code (callable without Lua stack) */
void luaA_emit_signal_global(const char *name);

/* Emit a global signal with a client object as argument */
void luaA_emit_signal_global_with_client(const char *name, Client *c);

/* Emit a global signal with a screen object as argument */
struct screen_t;
void luaA_emit_signal_global_with_screen(const char *name, struct screen_t *screen);

/* Emit a global signal with a table argument (for spawn::* signals) */
void luaA_emit_signal_global_with_table(const char *name, int nargs, ...);

/* Signal array helpers (exposed for per-object signals) */
void signal_array_init(signal_array_t *arr);
void signal_array_wipe(signal_array_t *arr);

#endif /* SIGNAL_H */
