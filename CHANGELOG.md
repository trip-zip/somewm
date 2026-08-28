# Changelog

All notable changes to somewm will be documented in this file.

## [2.0.0] - 2026-08-28

Major release. 202 commits since 1.4.0. The Lua/C boundary is reworked: C
events are queued and delivered to Lua at a defined point, instead of Lua
running in the middle of C event handling. The deprecated API surface
accumulated through the 1.4 line is removed. Fixes already released in 1.4.1
through 1.4.4 are included but not re-listed here.

### Removed

Every removal is listed with its replacement in
[`DEVIATIONS.md`](DEVIATIONS.md) under "Removed APIs".

- `awesome.api_level` and the machinery behind it. Nothing selects a
  compatibility level anymore; the library behaviors that branched on it are
  fixed at what level 4 did, and `gears.debug.deprecate` is a plain warning
- `gears.wallpaper` and its cache. Use `awful.wallpaper`
- `awful.util`, whole module. Its functions have lived in `gears.*` and
  `awful.*` since AwesomeWM 4.0
- `naughty.notify()` and the other deprecated `naughty.core` functions. Use
  `naughty.notification`
- The deprecated redirect shims and the deprecated functions in `awful.tag`
  and `awful.client`
- The `manage`/`unmanage` client signals. Connecting to them warns and does
  nothing; use `request::manage`/`request::unmanage`
- The legacy `_key` module, the `add_signal` no-ops, and the `.data` alias

### Changed

- C-to-Lua signals go through an event queue. Geometry, focus, mouse,
  lifecycle, and `request::` signals are queued in C and delivered together at
  a defined point in the frame; pointer motion coalesces to one event per
  delivery
- The default config (`somewmrc.lua`) is rewritten around somewm's own
  features instead of mirroring AwesomeWM's rc.lua. The AwesomeWM-style config
  remains supported; only the shipped default changed
- somewm.c is split into focused modules (input, window, monitor, protocols,
  focus, xwayland). No behavior change

### Added

- Client-side maximize and minimize buttons (GTK header bars) drive the same
  client state as titlebar buttons and keybindings
- Laptop lid and keypad-slide switches emit Lua signals
- Carousel layout: dynamic peek (`beautiful.carousel_dynamic_peek`), layout
  state introspection via `carousel.get()`, vertical `push_window`, and
  per-client column width via the `carousel_column_width` rule property
- 256x256 client icons

### Fixed

- Notification D-Bus method calls always get a reply, so applications that
  block on the reply no longer hang or time out
- XDG toplevels are activated before keyboard enter, fixing focus for clients
  that wait for activation
- Shape masks are read in whichever pixel format they arrive in
- The Lua tree parses under every supported Lua again (5.1 through 5.5,
  LuaJIT), checked by `make test-unit`

### Notes

- 2.0 is its own line and no longer tracks AwesomeWM releases. The public
  `rc.lua` API is preserved by default; deviations are documented in
  [`DEVIATIONS.md`](DEVIATIONS.md)
