# Restart / hot-reload tests

Tests that assert on both sides of a real `awesome.restart()`. The suite is
also home to plain D-Bus tests (`notify-reply-paths.sh`): it is the only
harness that gives each test a private session bus and drives a sandboxed
instance from outside.

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

A test that pins a known-but-unfixed bug declares it at the top:

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
- An xfail that failed for a reason other than a failed assertion is an
  **ERROR**, not an XFAIL. A test that breaks because the compositor never
  started must not masquerade as a pinned bug. The runner decides this from
  the tally `finish` writes, so a test killed part-way through leaves no tally
  and is an error rather than being scored on whatever it had printed. An xfail
  whose very first assertion fails is still an XFAIL: what it needs is a failed
  assertion, not a passing one as well.

The same rule runs in the other direction for every test, xfail or not: exiting
0 is not a pass unless the tally shows at least one passing assertion. A test
that returns early, or whose last command merely happens to succeed, is an
**ERROR**.

There are currently no expected failures; every test in the suite is expected
to pass.

One assertion is contract-wide rather than test-specific, and every test gets
it: `sw_check_log_clean` fails on the warnings a surviving GLib source or a
surviving lgi closure prints. A module that registers either and does not
release it on `"exit"` reddens whichever reload test runs next.

## What each test pins

- `restart-executes`: the reload actually runs and completes. The predecessor
  tests were green while never executing a reload, so this one asserts on a
  wiped-global witness that only a real state rebuild can produce.
- `state-closed-after-restart`: the old Lua state is closed, not abandoned. It
  plants a userdata whose `__gc` writes a marker. GC is stopped on the old
  state for the whole reload and the userdata is reachable from `_G`, so
  nothing but `lua_close()` can run that finalizer.
- `double-restart`: lgi closures do not accumulate across reloads. An
  abandoned state frees none of its own, so the guard's live count tracks its
  cumulative wrapped count, and a closed one leaves a single state's set
  alive. Do not compare live counts between two reloads instead; a state whose
  asynchronous D-Bus setup had not finished when the reload landed has three
  fewer closures than one that had.
- `notify-after-restart`: notifications keep working after a reload. They used
  to die permanently because the reload closed the shared GDBus session
  connection; `bus-open-after-restart` pins the connection itself. Deleting
  the close needed the `"exit"` release contract first, or the rebuilt state
  collides with the abandoned one on a connection that now stays open.
- `remote-eval-after-restart`: remote eval over D-Bus answers after a reload.
  It used to die on the first reload because the signal handler table kept
  registry refs from the old state.
- `keygrabber-after-restart`: reloading during an active grab does not leave
  the keygrabber permanently stuck "already running".
- `globalconf-pointers-after-restart`: stale pointers held in globalconf are
  reset. Two members of the cluster have a cheap probe: `awesome.locked`
  reports the lock flag, and `root._keys` is the C entry point that
  `root.keys` hides.
- `idle-timeout-unref-smoke`: releasing an idle timeout after a reload does
  not free unrelated slots in the new state's registry.
- `animation-metatable-after-restart`: animation handles keep their methods
  after a reload; the handle metatable is registered per state, which covers
  the config-timeout path too.
- `animation-ticks-after-restart`: an animation still advances on an
  otherwise idle loop after a reload; the keepalive timer belongs to the
  wl_event_loop and is disarmed at reload, not removed. The test has to leave
  the instance alone while the animation runs: it arms the animation in one
  eval, sleeps in the shell, and reads the result in a second. Any poll loop
  drives a refresh per eval and rescues the animation it is watching.
  `animation-metatable-after-restart` stays green through this failure mode,
  since a handle keeps its methods whether or not it ticks.
- `search-paths-after-restart`: a rebuilt state resolves modules from the same
  search paths as boot. Boot and reload used to keep two hand-maintained
  copies of the registration list, which had drifted; both now run
  `luaA_register_state`. The test pins the half that is outside-visible: only
  the boot copy prepended somewm's `package.cpath`.
- `statusnotifierwatcher-after-restart`: the tray watcher service still
  answers from the live state after a reload. Ownership cannot show this,
  since every state owns the name on the one process-wide connection; a
  missing release kills the service instead. The test seeds a phase-unique
  marker into the live state's item list and reads it back over the bus, so
  the reply says which state answered.
