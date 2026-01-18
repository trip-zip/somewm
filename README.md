# somewm - AwesomeWM for Wayland

**somewm** is a Wayland compositor that brings AwesomeWM's Lua API to Wayland, built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots). The goal is 100% compatibility with AwesomeWM's Lua configuration.

<p align="center">
  <img src="screenshots/default.png" alt="Default configuration" width="45%">
  <img src="screenshots/styled.png" alt="Styled configuration" width="45%">
</p>
<p align="center">
  <em>Default config (left) and a styled config (right)</em>
</p>

## Install

**Arch Linux (AUR):**
```bash
yay -S somewm-git
```

**From source:**
```bash
git clone https://github.com/trip-zip/somewm
cd somewm
make
sudo make install
```

For Debian, Fedora, NixOS, and detailed instructions, see the [Installation Guide](https://somewm.org/getting-started/installation).

## Run

From your display manager, select "somewm" as your session.

Or from a TTY:
```bash
dbus-run-session somewm
```

See [First Launch](https://somewm.org/getting-started/first-launch) for configuration and migrating from AwesomeWM.

## Status

Most AwesomeWM functionality works. Your existing `rc.lua` should work with minimal changes.

| Works | Coming Soon |
|-------|-------------|
| Tiling layouts | Systray (XEmbed) |
| Widgets & wibar | `root.fake_input()` |
| Client management | Scroll bindings on root |
| Multi-monitor | |
| XWayland | |
| Notifications | |

See [Current Limitations](https://somewm.org/troubleshooting#current-limitations) for the full list.

## Documentation

Full documentation at **[somewm.org](https://somewm.org)**:

- [Getting Started](https://somewm.org/getting-started/installation) - Installation, first launch, migration
- [Tutorials](https://somewm.org/tutorials/basics) - Keybindings, widgets, themes
- [Troubleshooting](https://somewm.org/troubleshooting) - Common issues and solutions

## Contributing

Contributions welcome! See [GitHub Issues](https://github.com/trip-zip/somewm/issues) for current work.

- Report bugs or request features via [Issues](https://github.com/trip-zip/somewm/issues)
- Questions and discussion at [Discussions](https://github.com/trip-zip/somewm/discussions)

## Acknowledgements

- [AwesomeWM](https://github.com/awesomeWM/awesome) - The GOAT window manager
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) - The Wayland compositor library
- [dwl](https://codeberg.org/dwl/dwl) - Initial reference for wlroots integration

## License

GPLv3. See [LICENSE](LICENSE) for details.
