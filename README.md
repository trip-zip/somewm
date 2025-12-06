# somewm - AwesomeWM for Wayland

**somewm** is a Wayland compositor that brings AwesomeWM's Lua API to Wayland, built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots).

## Disclaimer:
- I am NOWHERE near the level of developer that the team at AwesomeWM are.  I do not wish to overpromise ANY part of this compositor.  I learned C in the middle of trying to implement this, whereas the AwesomeWM team has been writing high quality C code before I even stated my dev career.
- Hence the name "someWM".  It's not AwesomeWM, merely "some" of what awesome is.

## Status & Plans

- **0.1.0** - Early development.  The default rc.lua files for the default awesomeWM themes all load and are mostly functional
- I want 1.0.0 to be 100% awesomewm lua library compatibility, meaning with some known exceptions, anyone should be able to bring their rc.lua config from awesomewm into somewm and have it work seamlessly.

## Building

Dependencies:
- wlroots 0.19
- wayland / wayland-protocols
- libinput
- xkbcommon
- lua 5.1 or luajit
- cairo and pango

Optional (XWayland):
- libxcb / libxcb-icccm
- Xwayland

```bash
make              # Build
./somewm          # Run
./somewm -s 'cmd' # Run with startup command
```


## Acknowledgements

somewm wouldn't exist without:
- [AwesomeWM](https://github.com/awesomeWM/awesome) - The Lua API and libraries we're porting
- dwl - Although I'm not using that code any longer here, it was a super useful "scaffolding." I started this project by copying the AwesomeWM lua libraries into dwl, then replacing dwl code with an approximation of AwesomeWM C code until all that's left is my poor attempt at AwesomeWM's C compatibility
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) - The Wayland compositor library

## License

GPLv3. See [LICENSE](LICENSE) and [licenses/](licenses/) for details.
