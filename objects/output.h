#ifndef OUTPUT_H
#define OUTPUT_H

#include <lua.h>
#include "../somewm_types.h"
#include "common/luaclass.h"

/* Output object structure - represents a physical monitor connector.
 * Unlike screen objects (created/destroyed on enable/disable), output objects
 * persist from physical connect to physical disconnect. */
typedef struct output_t {
	LUA_OBJECT_HEADER
	Monitor *monitor;  /* Back-pointer to Monitor (owns the wlr_output) */
	bool valid;        /* false after physical disconnect */
	bool is_virtual;   /* true for fake screen outputs (no wlr_output backing) */
	char *vname;       /* name override for virtual outputs without wlr_output */
} output_t;

#define OUTPUT_MT "output"

/* Output class (for signal emission from somewm.c) */
extern lua_class_t output_class;

/* Output class setup (registers "output" global) */
void output_class_setup(lua_State *L);

/* Output object creation and management */
output_t *luaA_output_new(lua_State *L, Monitor *m);
output_t *luaA_output_new_virtual(lua_State *L, const char *name);
void luaA_output_push(lua_State *L, output_t *output);
void luaA_output_invalidate(lua_State *L, output_t *output);

/* Set output scale from C (used by screen.scale delegation).
 * Expects the output userdata at stack position `ud_idx` and scale value at top of stack. */
void luaA_output_apply_scale(lua_State *L, output_t *o, int ud_idx, float scale);

#endif /* OUTPUT_H */
