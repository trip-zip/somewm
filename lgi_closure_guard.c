/* lgi_closure_guard.c — LD_PRELOAD interposition for Lgi FFI closures.
 *
 * Wraps ffi_prep_closure_loc() to tag each Lgi-originated closure with
 * a generation number. On hot-reload, somewm bumps the generation via
 * lgi_guard_bump_generation() (resolved through dlsym). Stale closures
 * from previous Lua states become silent no-ops instead of SEGVing.
 *
 * Additionally validates Lgi closure internal state before dispatch:
 * checks that the callable registry ref resolves to valid userdata.
 * This prevents crashes from closures whose Lua state is corrupted
 * after hot-reload (even if generation matches).
 *
 * Build: shared_library in meson.build
 * Usage: LD_PRELOAD=/usr/local/lib/liblgi_closure_guard.so somewm
 */

#define _GNU_SOURCE
#include <ffi.h>
#include <glib.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

/* ================================================================
 * Lgi internal structures (from lgi/callable.c, version 0.9.2)
 * Replicated here to validate closure state before dispatch.
 *
 * Layout (confirmed from lgi source):
 *   FfiClosure = { ffi_closure, *block, union{callable_ref+target_ref | call_addr}, bits }
 *   FfiClosureBlock = { FfiClosure (first closure inline), Callback, count, FfiClosure*[] }
 *   Callback = { lua_State *L, int thread_ref, gpointer state_lock }
 * ================================================================ */

typedef struct _LgiCallback {
	lua_State *L;
	int thread_ref;
	gpointer state_lock;
} LgiCallback;

typedef struct _LgiFfiClosureBlock LgiFfiClosureBlock;

typedef struct _LgiFfiClosure {
	ffi_closure ffi_closure_inner;
	LgiFfiClosureBlock *block;
	union {
		struct {
			int callable_ref;
			int target_ref;
		};
		gpointer call_addr;
	};
	guint autodestroy : 1;
	guint created : 1;
} LgiFfiClosure;

struct _LgiFfiClosureBlock {
	LgiFfiClosure ffi_closure;  /* first closure inline */
	LgiCallback callback;
	int closures_count;
	LgiFfiClosure *ffi_closures[1];
};

/* ================================================================
 * Guard state
 * ================================================================ */

static volatile gint lgi_guard_generation = 0;
static volatile gint lgi_guard_ready_gen = 0;
static volatile gint lgi_guard_wrapped = 0;
static volatile gint lgi_guard_total = 0;
static volatile gint lgi_guard_blocked = 0;

void lgi_guard_bump_generation(void)
{
	gint new_gen = g_atomic_int_add(&lgi_guard_generation, 1) + 1;
	fprintf(stderr, "somewm: lgi_guard: bumped to generation %d "
		"(wrapped %d/%d, blocked %d)\n", new_gen,
		g_atomic_int_get(&lgi_guard_wrapped),
		g_atomic_int_get(&lgi_guard_total),
		g_atomic_int_get(&lgi_guard_blocked));
}

void lgi_guard_mark_ready(void)
{
	gint gen = g_atomic_int_get(&lgi_guard_generation);
	g_atomic_int_set(&lgi_guard_ready_gen, gen);
	fprintf(stderr, "somewm: lgi_guard: generation %d marked ready\n", gen);
}

/* ================================================================
 * Closure wrapper
 * ================================================================ */

typedef struct {
	void (*real_fn)(ffi_cif *, void *, void **, void *);
	void *real_user_data;
	gint generation;
} LgiGuardWrapper;

/* Validate that the Lgi closure's internal state is usable.
 * Returns TRUE if the closure can safely be dispatched. */
/* Validate that the Lgi closure's internal state is usable.
 * Returns TRUE if the closure can safely be dispatched.
 * Mirrors the checks closure_callback does before calling into Lua. */
