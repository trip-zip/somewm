# Changelog

All notable changes to somewm will be documented in this file.

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

## [0.4.0] - 2025-12-28

### Added
- Dynamic keybinding removal (#15)
- Scroll wheel support in mousebinds (#16)
- Complete button press/release signals on clients (#17)
- Cursor theme changing via `root.cursor()` (#18)

### Notes
- XKB layout switching moved to 0.5.0 (Wayland limitation with documented workaround)

## [0.3.0] - 2025-12-21

Initial public release with core AwesomeWM compatibility.

[Unreleased]: https://github.com/trip-zip/somewm/compare/0.5.0...HEAD
[0.5.0]: https://github.com/trip-zip/somewm/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/trip-zip/somewm/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/trip-zip/somewm/releases/tag/0.3.0
