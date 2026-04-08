## SomeWM 1.4.0 - Hot-reload, new layouts, and the AwesomeWM compatibility finish line

I've been pretty busy working on getting as much full AwesomeWM compat as reasonably possible in SomeWM.  The final piece, getting hot-reloading working in Wayland, is merged and working fairly well.  
With that last major blocker out of the way, I'm ready to announce a release of 1.4.0

### Versioning

First major release being 1.4.0 is weird, I know, but here's my reasoning

SomeWM 1.4 will attempt to follow AwesomeWM 4.4 (current master branch) indefinitely for all non-x11 specific features/bug fixes.
When 4.4 is merged and awesome starts active dev on 4.5, 1.4 will be frozen on 4.4, 1.5 will follow the 4.5 master branch.

2.x will start to make core C/Lua architectural changes and get more of its own identity.  Public Lua API will mostly remain the same.


### What's new since 0.3.0

- Animated tiling transitions
- Lock/idle screen with PAM authentication, no external locker needed
- IPC client overhaul (somewm-client went from a handful of commands to ~45, with event subscription and shell completions)
- First-class output objects- persistent monitor objects with full Lua API (scale, transform, mode, position, adaptive sync)
- Layer surface rules
- Fractional output scaling with wp_fractional_scale_v1
- Tag persistence across monitor hotplug
- Pointer gestures via wlroots
- Overflow layout with scrollbar support
- Carousel tag layout
- Systemd service units
- Improved Nix flake support
- Build system migrated to meson with bundled wlroots 0.19

Stability:

- 6 naughty/notification fixes (slowly but surely I'm trying to add these to Awesome upstream to help close the gap on the 4.4 milestone)
- XWayland got way more solid (dialogs, focus, popups, close-to-tray, Discord no longer turns your laptop into a portable space heater)
- Libinput settings from Lua, XKB multi-layout, NumLock, AltGr
- Multi-monitor hotplug reliability
- A ton of crash fixes and use-after-free fixes caught by running ASAN as my daily driver

AwesomeWM compatibility:

- 15 upstream PRs pulled into main
- Lua 5.1 through 5.4 and LuaJIT all supported much more comprehensively than my last post

### Why I'm cutting this release now:

a) It's stable, reliable, and there are vanishingly few AwesomeWM features not supported (if any).  Pulling commits from upstream is trivial now, so following Awesome is an achievable goal indefinitely now.

b) I keep getting tempted to go off-script. Carousel, animations, ideas about event queues and layout engines...none of that belongs in a release whose promise is "your AwesomeWM rc.lua just works on Wayland."
Every time I add a somewm-original feature to the compatibility branch, I'm straddling two goals.

1.4 draws the line. This is the AwesomeWM compatibility milestone. It'll get bug fixes and upstream ports on release/1.4 for as long as people use it.  Any issues that don't match Awesome, those get priority.  New features are at a hard stop there.

2.0 will be a structural release that untangles the inherited C/Lua architecture - instead of signals firing Lua at arbitrary points in the frame, Lua will declare intent at well-defined sync points while C handles layout, rendering, and event processing. Your rc.lua keeps working; what changes is everything underneath it.
