# Cold Restart & Session Script

## Status: Implemented (branch `feat/cold-restart`)

## Problem

`awesome.restart()` crashes with SIGSEGV because `argv` is NULL after
`globalconf_init()` calls `memset(&globalconf, 0, ...)`. The original
AwesomeWM restart path (`execvp`) cannot work in a Wayland compositor
context anyway — the DRM session, Wayland clients, and GPU state cannot
survive an exec.

## Solution: dwm-style exit code + session script

Instead of trying to exec in-place, the compositor exits cleanly with a
specific exit code. A session wrapper script (`somewm-session`) interprets
the exit code and decides what to do next. The OS handles all resource
cleanup perfectly — no leaked file descriptors, no stale DRM locks, no
orphaned Wayland sockets.

This is **not a permanent architecture change** — it is a practical
interim approach (expected to last several months) that:
- Unifies how somewm is launched from TTY
- Provides reliable cold restart (kills all clients, restarts compositor)
- Enables a rebuild+restart dev workflow without sudo or system install
- Avoids the complexity of in-process hot restart

## Exit Code Convention

| Code | Meaning | Session script action |
|------|---------|----------------------|
| 0 | Normal quit (`awesome.quit()`) | Exit |
| 1 | Cold restart (`awesome.restart()` / `awesome.cold_restart()`) | Restart in 1s |
| 2 | Rebuild + restart (`awesome.rebuild_restart()`) | `ninja -C build` then restart |

## Changes

### C code

**`somewm.c`** — Two new functions after `cleanup()`:
- `cold_restart()` — sets `globalconf.exit_code = 1`, calls `some_compositor_quit()`
- `rebuild_restart()` — sets `globalconf.exit_code = 2`, calls `some_compositor_quit()`
- `main()` saves `exit_code` before `cleanup()` (which wipes globalconf) and returns it

**`luaa.c`** — Lua API additions:
- `awesome.restart()` now calls `cold_restart()` instead of crashing `execvp`
- `awesome.cold_restart()` — explicit alias for the same operation
- `awesome.rebuild_restart()` — triggers exit code 2
- `globalconf_init()` — saves argc/argv/log_level before memset (real bug fix)

### Lua code

**`somewmrc.lua`** — Menu and keybindings:
- Menu: "cold restart" and "rebuild & restart" items
- `Ctrl+Super+R` → cold restart

**`lua/awful/ipc.lua`** — IPC commands:
- `somewm-client restart` → cold restart (exit code 1)
- `somewm-client rebuild` → rebuild + restart (exit code 2)

### Build system

**`meson.build`** — Installs `somewm-session` to bindir

### Session script

**`somewm-session`** — Bash script installed to `/usr/local/bin/somewm-session`

Two modes:
- **Installed mode:** `somewm-session` — uses system `somewm` from PATH
- **Dev mode:** `SOMEWM_DIR=~/git/github/somewm somewm-session` — uses `build/somewm` with `-L ./lua`, no sudo needed

## Usage

### From TTY (production)
```bash
somewm-session
```

### From TTY (development, no install needed)
```bash
SOMEWM_DIR=~/git/github/somewm somewm-session
```

### Keybindings & IPC
```bash
# Ctrl+Super+R          → cold restart
# Menu → cold restart   → cold restart
# Menu → rebuild        → rebuild + restart

somewm-client restart   # cold restart via IPC
somewm-client rebuild   # rebuild + restart via IPC
```

## Testing

All three exit codes verified in nested compositor:

```
awesome.quit()           → exit code 0 (session script exits)
somewm-client restart    → exit code 1 (session script restarts)
somewm-client rebuild    → exit code 2 (session script builds + restarts)
```

## Commits

- `4f9d1e9` — feat: cold restart with exit codes and session script

## Related

- Branch: `feat/cold-restart`
- Fork: https://github.com/raven2cz/somewm/tree/feat/cold-restart
- Upstream issue: https://github.com/trip-zip/somewm/issues/232
