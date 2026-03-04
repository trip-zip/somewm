# SomeWM Deviations from AwesomeWM

This document tracks all known differences between somewm and AwesomeWM. These exist primarily due to fundamental differences between X11 and Wayland protocols.

## Architectural Differences (Wayland vs X11)

| Feature | AwesomeWM (X11) | SomeWM (Wayland) | Reason |
|---------|-----------------|------------------|--------|
| Systray | X11 `_NET_SYSTEMTRAY` embed | StatusNotifierItem D-Bus (SNI) | X11 tray protocol doesn't exist on Wayland |
| Titlebar borders | Outside frame (X server draws) | Inset by `border_width` | Scene graph positioning differs |
| Window visibility | `xcb_map_window()` shows immediately | Content must exist before showing | Prevents smearing artifacts |
| WM restart | `awesome.restart()` works | Not supported | Wayland compositor can't restart in place |
| GTK theme detection | Creates GTK widgets, queries `GtkStyleContext` | Parses `gtk-3.0/settings.ini` and `gtk-4.0/settings.ini` | Creating GTK windows inside a compositor is unsafe |
| Xresources | Queries `xrdb` server | Parses `~/.Xresources` file directly | No `xrdb` server on Wayland |
| Wibox shape surfaces | 1-bit (`cairo.Format.A1`) | Full ARGB32 with anti-aliasing | Enables anti-aliased rounded corners and HiDPI scaling |
| Config/cache paths | `~/.config/awesome/`, `~/.cache/awesome/` | `~/.config/somewm/`, `~/.cache/somewm/` | Rebranded |

### Detailed Explanations

**Systray (SNI vs X11 embed)**
- AwesomeWM uses X11's `_NET_SYSTEMTRAY` protocol to embed tray icon windows
- SomeWM uses the modern StatusNotifierItem D-Bus protocol
- Most apps (NetworkManager, Discord, Bluetooth) support SNI already
- Legacy XEmbed-only apps won't show tray icons

**Titlebar Border Positioning**
- In X11, borders are drawn OUTSIDE the window frame by the X server
- In Wayland, borders are scene rects at geometry edges
- Titlebars must start INSIDE the border area, hence `border_width` inset
- See `titlebar_get_area()` in `objects/client.c`

**Window Visibility Timing**
- X11: `xcb_map_window()` maps immediately, content shows when ready
- Wayland: Scene node not enabled until content is ready
- `drawin_refresh_drawable()` in `objects/drawin.c` enables the scene node once content exists
- Prevents visual smearing during initial render

**GTK Theme Detection**
- AwesomeWM's `beautiful/gtk.lua` creates actual GTK+ 3 widgets via LGI and queries `GtkStyleContext` for live theme colors
- SomeWM parses `~/.config/gtk-3.0/settings.ini` and `~/.config/gtk-4.0/settings.ini` directly, with Adwaita Dark as the fallback
- Theme detection is less accurate — complex GTK CSS that the file parser cannot read will be missed

**Xresources**
- AwesomeWM's `beautiful/xresources.lua` queries the X server's resource database via `xrdb`
- SomeWM's `gears/xresources.lua` parses `~/.Xresources` directly, falling back to Catppuccin Mocha defaults
- This means `Xft.dpi` and other resources work, but dynamically loaded resources (via `xrdb -merge`) won't be picked up

**Wibox Shape Surfaces**
- AwesomeWM uses 1-bit alpha masks for shape bounding/clip/input surfaces
- SomeWM uses full ARGB32 surfaces with `cairo.Antialias.BEST`, producing anti-aliased rounded corners
- Shape surfaces are scaled by `screen.scale` for HiDPI
- Surface references are retained (not finished) because the C side reads them asynchronously on Wayland, unlike X11 which copies immediately
- SomeWM adds a `shape_border` property on wibox for colored anti-aliased shape borders