static gboolean
lgi_closure_is_valid(void *closure_arg)
{
	LgiFfiClosure *closure = closure_arg;
	if (!closure || !closure->block)
		return FALSE;

	LgiFfiClosureBlock *block = closure->block;
	lua_State *L = block->callback.L;
	if (!L)
		return FALSE;

	int top = lua_gettop(L);

	/* Check thread_ref — closure_callback does this first */
	lua_rawgeti(L, LUA_REGISTRYINDEX, block->callback.thread_ref);
	if (lua_type(L, -1) != LUA_TTHREAD) {
		lua_settop(L, top);
		return FALSE;
	}
	lua_State *thread_L = lua_tothread(L, -1);
	lua_settop(L, top);
	if (!thread_L)
		return FALSE;

	/* Check callable_ref — this is what crashes as NULL */
	int thread_top = lua_gettop(thread_L);
	lua_rawgeti(thread_L, LUA_REGISTRYINDEX, closure->callable_ref);
	gboolean valid = (lua_touserdata(thread_L, -1) != NULL);
	lua_settop(thread_L, thread_top);

	return valid;
}

static void
lgi_guard_callback(ffi_cif *cif, void *ret, void **args, void *user_data)
{
	LgiGuardWrapper *w = user_data;
	gint ready = g_atomic_int_get(&lgi_guard_ready_gen);

	/* Block closures from non-ready generations */
	if (w->generation != ready) {
		g_atomic_int_add(&lgi_guard_blocked, 1);
		if (ret && cif->rtype && cif->rtype->size > 0)
			memset(ret, 0, cif->rtype->size);
		return;
	}

	/* Validate Lgi internal state before dispatch */
	if (!lgi_closure_is_valid(w->real_user_data)) {
		g_atomic_int_add(&lgi_guard_blocked, 1);
		if (ret && cif->rtype && cif->rtype->size > 0)
			memset(ret, 0, cif->rtype->size);
		return;
	}

	w->real_fn(cif, ret, args, w->real_user_data);
}

/* ================================================================
 * Lgi detection + interposition
 * ================================================================ */

static gboolean
is_lgi_function(void (*fun)(ffi_cif *, void *, void **, void *))
{
	Dl_info info;
	if (!dladdr((void *)(fun), &info))
		return FALSE;
	if (!info.dli_fname)
		return FALSE;
	return strstr(info.dli_fname, "corelgi") != NULL;
}

static ffi_status (*real_ffi_prep)(
	ffi_closure *, ffi_cif *,
	void (*)(ffi_cif *, void *, void **, void *), void *, void *) = NULL;

__asm__(".symver ffi_prep_closure_loc_impl,ffi_prep_closure_loc@@LIBFFI_CLOSURE_8.0");

ffi_status
ffi_prep_closure_loc_impl(ffi_closure *closure, ffi_cif *cif,
	void (*fun)(ffi_cif *, void *, void **, void *),
	void *user_data, void *codeloc)
{
	if (!real_ffi_prep) {
		real_ffi_prep = dlvsym(RTLD_NEXT, "ffi_prep_closure_loc",
			"LIBFFI_CLOSURE_8.0");
	}
	if (!real_ffi_prep)
		real_ffi_prep = dlsym(RTLD_NEXT, "ffi_prep_closure_loc");

	g_atomic_int_add(&lgi_guard_total, 1);

	if (!is_lgi_function(fun))
		return real_ffi_prep(closure, cif, fun, user_data, codeloc);

	LgiGuardWrapper *w = malloc(sizeof(*w));
	if (!w)
		return real_ffi_prep(closure, cif, fun, user_data, codeloc);

	w->real_fn = fun;
	w->real_user_data = user_data;
	w->generation = g_atomic_int_get(&lgi_guard_generation);

	g_atomic_int_add(&lgi_guard_wrapped, 1);

	return real_ffi_prep(closure, cif, lgi_guard_callback, w, codeloc);
}
