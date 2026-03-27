# Fix: Hot-reload Lgi FFI closure crash (second reload SEGV)

## Problem

After Lua hot-reload, old Lgi FFI closures survive in `ffi_closure` memory
(allocated outside Lua heap via `ffi_closure_alloc`). When GLib dispatches
them — either via GSource (timers, idle, I/O) OR GSignal (synchronous
object signals) — they access dead `lua_State*` → SEGV.

First reload works (GLib source sweep removes most GSource dispatchers).
Second reload crashes because FFI closures from the first leaked state
persist and fire via GSignal paths that bypass GMainContext entirely.

## Root Cause (precise)

```
FfiClosureBlock (ffi_closure_alloc, outside Lua heap):
  callback.L         → dead lua_State*
  callback.thread_ref → ref into dead registry
  callback.state_lock → LgiStateMutex* (leaked userdata)
```

Two callback dispatch paths:
1. **GSource** (timers, idle, I/O, dbus) → goes through GMainContext → removable by source sweep
2. **GSignal** (g_signal_connect) → synchronous, object emits → closure fires directly → NOT removable

`closure_callback()` flow:
1. `lgi_state_enter(state_lock)` — GRecMutex (recursive, same-thread always succeeds)
2. `lua_rawgeti(block->callback.L, ...)` — dereference dead state → **SEGV**

## Why previous attempts failed

| Attempt | Result | Why |
|---------|--------|-----|
| GLib source sweep | First reload OK, second crashes | Only removes GSource, not GSignal callbacks |
| Poison mutex (dead GRecMutex) | Same-thread re-lock succeeds | GRecMutex is recursive; GLib is single-threaded |
| `lua_close()` | Immediate crash | Client snapshots reference Lua userdata |
| `lua_gc()` collect | Still crashes later | Doesn't free `ffi_closure` (outside Lua heap) |

## Proposed Solutions (ranked by all 3 AI models)

### Solution 1: Linker-wrap `ffi_prep_closure_loc` (RECOMMENDED)

**Source:** Sonnet 4.6 (detailed implementation), Gemini 3.1 Pro (concept).
**Consensus:** Best approach — no Lgi fork, catches both GSource AND GSignal paths.

**How it works:**
Every Lgi FFI closure goes through `ffi_prep_closure_loc()` at creation time.
We use the linker `--wrap` flag to intercept this call and wrap each closure
with a generation counter. On hot-reload, increment the counter. Stale closures
detect the mismatch and silently no-op instead of touching dead `lua_State*`.

**Files:**
- `lgi_closure_guard.c` — new file (~80 lines)
- `meson.build` — add source + `--wrap` linker flag
- `luaa.c` — call `lgi_guard_bump_generation()` before leaking old state

**Key code:**

```c
/* Per-closure wrapper */
typedef struct {
    void (*real_fn)(ffi_cif *, void *, void **, void *);
    void *real_user_data;
    guint32 generation;
} LgiGuardWrapper;

static volatile guint32 lgi_guard_generation = 0;

void lgi_guard_bump_generation(void) {
    g_atomic_int_inc((gint *)&lgi_guard_generation);
}

static void
lgi_guard_callback(ffi_cif *cif, void *ret, void **args, void *user_data)
{
    LgiGuardWrapper *w = user_data;
    if (w->generation != g_atomic_int_get((gint *)&lgi_guard_generation)) {
        /* Stale closure — zero return, don't touch Lua */
        if (ret && cif->rtype && cif->rtype->size > 0)
            memset(ret, 0, cif->rtype->size);
        return;
    }
    w->real_fn(cif, ret, args, w->real_user_data);
}

/* Only wrap Lgi closures (check if fun is in lgi .so address range) */
ffi_status __wrap_ffi_prep_closure_loc(ffi_closure *closure, ffi_cif *cif,
    void (*fun)(ffi_cif*,void*,void**,void*), void *user_data, void *codeloc)
{
    if (!is_lgi_function(fun))
        return __real_ffi_prep_closure_loc(closure, cif, fun, user_data, codeloc);

    LgiGuardWrapper *w = malloc(sizeof(*w));
    w->real_fn = fun;
    w->real_user_data = user_data;
    w->generation = lgi_guard_generation;
    return __real_ffi_prep_closure_loc(closure, cif, lgi_guard_callback, w, codeloc);
}
```

**Pros:**
- No Lgi fork needed — works with system Lgi package
- Catches BOTH GSource and GSignal dispatch paths
- O(1) generation check — zero normal-operation overhead
- Survives unlimited consecutive reloads
- ~80 lines of C, minimal invasiveness

**Cons:**
- ~24 bytes leaked per closure per reload (~2.4KB for ~100 closures)
- `is_lgi_function()` range check uses heuristic (can tighten via /proc/self/maps)
- GNU linker specific (`--wrap` flag)

### Solution 2: Patch Lgi — epoch/alive token

**Source:** Codex GPT-5.4.

Add per-state `LgiClosureEpoch` with atomic `alive` flag to Lgi.
Export `lgi_state_retire(L)`. Compositor calls it during hot-reload.

**Pros:** Architecturally correct — fixes the bug at the owning layer.
**Cons:** Requires shipping patched Lgi (fork + subproject or AUR).

### Solution 3: `ffi_closure_alloc` interposition (dlsym variant)

**Source:** Gemini 3.1 Pro.

Track all `ffi_closure_alloc` calls. During reload, scan closure memory
for old `lua_State*` pointer and overwrite `closure->fun` with dummy.

**Pros:** No fork needed.
**Cons:** ABI-dependent memory scanning, fragile across versions.

### Solution 4: Submit epoch patch upstream to lgi-devs/lgi

Same as Solution 2 but as upstream PR. Benefits entire ecosystem.
Can be done in parallel with Solution 1.

## Implementation Plan

### Phase 1: Linker-wrap guard (Solution 1) — immediate fix

1. Create `lgi_closure_guard.c` with generation-tagged wrapping
2. Add to `meson.build` with `--wrap=ffi_prep_closure_loc`
3. Add `lgi_guard_bump_generation()` call to `luaA_hot_reload()`
4. Keep existing GLib source sweep as belt-and-suspenders
5. Test: 3+ consecutive reloads without crash

### Phase 2: Upstream Lgi contribution (Solution 4) — long-term

6. Fork `lgi-devs/lgi` → `raven2cz/lgi`
7. Apply epoch patch (callable.c, core.c)
8. Submit PR with test case demonstrating reload crash
9. Reference issues #133, #9, #155

### Phase 3: GMainContext isolation (optional hardening)

10. Create dedicated context for Lua timer/idle sources
11. Destroy context on reload as additional safety layer

## References

- [lgi callable.c](https://github.com/lgi-devs/lgi/blob/master/lgi/callable.c) — FFI closure impl
- [lgi core.c](https://github.com/lgi-devs/lgi/blob/master/lgi/core.c) — State mutex mgmt
- [lgi-devs/lgi#133](https://github.com/lgi-devs/lgi/issues/133) — Crash on reload
- [lgi-devs/lgi#9](https://github.com/lgi-devs/lgi/issues/9) — GLib reinit segfaults
- [lgi-devs/lgi#155](https://github.com/lgi-devs/lgi/issues/155) — Use-after-free
- [way-cooler#555](https://github.com/way-cooler/way-cooler/issues/555) — Same problem

## Review

Analyzed by: Claude Opus 4.6, Claude Sonnet 4.6, OpenAI GPT-5.4, Google Gemini 3.1 Pro
All three external models converge on libffi interposition as the best no-fork approach.
Codex recommends Lgi patch as architecturally superior if fork is acceptable.
