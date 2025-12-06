#include "signal.h"
#include "luaa.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/** Global signal registry for class-level signals
 * In AwesomeWM, there are both instance and class-level signals.
 * For simplicity, we start with global signals only.
 */
static signal_array_t global_signals = {0};

/** Initialize a signal array */
void
signal_array_init(signal_array_t *arr)
{
	arr->signals = NULL;
	arr->count = 0;
	arr->capacity = 0;
}

/** Free all memory in a signal array */
void
signal_array_wipe(signal_array_t *arr)
{
	for (size_t i = 0; i < arr->count; i++) {
		free(arr->signals[i].name);
		free(arr->signals[i].refs);
	}
	free(arr->signals);
	arr->signals = NULL;
	arr->count = 0;
	arr->capacity = 0;
}

/** Find a signal by name in an array
 * \return Pointer to signal, or NULL if not found
 */
static signal_t *
signal_find(signal_array_t *arr, const char *name)
{
	for (size_t i = 0; i < arr->count; i++) {
		if (strcmp(arr->signals[i].name, name) == 0)
			return &arr->signals[i];
	}
	return NULL;
}

/** Create a new signal in an array
 * \return Pointer to the newly created signal
 */
static signal_t *
signal_create(signal_array_t *arr, const char *name)
{
	signal_t *sig;

	/* SAFETY: Detect uninitialized signal arrays (garbage pointer + zero capacity)
	 * This can happen when objects are created before proper initialization.
	 * AwesomeWM compatibility fix: reset to NULL so realloc() acts like malloc() */
	if (arr->capacity == 0 && arr->signals != NULL) {
		arr->signals = NULL;
		arr->count = 0;
	}

	/* Grow array if needed */
	if (arr->count >= arr->capacity) {
		size_t new_cap = arr->capacity == 0 ? 4 : arr->capacity * 2;
		signal_t *new_signals = realloc(arr->signals, new_cap * sizeof(signal_t));
		if (!new_signals) {
			fprintf(stderr, "somewm:failed to allocate signal array\n");
			return NULL;
		}
		arr->signals = new_signals;
		arr->capacity = new_cap;
	}

	/* Initialize new signal */
	sig = &arr->signals[arr->count++];
	sig->name = strdup(name);
	sig->refs = NULL;
	sig->ref_count = 0;
	sig->ref_capacity = 0;

	return sig;
}

/** Add a Lua callback reference to a signal
 * \param sig The signal to add to
 * \param ref The Lua registry reference (from luaL_ref)
 */
static void
signal_add_ref(signal_t *sig, int ref)
{
	/* SAFETY: Detect uninitialized refs array (garbage pointer + zero capacity) */
	if (sig->ref_capacity == 0 && sig->refs != NULL) {
		sig->refs = NULL;
		sig->ref_count = 0;
	}

	/* Grow refs array if needed */
	if (sig->ref_count >= sig->ref_capacity) {
		size_t new_cap = sig->ref_capacity == 0 ? 2 : sig->ref_capacity * 2;
		intptr_t *new_refs = realloc(sig->refs, new_cap * sizeof(intptr_t));
		if (!new_refs) {
			fprintf(stderr, "somewm:failed to allocate signal refs\n");
			return;
		}
		sig->refs = new_refs;
		sig->ref_capacity = new_cap;
	}

	sig->refs[sig->ref_count++] = ref;
}

/** Remove a Lua callback reference from a signal
 * \param L Lua state (needed to unreference)
 * \param sig The signal to remove from
 * \param ref The Lua registry reference to remove
 * \return 1 if removed, 0 if not found
 */
static int
signal_remove_ref(lua_State *L, signal_t *sig, int ref)
{
	for (size_t i = 0; i < sig->ref_count; i++) {
		if (sig->refs[i] == ref) {
			/* Unreference in Lua registry */
			luaL_unref(L, LUA_REGISTRYINDEX, ref);

			/* Remove from array by shifting */
			for (size_t j = i; j < sig->ref_count - 1; j++) {
				sig->refs[j] = sig->refs[j + 1];
			}
			sig->ref_count--;
			return 1;
		}
	}
	return 0;
}

/** signal.connect(name, callback) - Connect a callback to a signal
 * \param name Signal name (string)
 * \param callback Lua function to call when signal is emitted
 */