- `screen.fake_add` creates a screen object, but fake screens are not
  functional: clients moved to one are hidden and bars cannot attach to it
  (#561). This is gated on the 2.2 layout work

## [1.4.4] - 2026-08-20

Patch release. 10 commits since 1.4.3: client popups, input routing, and idle
inhibitors. No API changes; existing rc.lua configs run unchanged.

### Fixed

- Client popup menus open where the application asked, instead of offset up and
  left by the border width and titlebar height, and no longer get cropped at the
  client's content edge. Context menus routinely open above and left of the
  pointer, so this was visible in Firefox and anything else with a context menu
- Popups paint above client borders and shadows instead of behind them
- X11 clients keep the pointer grab when you click the window that already has
  focus, so games no longer lose mouse capture on every click
- Scroll ticks reach the mousegrabber as buttons 4/5, as they do in AwesomeWM.
  BTN_SIDE and BTN_EXTRA no longer land in those slots; they are buttons 8/9
- Clicking a wibar no longer fires the root button binding on top of whatever
  the wibar did with the click
- Pointer focus unpins on the seat's button count instead of a local latch, so a
  release swallowed by a mousegrabber no longer pins focus to a stale surface
- Destroying an idle inhibitor recomputes after wlroots unlinks it, so idle
  timers are no longer latched off for the rest of the session
- Systray icons size by the theme's `base_size` rather than the source pixmap,
  so an app publishing a 256x256 icon no longer takes a 256px wide slot with the
  icon letterboxed inside it
- Tag names that are empty or unset no longer read through a null pointer

## [1.4.3] - 2026-08-08

Patch release. 25 commits since 1.4.2: a hot-reload rework, wlroots 0.20
support, and border geometry fixes. One property removed to match upstream
AwesomeWM; existing rc.lua configs otherwise run unchanged.

### Added

- wlroots 0.20 support, alongside 0.19. The build picks whichever version the
  system provides; `-Dwlroots_version` forces the choice. Restores the build
  on Debian 13 and Ubuntu 24.04 (#579)
- Restart test suite: assertions on both sides of a real `awesome.restart()`,
  driven from outside through `somewm-client test`
- `make check-qa` runs luacheck, mirroring upstream AwesomeWM

### Fixed

- Hot-reload closes the old Lua state instead of leaking it, ending the
  ~90 MB RSS growth per `awesome.restart()` (#574)
- Hot-reload no longer crashes in lgi after reload: lgi's C libraries are
  pinned across the state close (#465)
- naughty and the status notifier watcher release their D-Bus names and
  registrations on exit, so notifications and the systray survive reloads
- Both rebuild paths reset C-held Lua state, including the config-timeout
  recovery path
- Border width no longer inflates client size: geometry is border-exclusive
  as in AwesomeWM, fixing titlebar positioning, shadow sizing, clipping, and
  `c.content` capture offsets
- Destroying the focused client emits `unfocus` and `property::active`,
  matching AwesomeWM
- Timers armed during the refresh cycle wake the poll, so an idle session no
  longer sleeps past a due `gears.timer`
- The seat advertises pointer and keyboard capabilities at startup, not only
  after the first input device appears
- `print()` from rc.lua reaches redirected logs (stdout is line-buffered)
- awful.ipc parses under Lua 5.5 (loop variables are read-only there)
- tasklist and drawable no longer swallow widget errors; undefined-variable
  bugs fixed in ipc, systray tooltips, and focus_tracker
- `clickfinger_button_map` initialized (touchpad clickfinger crash)

### Removed

- `client_shape_input` property and `awful.client.shape.update.input`,
  matching upstream AwesomeWM's revert of the feature (#4100). The drawin
  `shape_input` property is unaffected.

### Notes

- AwesomeWM baseline unchanged from 1.4.0, plus ported upstream fixes #4100
  and #3998.
- See [`DEVIATIONS.md`](DEVIATIONS.md) for Wayland vs X11 differences.

## [1.4.2] - 2026-06-22

Patch release. 43 commits since 1.4.1: mostly bug fixes, plus a few additive
features. No public API breaks; existing rc.lua configs run unchanged.

### Added

- `somewm::ready` and `xwayland::ready` signals, also exposed as `awesome.*`
  properties and re-emitted on hot-reload
- `-c NONE` to start without loading any user config
- XKB keyboard model and rules selection
- `screenshot` interactive (snipping) subcommand in the somewm-client CLI

### Fixed

- Compositor terminates cleanly on SIGTERM/SIGINT and Ctrl-Alt-Backspace
- Timer-driven widget redraws now present on an otherwise idle session (clocks update)
- Client buffer flush deferred out of the map signal emit (disconnect-mid-map crash)
- Titlebar hover no longer leaks pointer events to the client beneath it
- Aerosnap placeholder deferred by dwell, removing cross-monitor flicker
- `request::tag` nil-guard restored for `transient_for.screen`
- `createmon()` bails cleanly when an output commit fails (partial hotplug)
- Per-client geometry signals emitted on the xdg fullscreen path
- Hot-reload assigns all client screens before emitting restore signals
- Drawin struts aggregated per explicit screen pointer (multi-monitor)
- `c.content` captured via scene-tree walk and scaled to logical size on HiDPI
- Screenshot snipping overlay rendered at logical resolution

### Changed

- Default build is optimized release with no sanitizers (packaging-relevant)
- Build supports Lua 5.5; added a `lua_pkg` override
- Cleaned `-Werror` failures under GCC 15/16; stopped propagating `-Werror`
  into the wlroots, v4l-utils, and libdisplay-info subprojects

### Notes

- AwesomeWM baseline unchanged from 1.4.0.
- See [`DEVIATIONS.md`](DEVIATIONS.md) for Wayland vs X11 differences.

## [1.4.1] - 2026-04-24

Patch release. 19 commits since 1.4.0, all bug fixes and one additive
signal change. No public API breaks; existing rc.lua configs run unchanged.

### Fixed

- Use-after-free of `wlr_scene_tree` via `wlr_surface->data`
- SEGV on monitor unplug from missing surface cleanup (#442)
- `createmon()` hardening for partial monitor init failures (#477)
- Carousel: clients render across monitors when outside the carousel layout
- Borders stay visible when a client is partially offscreen
- Pointer enter delivered to newly mapped layer-shell surfaces
- Pointer focus re-evaluated after the banning refresh
- `LyrOverlay` placement preserved for override-redirect clients (XWayland stacking)
- wibox: opacity and border properties propagate to the underlying C drawin
- wibox: A1 surface format restored for shape masks
- Idle-inhibit exclude mechanism honored again (#446)
- Icon resolution falls back to `.desktop` entries when class isn't a theme icon
- Keygrabber stops key repeat when starting mid-press
- Keyboard layout `next_layout()` off-by-one in wrap-around
- README links point at the 1.4 docs site

### Changed

- The `exit` signal now carries a `restart` boolean argument: `true` on
  hot-reload, `false` on shutdown. Matches AwesomeWM behavior. Existing
  handlers that ignore arguments are unaffected.

### Notes

- AwesomeWM baseline unchanged from 1.4.0.
- See [`DEVIATIONS.md`](DEVIATIONS.md) for Wayland vs X11 differences.

## [1.4.0] - 2026-04-07

First stable release. SomeWM 1.4 = AwesomeWM 4.4 on Wayland.

### Added

- In-process Lua hot-reload for `awesome.restart()` - tears down and rebuilds the Lua VM while Wayland clients survive (#366)
- Carousel layout - niri-style scrollable tiling with per-column focus (#351)
- Animated tiling transitions with configurable easing and duration (#362)
- Lock screen with PAM authentication (#201)
- IPC client (`somewm-client`) with ~45 commands, event subscription, and shell completions (#338)
- First-class `output` object for Wayland monitor management (#290)
- Tag persistence across monitor hotplug (#312)
- Overflow layout with scrollbar support (#370)
- Per-device input rules via `awful.input.rules`
- Lua-settable idle inhibition via `awesome.idle_inhibit`
- Gesture module (`awful.gesture`) with wlr_pointer_gestures_v1 support
- Layer surface Lua API for layer-shell surfaces
- Screen fractional scaling via `screen.scale`
- Level-aware logging with `--verbose` flag (#191)
- Improved `--check` mode with suppression, severity filter, and GTK detection
- Systemd service units and session wrapper for distro packagers
- XDG desktop portal file for xdg-desktop-portal-wlr screen sharing
- Wallpaper caching for instant tag switching
- Libinput touchpad/trackpoint configuration
- Client aspect ratio constraints for resize
- `awesome.startup` property (#253)
- Runtime cursor theme and size configuration

### Fixed

- XWayland dialogs now float correctly via `_NET_WM_WINDOW_TYPE` (#337, #364)
- `screen:disconnect_signal()` implemented (#363)
- `root._remove_key()` implemented for dynamic keybinding removal (#405)
- EWMH `_NET_CLIENT_LIST_STACKING` updates enabled in stack operations (#406)
- Keygrabber release events now fire with `"release"` event type (#409)
- Crash when closing foot near XWayland clients (#386)
- Browser tab drag to wibar area (#318)
- Shadow geometry resize performance - excessive damage eliminated (#373)
- 6 naughty notification fixes: icon resolution (#343), ActionInvoked on dismiss (#344), timeout with `ruled.notification` (#345), GC ghost notifications (#346), `beautiful.notification_*` properties (#347), stuck notifications (#193)
- Hot-reload stability: Lgi FFI closure guard, GDBus singleton bypass, systray snapshot/restore, tiled client order preservation, stale titlebar/drawin cleanup
- Multi-monitor hotplug lifecycle (6 bugs including screen add ordering, layoutlist crash, scale reentrancy)
- Fullscreen clients now render above wibars (#368, #317)
- Client resize performance regression from shape updates (#359)
- Minimized clients no longer reappear after switching tags (#217)
- Lock screen covers all screens and survives hotplug (#353, #357)
- XWayland position sync for popup menu placement (#320)
- Firefox saved-geometry regression on map (#321)
- XWayland keyboard focus delivery in Lua focus path
- Various SEGV and use-after-free fixes in screen, spawn, drawin, and client lifecycle
- XKB multi-layout keyboard switching and widget display
- Pointer focus over titlebars, borders, and on client map
- Drag motion events delivered to drag source client
- Snap preview crash from format mismatch

### Changed

- 26-file AwesomeWM symbol alignment refactor for code-level parity
- 17 upstream AwesomeWM PRs ported (see `UPSTREAM_PORTS.md`)
- Dead xproperty stub functions and unused button matching code removed
- `selection()` crash converted to deprecation warning (use `selection.getter{}`)
- Build: strict GCC warnings enabled, LuaJIT preferred in auto-detection

### Notes

- AwesomeWM baseline: [`fa805ab4`](https://github.com/awesomeWM/awesome/commit/fa805ab465821c54094126b71a92acf2eba17674) (latest port: 2026-04-01)
- See [`DEVIATIONS.md`](DEVIATIONS.md) for all known Wayland vs X11 differences
- See [`UPSTREAM_PORTS.md`](UPSTREAM_PORTS.md) for ported AwesomeWM PRs

## [0.5.0] - 2026-01-02

### Breaking Changes

- **Build system migrated to meson** (https://github.com/trip-zip/somewm/discussions/117):
  - Now requires `meson` and `ninja` to build
  - wlroots 0.19 is bundled and built automatically (system wlroots 0.19 used if available)
  - `config.mk` removed - use `meson configure build` to change options
  - Old make targets removed: `install-local`, `install-session`, `uninstall-local`, `uninstall-session`
  - Build commands unchanged: `make` and `sudo make install` still work

- **CLI flags changed for AwesomeWM compatibility** (#4):
  - `-c` now specifies config file (was `-C`)
  - `-k` now runs config check (was `-c`)
  - If you were using `-C /path/to/config`, change to `-c /path/to/config`
  - If you were using `-c /path/to/config` for checking, change to `-k /path/to/config`

### Added

- ASAN/UBSAN build support via `make asan` for debugging memory issues
- Runtime cursor theme and size changing via `root.cursor_theme()` and `root.cursor_size()` (#177)
- Startup now respects `XCURSOR_THEME` and `XCURSOR_SIZE` environment variables (#177)

## [0.4.0] - 2025-12-28

### Added
- Dynamic keybinding removal (#15)
- Scroll wheel support in mousebinds (#16)
- Complete button press/release signals on clients (#17)
- Cursor shape changing via `root.cursor()` (#18)

### Notes
- XKB layout switching moved to 0.5.0 (Wayland limitation with documented workaround)

## [0.3.0] - 2025-12-21

Initial public release with core AwesomeWM compatibility.

[Unreleased]: https://github.com/trip-zip/somewm/compare/1.4.0...HEAD
[1.4.0]: https://github.com/trip-zip/somewm/compare/0.5.0...1.4.0
[0.5.0]: https://github.com/trip-zip/somewm/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/trip-zip/somewm/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/trip-zip/somewm/releases/tag/0.3.0
