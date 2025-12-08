/*
 * objects/signal.h - somewm global signal emission helpers
 *
 * This file provides somewm-specific signal emission functions for
 * emitting global signals from C code. The core signal_t and signal_array_t
 * types are defined in common/signal.h (AwesomeWM's signal system).
 */

#ifndef SOMEWM_OBJECTS_SIGNAL_H
#define SOMEWM_OBJECTS_SIGNAL_H

#include <lua.h>
#include "common/signal.h"
#include "common/luaobject.h"

/* Alias for AwesomeWM compatibility - calls luaA_object_emit_signal */
#define luaA_awm_object_emit_signal(L, idx, name, nargs) \
    luaA_object_emit_signal(L, idx, name, nargs)

/* Forward declarations */
typedef struct client_t Client;
struct screen_t;

/* Global signal system setup/cleanup */
void luaA_signal_setup(lua_State *L);
void luaA_signal_cleanup(void);

/* Emit a global signal from C code (callable without Lua stack) */
void luaA_emit_signal_global(const char *name);

/* Emit a global signal with a client object as argument */
void luaA_emit_signal_global_with_client(const char *name, Client *c);

/* Emit a global signal with a screen object as argument */
void luaA_emit_signal_global_with_screen(const char *name, struct screen_t *screen);

/* Emit a global signal with a table argument (for spawn::* signals) */
void luaA_emit_signal_global_with_table(const char *name, int nargs, ...);

#endif /* SOMEWM_OBJECTS_SIGNAL_H */
