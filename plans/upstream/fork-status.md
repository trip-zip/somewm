# Fork Status: raven2cz/somewm vs trip-zip/somewm

Last sync with upstream: **2026-03-30** (8 commits: fullscreen fixes, systemd, shadow optimization)
Last fork-status update: **2026-03-30**

## What's in main

### Our unique features (not in upstream)

| # | Feature | Key files | Issue |
|---|---------|-----------|-------|
| 1 | NVIDIA crash guard — `xdg->initialized` check | `somewm.c` | [#216](https://github.com/trip-zip/somewm/issues/216) |
| 2 | Cold restart / session management | `somewm.c`, `luaa.c`, `somewm-session` | [#232](https://github.com/trip-zip/somewm/issues/232) |
| 3 | NumLock on startup (`awesome.set_numlock`) | `luaa.c` | [#238](https://github.com/trip-zip/somewm/issues/238) |
| 4 | Pointer constraint in Lua focus path | `somewm_api.c` | — |
| 5 | `[SOMEWM-DEBUG]` startup markers | `somewm.c` | — |
| 6 | Client animation framework (9 types) | `lua/awful/anim_client.lua` + C changes | [#381](https://github.com/trip-zip/somewm/issues/381) |
| 7 | SceneFX visual effects (optional) | 28 files, `scenefx_compat.h` | [#387](https://github.com/trip-zip/somewm/issues/387) |
| 8 | Layoutlist hotplug crash fix | `lua/awful/widget/layoutlist.lua` | [#390](https://github.com/trip-zip/somewm/issues/390), [PR #391](https://github.com/trip-zip/somewm/pull/391) |
| 9 | somewm-one config project | `plans/somewm-one/` | — |

### SceneFX integration (merged 2026-03-30)

Optional compile-time extension (`-Dscenefx=auto`). See [scenefx-integration.md](../scenefx-integration.md).
- Rounded corners (`c.corner_radius`)
- GPU shadows (dual-path: scenefx native or 9-slice fallback)
- Backdrop blur (`c.backdrop_blur`)
- Rounded border frame (single rect + clipped_region)
- Titlebar rounded corners
- Fade animation + decoration interaction

### Client animation framework (merged earlier)

9 animation types via `anim_client.lua`. See upstream issue [#381](https://github.com/trip-zip/somewm/issues/381).
Branch `feat/unified-animations` preserved for reference.

## Our contributions accepted upstream

16 commits cherry-picked (11 exact, 5 modified). Maintainer picked directly from our fork.

| Our fix | Upstream issue | Status |
|---------|---------------|--------|
| XWayland keyboard focus (Lua path) | #137, #135, #133 | Cherry-picked + improved |
| XWayland ICCCM focusable detection | #137 | Cherry-picked exact |
| awesome.exec() use-after-free | — | Cherry-picked exact |
| Titlebar geometry/clipping (4 commits) | #230 | Cherry-picked exact |
| XWayland position sync for popups | #231 | Cherry-picked exact |
| Minimized clients + tag switch | #217 | Cherry-picked exact |
| Selmon mouse motion update | #245 | Cherry-picked exact |
| XKB layout widget fix | #233 | Cherry-picked exact |
| Multi-monitor hotplug (6 bugs) | #216 | Cherry-picked modified |
| Keyboard focus desync (sloppy) | #237 | Cherry-picked modified |
| NumLock wibar scroll + UBSan | #239 | Cherry-picked modified |

## Open issues on upstream

| # | Title | Notes |
|---|-------|-------|
| [#387](https://github.com/trip-zip/somewm/issues/387) | SceneFX visual effects | Our issue, references feat/scenefx-integration branch |
| [#381](https://github.com/trip-zip/somewm/issues/381) | Client animation system | Our issue, references feat/unified-animations branch |
| [#390](https://github.com/trip-zip/somewm/issues/390) | Layoutlist assertion crash on hotplug | Our fix, [PR #391](https://github.com/trip-zip/somewm/pull/391) |
| [#249](https://github.com/trip-zip/somewm/issues/249) | Tag state lost on hotplug | Upstream has #312 (tag persistence) |
| [#232](https://github.com/trip-zip/somewm/issues/232) | awesome.restart() SIGSEGV | Our cold restart workaround active |
| [#193](https://github.com/trip-zip/somewm/issues/193) | Naughty stuck notifications | Upstream fixed break bug (#274) |

## Branch status

### Active (not in main, intentionally preserved)

| Branch | Purpose | Status |
|--------|---------|--------|
| `feat/scenefx-integration` | SceneFX visual effects PoC | **Merged to main 2026-03-30**. Branch preserved — referenced by upstream [#387](https://github.com/trip-zip/somewm/issues/387) |
| `feat/unified-animations` | Client animation system | **Merged to main earlier**. Branch preserved — referenced by upstream [#381](https://github.com/trip-zip/somewm/issues/381) |
| `backup/scenefx-integration` | Pre-squash backup (25 commits) | Safety backup, can be deleted after verification |

### Stale (already in main, can be deleted)

These branches were created before the upstream sync (2026-03-22) and their commits
are already in main under different hashes (cherry-picked or merged separately):

| Branch | Why stale |
|--------|-----------|
| `feat/cold-restart` | Commit `63ca2ed` = main's `bdc4fcb` |
| `fix/floating-layout-initial-size` | Commits `bbd1f97`, `b7ca0aa` = main's `9012e25`, `a28205e` |
| `fix/scroll-wibar-numlock` | Commit `3d063e0` = main's `8a664de` |
| `feat/numlock-on-startup` | Commit `eb33fa2` in main |
| `feat/output-added-connected` | Merged to main |
| `fix/hot-reload-lgi-crash` | Merged to main |
| `fix/keyboard-focus-desync` | Cherry-picked by upstream, in main via sync |
| `fix/minimized-clients-reappear-tag-switch` | Cherry-picked by upstream |
| `fix/multi-monitor-hotplug` | Cherry-picked by upstream |
| `fix/selmon-not-updated-on-mouse-motion` | Cherry-picked by upstream |
| `fix/shadow-resize-perf` | Merged to main |
| `fix/steam-menu-popup-positioning` | Cherry-picked by upstream |
| `fix/titlebar-geometry-clipping-and-pointer-focus` | Cherry-picked by upstream |
| `fix/xkb-keyboard-layout-switching` | Cherry-picked by upstream |
| `fix/xwayland-keyboard-focus` | Cherry-picked by upstream |
| `experiment/scenefx-poc` | Superseded by feat/scenefx-integration |
| `feature/native-screenrecord` | Merged to main |
| `sync/upstream-main` | Merge branch, completed |
| `fix/layoutlist-hotplug` | Merged to main |

### Upstream branches (Jimmy's, not ours)

| Branch | Commits | Notes |
|--------|---------|-------|
| `a11y_module` | 2 | WIP accessibility module |
| `feat/lockscreen` | 7 | Lock screen implementation |
| `feat/wallpaper_caching` | 1 | Wallpaper cache optimization |
| `fix/firefox-tiling-regression` | 1 | Stack refactor regression |
| `fix/shadow-beautiful-lookup` | 1 | Beautiful module require fix |
| `fix/silent_exit` | 1 | Error visibility improvement |

These are upstream WIP/fixes on our fork's remote. Do not merge — they belong in upstream PRs.

## Maintenance checklist

When syncing with upstream or merging branches:
1. Update this file with new branch status
2. Update "What's in main" section
3. Move merged branches to "Stale" section
4. Check if upstream adopted any of our commits
5. Update open issues status