- `ipc-subscribe-across-restart`: a subscribed `somewm-client` keeps receiving
  events after a reload. C owns the fd and the subscribed flag; the fix asks C
  whether anyone is subscribed rather than keeping a second count in Lua.
- `layer-surface-after-restart`: layer surfaces are re-created in the rebuilt
  state. The wlroots listeners belong to the C LayerSurface, which the reload
  never frees, so only the Lua half went stale and the fix rebuilds it from
  the surviving structs.
- `selection-after-restart`: clipboard watcher and acquire listeners are
  detached at reload instead of dispatching into the dead state. Its watcher
  assertion counts dispatch lines in the log rather than a Lua-side counter,
  because a dispatch to the *live* watcher also logs `Trying to emit signal
  ... on non-object`: no selection object is ever entered into the object
  registry, so `luaA_object_push` cannot find one and `selection_changed`,
  `release` and `request` never reach Lua at all. That is a separate,
  pre-existing bug, not a reload bug, and it is why the expected count is 2
  rather than 0. Fix it and this test needs rewriting onto a Lua-side counter
  in `configs/rc-selection.lua`.
- `boot-timer-after-restart`: a timer armed while the first config loads is
  released instead of outliving the state the reload closes. The source sweep
  never saw those sources, since its baseline was recorded from the Wayland
  source, which `run()` attaches after the config has loaded. Fixed in both
  halves: a release contract in `gears.timer`, and a baseline the sweep can
  act on. Reverting either segfaults the instance in libffi, so a failure
  here can look like a dead instance rather than a failed assertion.
- `timer-release-on-double-exit`: `"exit"` reaching one state twice, which
  happens whenever a reload emits it and then quits. The release in
  `gears.timer` left each timer in its registry with the source id already
  nil, so the second pass called `glib.source_remove(nil)` and threw out of an
  exit handler. The test emits the signal directly rather than faulting an
  allocation, which is the same entry point both emitters use.
- `client-during-hung-reload`: a reloaded config that hangs aborts through
  the same `lua_close()` the config-timeout path has always used, with
  clients already restored into the state it closes. The test swaps the
  config under a running instance, since no startup can reach that state: at
  startup there are no clients yet.
- `tags-after-restart`, `client-survives-restart`, `client-order-after-restart`,
  `transient-screen-restart`, `client-screen-after-restart`: clients, tags,
  stacking order, transient relationships and the client's screen survive a
  reload.
- `startup-flag-across-reload`: `awesome.startup` is true during a reload's
  config load too, and `awesome._restart` says which it was.

Config-timeout tests (a config that hangs longer than the limit is aborted and
the fallback loads):

- `timers-after-config-timeout`: timers and spawn callbacks work after a
  config timeout instead of being silently dropped forever.
- `dbus-after-config-timeout`: the abort's source cleanup no longer destroys
  the libdbus watches, so D-Bus dispatch survives.
- `screens-after-config-timeout`: the retried config gets real screens. The
  abort closes the state, so every screen userdata is freed while the C-side
  ref arrays live on; without the rebuild, naughty's startup-error fallback
  fake_adds a phantom screen.
- `class-signals-after-config-timeout`: class signal handlers connected by the
  aborted config do not dispatch into the closed state. Class signal arrays
  live on the C-side `lua_class_t`, so they outlive the `lua_close()` the
  abort performs; the reload path already cleared them, the timeout path did
  not.
- `startup-error-after-config-timeout`: the "config timed out" error is
  actually displayed. This is the one config-timeout test that loads the real
  `somewmrc.lua`, since the handler under test lives there.

## Covered manually, not by this suite

- EWMH class-signal reconnection after a reload is fixed but untestable from
  outside. The properties a probe can read (`_NET_CLIENT_LIST`,
  `_NET_ACTIVE_WINDOW`) are maintained by wlroots' own xwm and stay correct
  with every somewm handler dead, and the ones somewm writes itself never
  reach the server because nothing calls `xcb_flush()`. Either kind of test
  passes with or without the fix. Verified by instrumenting `ewmh_init_lua`
  instead.
- The reload's allocation-failure paths have no test: reaching them from
  outside the process means faulting the allocator. Verified by making the
  tag snapshot allocation fail, which quits with the in-progress flag cleared
  and the guard generation marked, instead of returning into a half-torn
  state.