**Window Type Handling**
- Native Wayland clients may not set a window type, resulting in `c.type == nil`
- SomeWM treats `nil` type as `"normal"` in `awful/client.lua` so focus rules and placement work correctly

---

## Not Implemented (Stubs Only)

These APIs exist as stubs for compatibility but don't function:

| API | Status | Reason |
|-----|--------|--------|
| `awesome.register_xproperty()` | Stub | X11 property persistence doesn't exist on Wayland |
| `awesome.get_xproperty()` | Stub | X11 property persistence doesn't exist on Wayland |
| `awesome.set_xproperty()` | Stub | X11 property persistence doesn't exist on Wayland |
| `awesome.xkb_set_layout_group()` | No-op | Not yet wired to wlroots XKB state |
| `awesome.xkb_get_layout_group()` | Returns `0` | Not yet wired to wlroots XKB state |
| `awesome.xkb_get_group_names()` | Returns `""` | Not yet wired to wlroots XKB state |
| `root._string_to_key_code()` | Returns `0` | X11 keycode conversion; somewm uses xkbcommon keysyms directly |

### X Property APIs

The global stubs (`luaA_register_xproperty()`, `luaA_set_xproperty()`, `luaA_get_xproperty()` in `property.c`) and per-client stubs (`luaA_client_get_xproperty()`, `luaA_client_set_xproperty()` in `objects/client.c`) return "not yet implemented" warnings.

X11 properties were used for:
- Storing persistent per-window state
- Inter-client communication
- Session management

Wayland alternatives (not yet implemented):
- D-Bus for IPC
- Compositor-side storage for persistent state

### XKB Layout Functions

All three XKB Lua-facing functions in `xkb.c` are stubs. `xkb::map_changed` and `xkb::group_changed` signals do fire correctly, but the query/set APIs are not yet connected.

Multi-layout keyboard users should use `awful.input` to configure layouts at startup:
```lua
awful.input.xkb_layout = "us,ru"
awful.input.xkb_options = "grp:alt_shift_toggle"
```

Programmatic layout switching from Lua is not yet supported.

---

## Partially Implemented

| Feature | Status | Notes |
|---------|--------|-------|
| XKB toggle options | Layout set at startup only | `grp:alt_shift_toggle` etc. work at the XKB level but don't emit signals to Lua |
| Button press/release signals | Partial | `client::button_press` not fully emitted |
| Dynamic keybinding removal | Stub | `root._remove_key()` is no-op |
| Keygrabber release events | Press only | Callbacks only receive `"press"`, never `"release"` |
| Client `instance` property | Empty for Wayland | Wayland has no equivalent of `WM_CLASS` instance field |
| Client `machine` property | Empty for Wayland | Wayland has no `WM_CLIENT_MACHINE` equivalent |
| Client `icon_name` property | Empty for Wayland | No Wayland protocol provides this |
| `spawn::change` signal | Never emitted | Startup-notification progress not tracked on Wayland |
| `spawn::canceled` signal | Never emitted | Startup-notification cancellation not tracked |

### Keygrabber Release Events

`some_keygrabber_handle_key()` in `keygrabber.c` always passes `"press"` as the event type. Key release events are never forwarded to keygrabber callbacks.

This affects keygrabber-based UIs that use release detection, such as Alt-Tab implementations where releasing Alt confirms the selection.

### Client Properties for Native Wayland

The `instance`, `machine`, and `icon_name` properties are populated for XWayland clients (from X11 properties) but empty for native Wayland clients. The Wayland protocol does not provide direct equivalents.

For rule matching, use `class` (populated from the Wayland `app_id`) instead of `instance`:
```lua
-- AwesomeWM (X11): rule = { instance = "Navigator" }
-- SomeWM: use class instead
ruled.client.append_rule {
    rule = { class = "firefox" },
    properties = { tag = "web" },
}
```

---

## XWayland EWMH Gaps