static int
luaA_signal_connect(lua_State *L)
{
	const char *name;
	signal_t *sig;
	int ref;

	name = luaL_checkstring(L, 1);
	luaL_checktype(L, 2, LUA_TFUNCTION);

	/* Find or create signal */
	sig = signal_find(&global_signals, name);
	if (!sig)
		sig = signal_create(&global_signals, name);

	if (!sig)
		return 0;

	/* Store function in registry and get reference */
	lua_pushvalue(L, 2);  /* Duplicate function on stack */
	ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Add reference to signal */
	signal_add_ref(sig, ref);

	return 0;
}

/** signal.disconnect(name, callback) - Disconnect a callback from a signal
 * \param name Signal name (string)
 * \param callback Lua function to disconnect (must be same function object)
 */
static int
luaA_signal_disconnect(lua_State *L)
{
	const char *name;
	signal_t *sig;

	name = luaL_checkstring(L, 1);
	luaL_checktype(L, 2, LUA_TFUNCTION);

	sig = signal_find(&global_signals, name);
	if (!sig) {
		fprintf(stderr, "somewm:signal '%s' not found\n", name);
		return 0;
	}

	/* Find matching callback by comparing function references
	 * This is tricky - we need to check if the function matches any stored ref
	 */
	for (size_t i = 0; i < sig->ref_count; i++) {
		/* Get stored function from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Compare with provided function */
		if (lua_equal(L, -1, 2)) {
			lua_pop(L, 1);  /* Pop retrieved function */
			signal_remove_ref(L, sig, sig->refs[i]);
			return 0;
		}
		lua_pop(L, 1);  /* Pop retrieved function */
	}

	fprintf(stderr, "somewm:callback not found for signal '%s'\n", name);
	return 0;
}

/** signal.emit(name, ...) - Emit a signal, calling all connected callbacks
 * \param name Signal name (string)
 * \param ... Additional arguments to pass to callbacks
 */
static int
luaA_signal_emit(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	int nargs = lua_gettop(L) - 1;  /* Number of extra arguments */

	signal_t *sig = signal_find(&global_signals, name);
	if (!sig)
		return 0;  /* No callbacks connected, silently return */

	/* Call each connected callback */
	for (size_t i = 0; i < sig->ref_count; i++) {
		/* Get callback function from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Push all additional arguments */
		for (int arg = 2; arg <= nargs + 1; arg++) {
			lua_pushvalue(L, arg);
		}

		/* Call the callback */
		if (lua_pcall(L, nargs, 0, 0) != 0) {
			fprintf(stderr, "somewm:error calling signal '%s': %s\n",
			        name, lua_tostring(L, -1));
			lua_pop(L, 1);  /* Pop error message */
		}
	}

	return 0;
}

/** signal.list() - List all registered signals (for debugging)
 * \return Table of signal names
 */
