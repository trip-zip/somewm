/* lgi_closure_guard.c — LD_PRELOAD interposition for Lgi FFI closures.
 *
 * Wraps ffi_prep_closure_loc() to tag each Lgi-originated closure with
 * a generation number. On hot-reload, somewm bumps the generation via
 * lgi_guard_bump_generation() (resolved through dlsym). Stale closures
 * from previous Lua states become no-ops instead of SEGVing, and each
 * generation says so once.
 *
 * A canary, not a safety net, and the difference matters. It can only speak
 * once libffi has already walked the closure's cif to marshal the call, and
 * that cif lives in the Lua state: close the state and the walk reads freed
 * memory, killing the process before the wrapper below is ever entered. What
 * actually keeps a state's callbacks from outliving it is every module
 * releasing what it registered on "exit"; a block here means one did not.
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

/* Whether this generation has already reported a block, so a stale 100ms timer
 * names itself once instead of every tick. */
static volatile gint lgi_guard_reported = 0;

typedef struct {
	void (*real_fn)(ffi_cif *, void *, void **, void *);
	void *real_user_data;
	gint generation;
} LgiGuardWrapper;

/* Closures wrapped and not yet freed, keyed by the address libffi was given.
 * The counters above only ever grow, so they cannot answer the question a
 * hot-reload needs answered: is anything from the state being torn down still
 * registered with GLib? An lgi closure only outlives its call when something
 * external holds it, so a live one after teardown means a module did not
 * release what it registered. */
static GHashTable *live_closures = NULL;
static GMutex live_lock;

/** How many wrapped closures are still alive.
 * \param generation Count only this generation, or -1 for all of them.
 */
int lgi_guard_live_count(int generation)
{
	GHashTableIter iter;
	gpointer value;
	int count = 0;

	g_mutex_lock(&live_lock);
	if (live_closures) {
		g_hash_table_iter_init(&iter, live_closures);
		while (g_hash_table_iter_next(&iter, NULL, &value)) {
			LgiGuardWrapper *w = value;
			if (generation < 0 || w->generation == generation)
				count++;
		}
	}
	g_mutex_unlock(&live_lock);
	return count;
}


void lgi_guard_bump_generation(void)
{
	gint old_gen = g_atomic_int_get(&lgi_guard_generation);
	gint new_gen = g_atomic_int_add(&lgi_guard_generation, 1) + 1;

	/* No generation is ready until mark_ready names one. Leaving the old
	 * generation ready here would let the closures of the state being torn
	 * down dispatch for the whole rebuild, which spans the lua_close() that
	 * frees what they point at. */
	g_atomic_int_set(&lgi_guard_ready_gen, -1);
	g_atomic_int_set(&lgi_guard_reported, 0);

	fprintf(stderr, "somewm: lgi_guard: bumped to generation %d "
		"(wrapped %d/%d, blocked %d, live %d, live in generation %d: %d)\n",
		new_gen,
		g_atomic_int_get(&lgi_guard_wrapped),
		g_atomic_int_get(&lgi_guard_total),
		g_atomic_int_get(&lgi_guard_blocked),
		lgi_guard_live_count(-1),
		old_gen, lgi_guard_live_count(old_gen));
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

	/* The generation check must stay first. lgi_closure_is_valid() reads
	 * the Lua state the closure was created in, which for any closure that
	 * outlived its state is freed memory. */
	if (w->generation != ready) {
		g_atomic_int_add(&lgi_guard_blocked, 1);
		if (g_atomic_int_compare_and_exchange(&lgi_guard_reported, 0, 1))
			fprintf(stderr, "somewm: lgi_guard: WARNING: blocked a "
				"callback from generation %d (ready %d); a "
				"module did not release what it registered "
				"on \"exit\"\n", w->generation, ready);
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

/* Interposing means every caller reaches libffi through here, so a symbol this
 * cannot resolve is not a degraded guard, it is a call through NULL on the next
 * closure. Say which symbol and stop. */
static void *
guard_resolve(const char *sym)
{
	void *fn = dlvsym(RTLD_NEXT, sym, "LIBFFI_CLOSURE_8.0");

	if (!fn)
		fn = dlsym(RTLD_NEXT, sym);
	if (!fn) {
		const char *err = dlerror();

		fprintf(stderr, "somewm: lgi_guard: FATAL: cannot resolve %s in "
			"libffi (%s)\n", sym, err ? err : "no error reported");
		abort();
	}
	return fn;
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
	if (!real_ffi_prep)
		*(void **)&real_ffi_prep = guard_resolve("ffi_prep_closure_loc");

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

	g_mutex_lock(&live_lock);
	if (!live_closures)
		live_closures = g_hash_table_new_full(NULL, NULL, NULL, free);
	g_hash_table_insert(live_closures, closure, w);
	g_mutex_unlock(&live_lock);

	return real_ffi_prep(closure, cif, lgi_guard_callback, w, codeloc);
}

static void (*real_ffi_closure_free)(void *) = NULL;

__asm__(".symver ffi_closure_free_impl,ffi_closure_free@@LIBFFI_CLOSURE_8.0");

/* lgi_closure_destroy() frees each closure here, with the same address it
 * passed to ffi_prep_closure_loc, which is what makes the live set exact.
 * Closures it allocated but never prepared are not in the table. */
void
ffi_closure_free_impl(void *closure)
{
	if (!real_ffi_closure_free)
		*(void **)&real_ffi_closure_free = guard_resolve("ffi_closure_free");

	g_mutex_lock(&live_lock);
	if (live_closures)
		g_hash_table_remove(live_closures, closure);
	g_mutex_unlock(&live_lock);

	real_ffi_closure_free(closure);
}