These affect XWayland (X11) clients only. Native Wayland clients are not affected.

| Feature | Status | Impact |
|---------|--------|--------|
| `_NET_FRAME_EXTENTS` | Not sent | CSD-aware XWayland apps may misposition windows |
| `_NET_DESKTOP_GEOMETRY` | Hardcoded 1920x1080 | XWayland pagers/tools see wrong geometry on non-1080p monitors |
| `_NET_WM_DESKTOP` | Read but not applied | XWayland apps setting desktop before mapping land on wrong tag |
| Maximized combo | No h-max + v-max merging | XWayland apps requesting both get two state changes instead of one clean maximize |

These are tracked for future improvement. Most native Wayland apps are unaffected.

---

## Lua Layer Changes

These modifications to AwesomeWM's Lua libraries were necessary for Wayland compatibility:

| File | Change | Reason |
|------|--------|--------|
| `wibox/widget/systray.lua` | Complete rewrite | SNI D-Bus protocol replaces X11 XEmbed |
| `beautiful/gtk.lua` | Complete rewrite | File parsing replaces live GTK widget queries |
| `wibox/init.lua` | ARGB32 shapes, HiDPI scaling, surface lifetime, `shape_border` | Wayland scene graph and compositing model |
| `wibox/drawable.lua` | HiDPI scale-change handler | Recreates surfaces when `screen.scale` changes |
| `awful/client.lua` | `c.type or "normal"` fallback | Native Wayland clients may not set window type |
| `awful/permissions/init.lua` | Layer surface keyboard focus handlers | Wayland layer-shell has no X11 equivalent |
| `awful/mouse/snap.lua` | ARGB32 shapes, surface lifetime | Same Wayland surface patterns as `wibox/init.lua` |
| `gears/filesystem.lua` | `somewm/` paths | Rebranded config/cache directories |
| `naughty/dbus.lua` | `awesome.version or "somewm-dev"` fallback | Version string safety |

### New Lua Modules (no AwesomeWM equivalent)

| Module | Purpose |
|--------|---------|
| `awful.input` | Libinput pointer/keyboard configuration |
| `awful.ipc` | Unix socket IPC for `somewm-client` |
| `awful.systray` | D-Bus StatusNotifierHost |
| `awful.statusnotifierwatcher` | D-Bus `org.kde.StatusNotifierWatcher` |
| `wibox.widget.systray_icon` | Individual SNI icon widget |
| `ruled.layer_surface` | Rules for layer-shell surfaces (panels, launchers) |
| `gears.xresources` | File-based Xresources parser |
| `gears.bitwise` | Pure-Lua bitwise operations |

---

## SomeWM-Only Features

These features are unique to somewm and don't exist in AwesomeWM:

### `awful.input` - Input Device Configuration

18 properties for pointer and keyboard settings:

```lua
local awful = require("awful")

-- Pointer settings
awful.input.tap_to_click = 1
awful.input.natural_scrolling = 1
awful.input.pointer_speed = 0.5
awful.input.scroll_button = 274  -- Middle mouse
awful.input.left_handed = 0

-- Keyboard settings
awful.input.xkb_layout = "us"
awful.input.xkb_variant = ""
awful.input.xkb_options = "ctrl:nocaps"
awful.input.repeat_rate = 25
awful.input.repeat_delay = 600
```

### NumLock on Startup

Wayland compositors start with NumLock off by default. AwesomeWM has no equivalent API because X11 inherits NumLock state from the display server.

Enable NumLock at startup from `rc.lua`:

```lua
awesome._set_keyboard_setting("numlock", true)
```

