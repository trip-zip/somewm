# somewm - AwesomeWM for Wayland

**somewm** is a Wayland compositor that brings AwesomeWM's Lua API to Wayland, built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots). The goal is 100% compatibility with AwesomeWM's Lua configuration, so you can use your existing `rc.lua` with minimal changes.

## Why?
- The very very short version is that I'm sad to see highly active, creative, and highly talented members of the AwesomeWM community start to leave for wayland compositors.  I love what they have added to the community by way of their incredible libraries, rices, configs, and answers in discord.  I don't want lack of wayland implementation to be the reason anyone else leaves.  There isn't a better WM than Awesome, I'll die on that hill.  If we had a fully AwesomeWM compatible wayland option, maybe those members of the community would still be pushing the envelope with widgets, rices, etc.

## Features

- AwesomeWM Lua API compatibility (awful.*, gears.*, wibox.*, etc.)
- Uses AwesomeWM's Lua libraries directly - no reimplementation
- Native Wayland (wlroots 0.19)
- XWayland support for legacy X11 applications
- *Existing AwesomeWM configs work out-of-box (Close, not quite there yet, but close.)

## Status

- somewm is in early development, though highly functional today. 
- The default AwesomeWM themes and configurations load and are nearly completely functional.
- The goal for 1.0.0 is complete AwesomeWM compatibility - your existing `rc.lua` should work seamlessly and with exactly the same behaviors as Awesome, quirks and all.
- (Of course, x11 architecture things that have no wayland comparison are excluded from this goal)
- My loftiest goals would be to get to a stable version where I have 100% current awesomewm functionality and keep all new awesomewm features up to date in an awesome_4.x compat branch, whereas the main somewm releases would take advantage of not needing certain backwards compat or deprecated features.  Maybe fully embrace some of what wayland offers us. we'll see.

## Limitations/Deficiencies
### Known limitations:

- This was written by 1 very stupid dev who, over the course of 3 years, about 10 false starts, attempts in zig and odin, finally hacked together something that "works"" only in the loosest definition of the word only by cobbling together wlroots calls that someone smarter built, whereas the AwesomeWM maintainers are incredible, experienced, and in the case of implementing XCB, actual pioneers in the WM space...

### Not Implemented

- Systray (system tray) - No support for status icons (nm-applet, etc.). Needs StatusNotifierItem/D-Bus implementation for Wayland.  I have lofty goals for the systray.  I want it to be much more customizable than the awesomewm version.
- root.fake_input() - Virtual keyboard/mouse input injection (used for automation/testing)
- X Property APIs - awesome.register_xproperty(), awesome.set_xproperty(), awesome.get_xproperty() all error out
- root._remove_key() - Cannot dynamically remove keybindings at runtime
- root.cursor() - Cursor theme changing is a no-op
### Partially Implemented

- Strut aggregation - Only works with single panel/wibar per screen, multiple panels don't correctly reserve space
- Keyboard layout detection - awesome.xkb_get_group_names() returns hardcoded "English (US)" instead of actual layouts
- EWMH client list updates - XWayland pagers/taskbars may not see correct window lists
- Scroll wheel mouse bindings - Not yet supported in root/client button bindings
- root.drawins() - Cannot enumerate all drawin objects
- Button press/release signal callbacks - Partial implementation on clients

### Reimplemented Differently (Wayland-Safe Stubs)

- beautiful.gtk - AwesomeWM queries GTK theme colors by instantiating GTK windows via LGI (doesn't work on Wayland). SomeWM's version reads from ~/.config/gtk-3.0/settings.ini and gsettings instead, with Adwaita defaults as fallback.

### Stubs (Accept Calls but Do Nothing)
- awesome.register_xproperty() - No-op (no X properties in Wayland)
- Signal disconnection on screens - No-op stub
- Icon pixmap handling (non-EWMH icons)

## Requirements

### Runtime Dependencies
- wlroots 0.19
- LuaJIT (recommended) or Lua 5.1-5.4
- LGI (Lua GObject Introspection bindings) - for wibox/widget rendering
- cairo, pango, gdk-pixbuf
- glib-2.0

### Build Dependencies
- C compiler (gcc or clang)
- wayland-protocols
- libinput
- xkbcommon
- pkg-config

### Optional (for XWayland)
- libxcb, libxcb-icccm
- Xwayland

## Building from Source

### Arch Linux

```bash
# Install dependencies
sudo pacman -S wlroots luajit lua-lgi cairo pango gdk-pixbuf2 \
    wayland-protocols libinput libxkbcommon

# Optional: XWayland support
sudo pacman -S xorg-xwayland libxcb

# Build
git clone https://github.com/trip-zip/somewm
cd somewm
make
```

### Debian/Ubuntu

**Note:** wlroots 0.19 is only available in Debian unstable (sid) and Ubuntu 25.04+. If you're on Debian stable or Ubuntu 24.04 LTS, you'll need to [build wlroots 0.19 from source](https://gitlab.freedesktop.org/wlroots/wlroots) first.  That's my bad, I didn't think of that until just now.  I'll look at the lift it would be to use wlroots.0.18 instead.

```bash
# Install dependencies
sudo apt install libwlroots-dev luajit lua-lgi libcairo2-dev \
    libpango1.0-dev libgdk-pixbuf-2.0-dev \
    wayland-protocols libinput-dev libxkbcommon-dev

# Optional: XWayland support
sudo apt install xwayland libxcb1-dev libxcb-icccm4-dev

# Build
git clone https://github.com/trip-zip/somewm
cd somewm
make
```

### Fedora

```bash
# Install dependencies
sudo dnf install wlroots-devel luajit lua-lgi cairo-devel pango-devel \
    gdk-pixbuf2-devel wayland-protocols-devel libinput-devel \
    libxkbcommon-devel

# Optional: XWayland support
sudo dnf install xorg-x11-server-Xwayland libxcb-devel xcb-util-wm-devel

# Build
git clone https://github.com/trip-zip/somewm
cd somewm
make
```

### Installation

```bash
# System-wide installation
sudo make install

# User-local installation (no root required)
make install-local

# Add session to display manager (SDDM, GDM, etc.)
sudo make install-session
```

Note: Most display managers only look for session files in `/usr/share/wayland-sessions/`. The `install-session` target copies the desktop file there so somewm appears in your login screen's session list.

## Running

```bash
# Start somewm
somewm

# Start with a command (e.g., terminal)
somewm -s 'alacritty'
```

## Configuration

somewm uses the same configuration format as AwesomeWM.

**Config locations (checked in order):**
1. `~/.config/somewm/rc.lua`
2. `~/.config/awesome/rc.lua`

If you already have an AwesomeWM config at `~/.config/awesome/rc.lua`, somewm will use it automatically - no need to copy anything.

If no config is found, somewm uses the built-in default theme, same as awesomewm.

## Known Limitations

- Some AwesomeWM APIs are stubbed or incomplete
- DBus integration is partial
- Some widget features may not render correctly yet
- WM Restarting.  Wayland doesn't have the same architecture as x11, therefore restarting the wm against a running server is out of the question.  Restarting will take some serious thought...though it's on my roadmap

## Acknowledgements

somewm wouldn't exist without:
- [AwesomeWM](https://github.com/awesomeWM/awesome) - Almost seems redundant to even include AwesomeWM here.  They're way more than an ackknowledgement...they are the legends.
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) - The Wayland compositor library
- dwl - Initial scaffolding and reference.  Couldn't have done this without dwl

## License

GPLv3. See [LICENSE](LICENSE) and [licenses/](licenses/) for details.
