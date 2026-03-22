# Fork Status: raven2cz/somewm vs trip-zip/somewm

Last sync: **2026-03-22** (see [sync-2026-03-22.md](sync-2026-03-22.md))

## What We Have That Upstream Doesn't

### 1. NVIDIA Crash Guard — `xdg->initialized` check
- **File:** `somewm.c`, `apply_geometry_to_wlroots()`
- **Commit:** `5a28e42`
- **Issue:** [#216](https://github.com/trip-zip/somewm/issues/216)
- **Why:** During output hotplug, `closemon() -> setmon() -> resize()` can reach `wlr_xdg_toplevel_set_size()` before the XDG surface completes its initial configure handshake. On NVIDIA DRM, the timing window is wider. Upstream doesn't test multi-monitor NVIDIA.
- **Test:** `tests/test-xdg-hotplug-crash.lua` (commit `ef91f47`)

### 2. Cold Restart / Session Management
- **Files:** `somewm.c`, `luaa.c`, `somewm-session` script
- **Commits:** `2d7e14d`, `bdc4fcb`
- **Issue:** [#232](https://github.com/trip-zip/somewm/issues/232)
- **Why:** `awesome.restart()` crashes with SIGSEGV upstream. Our workaround: exit with special codes (10=cold restart, 11=rebuild restart), `somewm-session` wrapper loop catches them.
- **Functions:** `cold_restart()`, `rebuild_restart()`, `luaA_cold_restart`, `luaA_rebuild_restart`

### 3. NumLock on Startup
- **File:** `luaa.c`
- **Commit:** `eb33fa2`
- **Issue:** [#238](https://github.com/trip-zip/somewm/issues/238)
- **Why:** No upstream API to toggle NumLock at startup. We added `awesome.set_numlock(true)`.

### 4. Pointer Constraint in Lua Focus Path
- **File:** `somewm_api.c`, end of `some_set_seat_keyboard_focus()`
- **Why:** Games (Steam, XWayland) need pointer constraint update when focus changes via Lua `client.focus = c`. Without this, focus-follows-mouse steals pointer from games. Upstream's popup-safe focus path doesn't call `some_update_pointer_constraint()`.

### 5. SOMEWM-DEBUG Startup Markers
- **File:** `somewm.c`, after `wlr_backend_start()`
- **Why:** `[SOMEWM-DEBUG]` markers at WLR_ERROR level always print, useful for confirming debug build launched correctly on NVIDIA.

### 6. Fork Documentation
- `plans/` directory — development plans, fix documentation, investigation notes
- `CLAUDE.md` — project guide for Claude Code sessions
- Session transcripts archive

## What Upstream Has That We Adopted

See [sync-2026-03-22.md](sync-2026-03-22.md) for full list. Key additions:

| Feature | PR |
|---|---|
| Carousel layout (niri-style) | #351 |
| Animated tiling transitions | #362 |
| Overflow wibox layout + scrollbar | #370 |
| Expanded IPC client | #338 |
| Lua lock/idle API + PAM | #201 |
| Output object API | #290 |
| Gesture module | #294 |
| Tag persistence across hotplug | #312 |
| 7 naughty notification fixes | #343-#347 |
| Shadow system rewrite (9-slice) | #205 |
| Screen disconnect_signal/emit_signal | #363, #365 |
| `updatemons_pending` reentrancy | #323 |
| Suspended state sync on unminimize | #332 |

## Our Contributions Accepted Upstream

16 commits cherry-picked (11 exact, 5 modified). **No PRs submitted** — maintainer picked directly from our fork branches.

| Our Fix | Upstream Issue | Status |
|---|---|---|
| XWayland keyboard focus (Lua path) | #137, #135, #133 | Cherry-picked + improved (3 iterations) |
| XWayland ICCCM focusable detection | #137 | Cherry-picked exact |
| awesome.exec() use-after-free | — | Cherry-picked exact |
| Titlebar geometry/clipping (4 commits) | #230 | Cherry-picked exact |
| XWayland position sync for popups | #231 | Cherry-picked exact |
| Minimized clients + tag switch | #217 | Cherry-picked exact + extended (#332) |
| Selmon mouse motion update | #245 | Cherry-picked exact |
| XKB layout widget fix | #233 | Cherry-picked exact |
| Multi-monitor hotplug (6 bugs) | #216 | Cherry-picked modified + extended (#323) |
| Keyboard focus desync (sloppy) | #237 | Cherry-picked modified |
| NumLock wibar scroll + UBSan | #239 | Cherry-picked modified |

## Open Issues on Upstream

| # | Title | Notes |
|---|---|---|
| [#249](https://github.com/trip-zip/somewm/issues/249) | Tag state lost on hotplug | Upstream now has #312 (tag persistence) — may partially address |
| [#232](https://github.com/trip-zip/somewm/issues/232) | awesome.restart() SIGSEGV | Our cold restart workaround active |
| [#193](https://github.com/trip-zip/somewm/issues/193) | Naughty stuck notifications | Upstream fixed `break` bug (#274), monitoring |

## Fork Branches (on origin)

Active:
- `main` — synced with upstream 2026-03-22
- `sync/upstream-main` — merge branch (to be merged to main)
- `fix/multi-monitor-hotplug` — preserved for reference

Historical (cherry-picked upstream):
- `fix/xwayland-keyboard-focus`
- `fix/titlebar-geometry-clipping-and-pointer-focus`
- `fix/steam-menu-popup-positioning`
- `fix/selmon-not-updated-on-mouse-motion`
- `fix/scroll-wibar-numlock`
- `fix/minimized-clients-reappear-tag-switch`
- `fix/keyboard-focus-desync`
- `fix/xkb-keyboard-layout-switching`
- `feat/cold-restart`
- `feat/numlock-on-startup`
