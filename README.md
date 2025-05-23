# SomeWM

SomeWM is a Wayland compositor based on wlroots that uses tinywl as a starting 
point to implement a lite version of AwesomeWM for Wayland. The goal is to 
recreate AwesomeWM's tiling window management and widget functionality in a 
Wayland compositor.

## Building SomeWM

SomeWM is disconnected from the main wlroots build system, in order to make it
easier to understand the build requirements for your own Wayland compositors.
Simply install the dependencies:

- wlroots
- wayland-protocols

And run `make`.

## Running SomeWM

You can run SomeWM with `./somewm`. In an existing Wayland or X11 session,
somewm will open a Wayland or X11 window respectively to act as a virtual
display. You can then open Wayland windows by setting `WAYLAND_DISPLAY` to the
value shown in the logs. You can also run `./somewm` from a TTY.

In either case, you will likely want to specify `-s [cmd]` to run a command at
startup, such as a terminal emulator. This will be necessary to start any new
programs from within the compositor, as SomeWM does not support any custom
keybindings. SomeWM supports the following keybindings:

- `Alt+Escape`: Terminate the compositor
- `Alt+F1`: Cycle between windows

## Limitations

Notable omissions from SomeWM:

- HiDPI support
- Any kind of configuration, e.g. output layout
- Any protocol other than xdg-shell (e.g. layer-shell, for
  panels/taskbars/etc; or Xwayland, for proxied X11 windows)
- Optional protocols, e.g. screen capture, primary selection, virtual
  keyboard, etc. Most of these are plug-and-play with wlroots, but they're
  omitted for brevity.
