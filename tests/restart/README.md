# Restart / hot-reload tests

Tests that assert on both sides of a real `awesome.restart()`.

## Why this suite exists separately

`awesome.restart()` rebuilds the Lua state in place. A test written with
`tests/_runner.lua` lives *inside* the state being destroyed, so it cannot make a
post-reload assertion. Worse, it never even reaches the reload: `awesome.restart()`
only queues a GLib idle, and `runner.done()` calls `awesome.quit()` in the same
dispatch, so the loop exits first. Four hot-reload tests were green for a long
time while never entering the code path they named.

These tests drive a sandboxed instance from outside, through
`somewm-client test` (`test_orchestrator.c`), which is a persistent process with
`start / eval / reload / logs / stop`. Assertions come from eval return values
and the instance log, checked in the shell.

## Running

```bash
make test-restart                                        # everything
make test-one-restart TEST=tests/restart/restart-executes.sh
bash tests/restart/restart-executes.sh                   # standalone, for debugging
```

Environment: `KEEP_LOGS=1` keeps instance logs for passing tests,
`SOMEWM_EVAL_PACE` tunes the delay between evals (default 0.5s; rapid-fire evals
return empty), `REQUIRE_ALL=1` turns a SKIP into a suite failure (CI uses this).

Instance logs land in `build-test/restart-artifacts/`.

## Writing a test

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"