static int
luaA_signal_list(lua_State *L)
{
	lua_newtable(L);
	for (size_t i = 0; i < global_signals.count; i++) {
		lua_pushstring(L, global_signals.signals[i].name);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/* Signal module methods */
static const luaL_Reg signal_methods[] = {
	{ "connect", luaA_signal_connect },
	{ "disconnect", luaA_signal_disconnect },
	{ "emit", luaA_signal_emit },
	{ "list", luaA_signal_list },
	{ NULL, NULL }
};

/** Setup the signal Lua module
 * Registers the global 'signal' table with signal functions
 */
void
luaA_signal_setup(lua_State *L)
{
	/* Initialize global signal array */
	signal_array_init(&global_signals);

	/* Register signal module */
	luaA_openlib(L, "signal", signal_methods, NULL);
}

/** Cleanup signal system (called on shutdown) */
void
luaA_signal_cleanup(void)
{
	signal_array_wipe(&global_signals);
}

/** Emit a global signal from C code
 * This is a convenience function for C code to emit signals without
 * needing to manage the Lua stack directly.
 * \param name Signal name to emit
 */
void
luaA_emit_signal_global(const char *name)
{
	signal_t *sig;

	if (!globalconf_L)
		return;  /* Lua not initialized */

	sig = signal_find(&global_signals, name);
	if (!sig)
		return;  /* No callbacks connected, silently return */

	/* Call each connected callback */
	for (size_t i = 0; i < sig->ref_count; i++) {
		/* Get callback function from registry */
		lua_rawgeti(globalconf_L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Call the callback with no arguments */
		if (lua_pcall(globalconf_L, 0, 0, 0) != 0) {
			fprintf(stderr, "somewm:error calling signal '%s': %s\n",
			        name, lua_tostring(globalconf_L, -1));
			lua_pop(globalconf_L, 1);  /* Pop error message */
		}
	}
}

/** Emit a global signal with a client object from C code
 * This emits a signal and passes a client pointer as lightuserdata to callbacks.
 * \param name Signal name to emit
 * \param c Client object to pass as argument
 */
void
luaA_emit_signal_global_with_client(const char *name, Client *c)
{
	signal_t *sig;

	if (!globalconf_L)
		return;  /* Lua not initialized */

	if (!c)
		return;  /* No client to pass */

	sig = signal_find(&global_signals, name);
	if (!sig)
		return;  /* No callbacks connected, silently return */

	/* Call each connected callback */
	for (size_t i = 0; i < sig->ref_count; i++) {
		/* Get callback function from registry */
		lua_rawgeti(globalconf_L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Push client as lightuserdata argument */
		lua_pushlightuserdata(globalconf_L, c);

		/* Call the callback with 1 argument (the client) */
		if (lua_pcall(globalconf_L, 1, 0, 0) != 0) {
			fprintf(stderr, "somewm:error calling signal '%s': %s\n",
			        name, lua_tostring(globalconf_L, -1));
			lua_pop(globalconf_L, 1);  /* Pop error message */
		}
	}
}

/* Forward declaration for screen push function */
extern void luaA_screen_push(lua_State *L, struct screen_t *screen);

/** Emit a global signal with a screen object from C code
 * This emits a signal and passes a screen object userdata to callbacks.
 * Note: This needs to be implemented in screen.c to avoid circular dependency
 * \param name Signal name to emit
 * \param screen Screen object to pass as argument
 */
void
luaA_emit_signal_global_with_screen(const char *name, struct screen_t *screen)
{
	signal_t *sig;
	size_t i;

	if (!globalconf_L)
		return;  /* Lua not initialized */

	if (!screen)
		return;  /* No screen to pass */

	sig = signal_find(&global_signals, name);
	if (!sig)
		return;  /* No callbacks connected, silently return */

	/* Call each connected callback */
	for (i = 0; i < sig->ref_count; i++) {
		/* Get callback function from registry */
		lua_rawgeti(globalconf_L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Push screen object as userdata argument */
		luaA_screen_push(globalconf_L, screen);

		/* Call the callback with 1 argument (the screen) */
		if (lua_pcall(globalconf_L, 1, 0, 0) != 0) {
			fprintf(stderr, "somewm: error calling signal '%s': %s\n",
			        name, lua_tostring(globalconf_L, -1));
			lua_pop(globalconf_L, 1);  /* Pop error message */
		}
	}
}

/** Emit a global signal with a table argument
 * This creates a table with the provided key-value pairs and passes it to signal handlers.
 * Used for spawn::* signals that need to pass event data.
 * \param name Signal name to emit
 * \param nargs Number of key-value pairs (must be even: key1, val1, key2, val2, ...)
 * \param ... Alternating const char* keys and values
 */
void
luaA_emit_signal_global_with_table(const char *name, int nargs, ...)
{
	signal_t *sig;
	va_list ap;
	size_t i;
	int j;

	if (!globalconf_L)
		return;  /* Lua not initialized */

	sig = signal_find(&global_signals, name);
	if (!sig)
		return;  /* No callbacks connected, silently return */

	/* Build table once (will be copied for each callback) */
	lua_createtable(globalconf_L, 0, nargs / 2);

	/* Add key-value pairs to table */
	va_start(ap, nargs);
	for (j = 0; j < nargs; j += 2) {
		const char *key = va_arg(ap, const char *);
		const char *value = va_arg(ap, const char *);
		if (value) {
			lua_pushstring(globalconf_L, value);
			lua_setfield(globalconf_L, -2, key);
		}
	}
	va_end(ap);

	/* Call each connected callback with table */
	for (i = 0; i < sig->ref_count; i++) {
		/* Get callback function from registry */
		lua_rawgeti(globalconf_L, LUA_REGISTRYINDEX, sig->refs[i]);

		/* Push copy of table as argument */
		lua_pushvalue(globalconf_L, -2);

		/* Call the callback with 1 argument (the table) */
		if (lua_pcall(globalconf_L, 1, 0, 0) != 0) {
			fprintf(stderr, "somewm:error calling signal '%s': %s\n",
			        name, lua_tostring(globalconf_L, -1));
			lua_pop(globalconf_L, 1);  /* Pop error message */
		}
	}

	/* Pop the table */
	lua_pop(globalconf_L, 1);
}
