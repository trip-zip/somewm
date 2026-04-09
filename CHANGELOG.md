# Changelog

All notable changes to somewm will be documented in this file.

## [2.0.0-dev] - Unreleased

### Added

### Fixed

### Changed

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