sw_start myinst --config "$ROOT_DIR/tests/rc.lua" || finish
check_eval myinst "description" 'return 1+1' 2
sw_reload myinst || finish
check_eval myinst "still works" 'return 1+1' 2
finish
```

Rules that bite:

- **Eval payloads are single-line.** The orchestrator joins argv with single
  spaces, so use `;` between statements. A `--` comment swallows the rest of the
  chunk. Results are `tostring`'d, so return strings, numbers or booleans; a
  table comes back as `table: 0x...`.
- **Always pass `--config`.** Without it the config search reaches
  `$XDG_CONFIG_HOME/somewm/rc.lua` and then `$HOME/.config/awesome/rc.lua`, and
  the test silently runs the developer's real config.
- **Never assert on a `gdbus` exit status alone.** A dead remote-eval endpoint
  answers with empty output and exit 0. Assert on `$BUS_OUT`.
- **Resolve bus names to a pid** with `sw_bus_owner_pid` and compare against the
  instance pid. `dbus-run-session` still honours `/usr/share/dbus-1/services`, so
  a real notification daemon can be activated on the private bus and turn a
  regression test permanently green.
- Pack several facts into one probe string (`"count=2|order=A,B"`) rather than
  making several round trips; each eval costs `SOMEWM_EVAL_PACE`.

## Expected failures

A test that pins an unfixed defect declares it at the top:

```bash
# xfail: every reload leaks the old Lua state and its lgi closures
```

The runner reads that line statically, before running the test, so the
classification survives a test that dies early. It is a comment, not a call, so
it cannot depend on `lib.sh` having been sourced yet.

- An xfail that fails is **XFAIL**, and the suite stays green.
- An xfail that **passes** is **XPASS**, and the suite goes **red**. The change
  that fixes the bug must delete the flag in that same change. There is no
  opt-out.
- An xfail that never asserted anything, or that failed for a reason other than
  a failed assertion, is an **ERROR**, not an XFAIL. A test that breaks because
  the compositor never started must not masquerade as a pinned defect. The
  runner decides this from the tally `finish` writes, so a test killed part-way
  through leaves no tally and is an error rather than being scored on whatever
  it had printed.

## What each expected failure pins

| symptom | pinned by |
|---|---|
| The four old hot-reload tests never executed the reload. | retired: this whole suite, `restart-executes` in particular |
| Per-reload resource accumulation: the old state is leaked with GC stopped, and the lgi closure population roughly doubles per reload. | `double-restart` (census half) |

Fixed defects keep their tests, now as plain regression tests:

- Notifications permanently dead after any restart (issue 444), because
  the reload closed the shared GDBus session connection:
  `notify-after-restart` for the symptom, `bus-open-after-restart` for the
  connection itself. Deleting the close needed the `"exit"` release contract
  first, or the rebuilt state collides with the abandoned one on a connection
  that now stays open.
- Remote eval dead after the first reload, because the signal handler table
  kept old-state registry refs: `remote-eval-after-restart`.
- lgi callbacks dropped after a config timeout: `timers-after-config-timeout`.
- `luaL_unref` of old-state refs against the new state freeing arbitrary
  live registry slots: `idle-timeout-unref-smoke`.
- Keygrabber permanently unusable after reloading during a grab:
  `keygrabber-after-restart`.
- Stale pointer cluster in globalconf:
  `globalconf-pointers-after-restart`. Added with the fix, so it never pinned
  the bug as an expected failure. Two members of the cluster do have a cheap
  probe after all: `awesome.locked` reports `lua_locked`, and `root._keys` is
  the C entry point that `root.keys` hides.
- Animation handles losing their metatable, because
  `animation_setup()` ran only at boot: `animation-metatable-after-restart`.
  Fixed by calling it from `luaA_create_fresh_state`, which covers the
  config-timeout path too.
- Boot and reload kept two hand-maintained copies of the registration
  list, which had drifted: `search-paths-after-restart`. Both now run
  `luaA_register_state`. The test pins the half that was outside-visible: only
  the boot copy prepended somewm's `package.cpath`.
- statusnotifierwatcher never released its name ownership, object
  registration or name watches: `statusnotifierwatcher-after-restart`.
  Ownership cannot show this, since every state owns the name on the one
  process-wide connection; a missing release kills the service instead. The test
  seeds a phase-unique marker into the live state's item list and reads it back
  over the bus, so the reply says which state answered.
- IPC event subscriptions going silent after a reload:
  `ipc-subscribe-across-restart`. Fixed by asking C whether anyone is
  subscribed rather than keeping a second count in Lua.
- Class signal handlers surviving a config timeout:
  `class-signals-after-config-timeout`. Class signal arrays live on the C-side
  `lua_class_t`, so they outlive the `lua_close()` the abort performs, and the
  next emit dispatches refs into a closed state. The reload path already called
  `luaA_class_cleanup_all()`; the timeout path did not.
- Screens and outputs not rebuilt after a config timeout:
  `screens-after-config-timeout`. Found while chasing the `naughty`
  traceback that the startup-error test's log still carried. The timeout path
  closes the state, so every screen userdata is freed while `screen_refs` keeps
  its registry ints, and naughty's startup-error fallback then fake_adds a
  phantom screen.
- The timeout sweep destroying the libdbus watches: `dbus-after-config-timeout`.
- Layer surfaces orphaned from Lua after a reload:
  `layer-surface-after-restart`. The wlroots listeners belong to the C
  LayerSurface, which the reload never frees, so only the Lua half went stale
  and the fix rebuilds it from the surviving structs.
- Selection watcher and acquire listeners left linked into the seat:
  `selection-after-restart`. Its watcher assertion counts dispatch lines in the
  log rather than a Lua-side counter, because a dispatch to the *live* watcher
  also logs `Trying to emit signal ... on non-object`: no selection object is
  ever entered into the object registry, so `luaA_object_push` cannot find one
  and `selection_changed`, `release` and `request` never reach Lua at all. That
  is a separate, pre-existing defect, not a reload defect, and it is why the
  expected count is 2 rather than 0. Fix it and this test needs rewriting onto a
  Lua-side counter in `configs/rc-selection.lua`.
- The startup-error display dying before a usable screen existed:
  `startup-error-after-config-timeout`, the one config-timeout test that loads
  the real `somewmrc.lua`, since the handler under test lives there.

Defects with no test here are covered manually or by a later stage:

- EWMH class-signal reconnection is fixed but untestable from
  outside. The properties a probe can read (`_NET_CLIENT_LIST`,
  `_NET_ACTIVE_WINDOW`) are maintained by wlroots' own xwm and stay correct
  with every somewm handler dead, and the ones somewm writes itself never
  reach the server because nothing calls `xcb_flush()`. Either kind of test
  passes with or without the fix. Verified by instrumenting `ewmh_init_lua`
  instead.
- Keybinding array shadowing and growth is traced. `_key.bind` has no
  Lua callers today, so the array only fills for a config that uses it.
- Half-torn states on reload error paths are traced but not cheaply
  reproducible from outside the process.