`some_set_numlock()` in `somewm_api.c` toggles the Mod2 locked modifier mask via `wlr_keyboard_notify_modifiers()` on all member keyboards (same pattern as Sway's `input * xkb_numlock enabled`).

NumLock (Mod2) is automatically stripped from `CLEANMASK` so keybindings and wibar scroll bindings work correctly whether NumLock is on or off.

---

### `somewm-client` - IPC CLI Tool

~45 commands for external control:

```bash
somewm-client ping                    # Health check
somewm-client client list             # List windows
somewm-client client focus <id>       # Focus window
somewm-client input tap_to_click 1    # Set input property
somewm-client eval "return 1+1"       # Eval Lua
somewm-client screenshot              # Take screenshot
```

### `output` - Physical Monitor Object

The `output` object represents a physical monitor connector (HDMI-A-1, DP-2, eDP-1). Unlike `screen` objects (which are destroyed on disable and recreated on enable), output objects persist from plug to unplug.

```lua
-- Iterate outputs
for o in output do
    print(o.name, o.make, o.enabled)
end

-- Configure by hardware
output.connect_signal("added", function(o)
    if o.name:match("^eDP") then
        o.scale = 1.5
    end
end)

-- Access from a screen
local o = screen.primary.output
```

AwesomeWM has no equivalent because X11 delegates monitor management to `xrandr`. See `objects/output.c`.

### `screen.scale` - Fractional Output Scaling

Set output scale dynamically from Lua or CLI. `screen.scale` delegates to `output.scale` as a single source of truth.

```lua
-- Lua API (both are equivalent)
screen.primary.scale = 1.5
screen.primary.output.scale = 1.5
```

```bash
# CLI
somewm-client screen scale           # Get focused screen scale
somewm-client screen scale 1.5       # Set focused screen to 1.5
somewm-client screen scale 1 1.5     # Set screen 1 to 1.5
```

Apps supporting `wp_fractional_scale_v1` render at native resolution. Struts/workarea are automatically recalculated after scale changes.

### `screen.content` - Screenshots

Capture screen contents from Lua:

```lua
local surface = screen.primary.content
```

### Additional Client Properties

| Property | Description |
|----------|-------------|
| `client.id` | Unique compositor-assigned client ID |
| `client.aspect_ratio` | Client aspect ratio hint |
| `client.shadow` | Per-client shadow toggle |

### Cursor Theming

```lua
root.cursor_theme("Adwaita", 24)   -- Set cursor theme and size
root.cursor_size()                  -- Get current cursor size
```

### SNI Systray

Modern D-Bus tray protocol instead of X11 embed. Implementation:
- `objects/systray.c` - C object and D-Bus watcher
- `lua/awful/statusnotifierwatcher.lua` - Lua bindings
- `wibox.widget.systray` - Widget (rewritten from AwesomeWM's X11 version)

### Layer Surface Rules

Wayland layer-shell surfaces (panels, launchers, overlays) can be matched with rules:

```lua
ruled.layer_surface.append_rule {
    rule = { namespace = "launcher" },
    properties = { keyboard_interactivity = "exclusive" },
}
```

---

## Testing Implications

Some AwesomeWM tests won't work due to these deviations:

| Test Pattern | Issue | Workaround |
|--------------|-------|------------|
| X property tests | APIs are stubs | Skip or use D-Bus alternatives |
| Keygrabber release tests | Only press events sent | Skip release-dependent tests |
| XKB layout switching tests | Layout query/set APIs are stubs | Test via `awful.input` instead |
| `instance`-based rule tests | Empty for Wayland clients | Use `class` matching instead |

---

## Future Work

Potential future compatibility improvements:

1. **XKB layout functions** - Wire `xkb_set_layout_group()` / `xkb_get_layout_group()` / `xkb_get_group_names()` to wlroots XKB state
2. **Keygrabber release events** - Forward key release to keygrabber callbacks
3. **Property storage** - Compositor-side persistent state for clients
4. **Session management** - Wayland-native session protocol support
5. **EWMH frame extents** - Send `_NET_FRAME_EXTENTS` to XWayland clients
6. **EWMH desktop geometry** - Report actual output geometry instead of hardcoded 1920x1080
