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
# xfail: naughty never re-owns org.freedesktop.Notifications after a reload
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
| Notifications permanently dead after any restart (issue 444). The reload closes the shared GDBus session bus; GLib's singleton cache hands the closed object to every later `bus_get_sync`, so naughty never re-owns its name. | `notify-after-restart`, `bus-open-after-restart`, `dbus-name-census-after-restart` |
| `awesome-client` / remote eval dead after the first reload. The signal handler table keeps old-state registry refs, so re-registration is refused and dispatch pushes nil. | `remote-eval-after-restart` |
| After a config timeout, every lgi callback is silently dropped forever. The timeout path bumps the closure-guard generation but never marks it ready. | `timers-after-config-timeout` |
| The config-timeout source sweep runs with `baseline=0` and destroys the libdbus watch sources, so incoming D-Bus is never dispatched again. | `dbus-after-config-timeout` |
| The four old hot-reload tests never executed the reload. | retired: this whole suite, `restart-executes` in particular |
| `luaL_unref` of old-state refs against the new state frees arbitrary live registry slots. | `idle-timeout-unref-smoke` |
| Keygrabber permanently unusable after reloading during a grab. | `keygrabber-after-restart` |
| Animation handles lose their metatable after a reload; `animation_setup()` is only called at boot. | `animation-metatable-after-restart` |
| Per-reload resource accumulation: the old state is leaked with GC stopped, and the lgi closure population roughly doubles per reload. | `double-restart` (census half) |
| statusnotifierwatcher leaks its name ownership, object registration and watches every reload. | `dbus-name-census-after-restart` |
| IPC event subscriptions go permanently silent after a reload. C keeps `client->subscribed` on the fd, but the subscriber registry is Lua module state destroyed with the state, and `ipc.broadcast` early-returns. The fd stays open and neither side reports an error. | `ipc-subscribe-across-restart` |

Known reload bugs with no test here are covered manually for now:

- EWMH updates stopping after a reload needs an XWayland client watching
  `_NET_*`.
- The stale pointer cluster in globalconf has no cheap outside-visible probe.
  `root.keys` is reassigned to a table by `lua/awful/root.lua`, so it does not
  report the C-side state, and the rest of the cluster (`primary_screen`,
  `drawable_under_mouse`, `mouse_under`, `pre_lock_focused_client`) needs pointer
  motion or a session lock. Verify it by hand when its reset lands.
- The rest (keybinding duplication, layer surfaces, selection listeners, the
  startup-error display, half-torn error paths) are traced but not cheaply
  reproducible from outside the process.
