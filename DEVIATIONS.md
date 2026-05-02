# SomeWM Deviations from AwesomeWM

This document tracks all known differences between somewm and AwesomeWM. These exist primarily due to fundamental differences between X11 and Wayland protocols.

## Architectural Differences (Wayland vs X11)

| Feature | AwesomeWM (X11) | SomeWM (Wayland) | Reason |
|---------|-----------------|------------------|--------|
| Systray | X11 `_NET_SYSTEMTRAY` embed | StatusNotifierItem D-Bus (SNI) | X11 tray protocol doesn't exist on Wayland |
| Titlebar borders | Outside frame (X server draws) | Inset by `border_width` | Scene graph positioning differs |
| Window visibility | `xcb_map_window()` shows immediately | Content must exist before showing | Prevents smearing artifacts |
| WM restart | `awesome.restart()` re-execs the process | In-process Lua hot-reload (clients survive) | Wayland compositor can't re-exec; tears down and rebuilds Lua VM instead |
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

**WM Restart**
- AwesomeWM re-execs itself via `execvp()`, restarting the entire process
- SomeWM performs in-process Lua hot-reload: tears down the Lua VM, rebuilds it from `rc.lua`, and reattaches existing clients
- wlroots, the scene graph, and client surfaces are untouched during reload
- The old Lua state is intentionally leaked (~1-2 MB) to avoid Lgi closure crashes
- An LD_PRELOAD closure guard (`lgi_closure_guard.so`) blocks stale FFI closures from the leaked state

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

## Signal Dispatch (somewm 2.0)

AwesomeWM dispatches signals synchronously: when C code calls `luaA_object_emit_signal()`, every connected Lua handler runs before the C function returns. somewm 2.0 changes this for most C-to-Lua emissions. They are queued in `event_queue.c` and drained at the start of `some_refresh()` (once per frame, before the `refresh` global signal and the layout / banning / stacking pass).

Lua-to-Lua emissions (`c:emit_signal("foo")` from inside a Lua handler) remain synchronous. Only C-to-Lua emissions are queued.

### What's queued vs synchronous

Queued signals (delivered at the next frame boundary):

- **Geometry**: `property::geometry`, `property::position`, `property::size`, `property::x`, `property::y`, `property::width`, `property::height`, `client::property::geometry`
- **Focus**: `focus`, `unfocus`, `property::active`, `client::focus`, `client::unfocus`
- **Mouse**: `mouse::enter`, `mouse::leave`, `mouse::move` (coalesced to one event per object per frame)
- **Lifecycle**: `list`, `swapped`
- **Request**: `request::activate`, `request::urgent`, `request::tag`, `request::select`, plus the systray equivalents (`request::secondary_activate`, `request::context_menu`, `request::scroll`)

Kept synchronous:

- `request::manage`, `request::unmanage`: rules must run before the client is visible, and client properties must still be valid during the handler
- `request::geometry`: the Lua handler applies new geometry (fullscreen / maximize) via `c:geometry(...)`, and C code inspects `c->geometry` immediately after the emission (`client_set_fullscreen` calls `client_resize_do` on the next line). Queueing would leave that resize operating on stale bounds.
- `scanning`, `scanned`: startup synchronization barriers
- Scalar `property::*` signals (`property::name`, `property::type`, `property::window`, `property::screen`, `property::fullscreen`, `property::maximized*`, `property::size_hints_honor`): the new value is already in C state when the signal fires; queueing them adds latency with no batching benefit

### Signals removed

| Signal | Replacement |
|--------|-------------|
| `client.manage` | `client.request::manage` |
| `client.unmanage` | `client.request::unmanage` |

AwesomeWM marked these as `TODO v6: remove this` upstream. somewm 2.0 follows through. User configs that connect to `client.connect_signal("manage", ...)` or `"unmanage"` will silently stop running on somewm 2.0; replace those connections with the `request::*` variants. The handler signatures are identical.

### Cross-API consistency window

Several Lua modules connect to queued signals to maintain side-table state. Because those signals are now queued, there is a narrow window during which that side state is stale: between the C call that triggers the change and the next `some_refresh()` drain. The window only matters for Lua callbacks that fire from a non-refresh source (timer, D-Bus, IPC, keybinding dispatch, another synchronous signal handler) and read state mutated by a queued handler.

Within a single drain, queued handlers fire in emission order, so they see consistent state relative to each other. The `refresh` global signal and the layout / banning / stacking pass always run after the drain, so layouts always see fresh state.

Known APIs that read cross-window-affected state:

| Public API | Driven by | What's stale between C emission and drain |
|---|---|---|
| `awful.client.focus.history.get(screen, idx, filter)` | `focus` signal | Most-recent focused client |
| `awful.client.focus.history.previous()` | `focus` signal | Target client for Alt+Tab-style cycling |
| `awful.client.urgent.get()` / `urgent.jumpto()` | `property::urgent`, `focus` | Urgent-client stack |
| `awful.tag.history.restore()` / `tag.history.previous` | `request::select` | Previous-tag list for "back" navigation |
| `awful.layout.parameters()` | `property::geometry` and siblings | Layout's view of client geometry |

If a stale read shows up in practice, wrap it in `gears.timer.delayed_call(...)` to push the read past the next drain:

```lua
-- Instead of reading history right after changing focus in a keybinding:
awful.client.focus.byidx(1)
local prev = awful.client.focus.history.get(screen, 1)  -- stale

-- Defer the read past the next drain:
awful.client.focus.byidx(1)
gears.timer.delayed_call(function()
    local prev = awful.client.focus.history.get(screen, 1)  -- fresh
    -- ...
end)
```

Widget-layer consumers (`naughty.list`, `awful.widget.tasklist`, `awful.widget.taglist`, `wibox.drawable` repaints, `awful.placement` tracking) already defer via `gears.timer.delayed_call()` in the existing code, so their visual state lines up with the drained signals.

---

## Layout Engine (somewm 2.0)

somewm 2.0 introduces [Clay](https://github.com/nicbarker/clay) as the universal layout engine. Every positional decision in the compositor flows through Clay, replacing the bespoke geometry math scattered across AwesomeWM's Lua libraries.

### What goes through Clay

| Pass | Where | Owner |
|---|---|---|
| Screen composition (wibars + workarea) | `compose_screen` in `lua/awful/layout/clay/init.lua` | Lua |
| Tiled-client layout (tile / fair / max / corner / spiral / spiral.dwindle / floating) | `awful.layout.clay.*` presets, all using `body_signature = "context"` descriptors. `floating` emits a stack of self-positioned clients (no-op solve for positioning + bw2 round-trip preservation). `max.fullscreen` drives its own `layout.solve` at `screen.geometry` bounds because the tag-suit adapter solves against the workarea. `magnifier` is a deliberate bespoke exception (two `layout.solve` passes for overlap; documented in `lua/awful/layout/clay/magnifier.lua`). | Lua |
| Per-client decoration (4 borders + 4 titlebars + surface + shadow) | `clay_apply_client_decorations()` in `clay_layout.c` | C |
| Widget hierarchy (wibox.layout.*) | All wibox layouts route through Clay. `flex` / `fixed` use flex distribution including `spacing_widget` (interleaved spacer leaves). `align` covers all three expand modes via Clay: `inside` / `outside` flex-grow; `none` is `layout.stack` with absolute child positions. `ratio` default uses flex distribution; non-default strategies (justify/center/spacing/left/right) and `spacing_widget` compute slot positions in Lua (void redistribution) then emit via `layout.stack` with absolute child positions. `stack` (z-order with offsets), `manual` (user-supplied points), and `grid` (cell math) all emit via `layout.stack`. | Lua via `somewm.layout.solve` |
| Container layout (wibox.container.{margin, place, background, constraint, border}) | each container's `:layout` calls `somewm.layout.solve`; `border` is a 9-slice container that emits via `layout.stack` with absolute child positions for the corners, edges, fill, and inner widget. | Lua via `somewm.layout.solve` |
| Layout-shaped placement (`placement.align` + 11 anchor aliases) | `awful.placement.align` calls `somewm.placement.solve` | Lua via `somewm.placement.solve` |
| Notification stacking (`naughty.layout.box`) | First notification routes through `placement[position]` (Clay-backed alias); subsequent notifications chain `placement.next_to`, intentionally bespoke per the next-to row below. | Lua via `somewm.placement.solve` (first) + bespoke search (rest) |
| Submenu placement (`awful.menu:set_coords`) | Direct screen-clamping math + next-to-style fallback (try right of parent, fall back to left). Both pieces are documented as bespoke below. | Bespoke (transitively-Clay where applicable) |
| Menubar geometry (`menubar.show`) | Trivial assignment of `screen.workarea` x/y/width to the menubar wibox; not anchor-shaped. | Direct, transitively-Clay through workarea (computed by `compose_screen`) |
| Layer-shell anchoring | `clay_apply_layer_surface()` in `clay_layout.c` | C |

### What stays bespoke (and why)

Clay handles **layout** (anchor a rect inside a parent rect with sizing / padding / alignment). Concerns that aren't layout — input, persistence, policy, orchestration — stay in their original modules. AwesomeWM bundled these together into `awful.placement`; somewm 2.0 keeps the public API but draws the line cleanly:

| Concern | Module | Why |
|---|---|---|
| Cursor reads | `placement.under_mouse`, `placement.next_to_mouse`, `placement.resize_to_mouse` | Input concern; not tree-shaped |
| Region search | `placement.no_overlap` | Rect subtraction over neighbors; not a tree |
| Try-and-fit | `placement.next_to` | Search algorithm with short-circuit; Clay can't express |
| Distance compare | `placement.closest_corner` | Snap math; delegates to `placement.align` for the anchor step |
| Memento | `placement.restore`, `placement.store_geometry` | Persistence concern |
| Boundary clamp | `placement.no_offscreen` | Trivial 8-line clamp; Clay roundtrip would add work |
| Single-axis transform | `placement.stretch`, `placement.maximize`, `placement.scale` | Preserves one corner of `dgeo`, transforms the other; not anchor-shaped |
| Scrollable / viewport-relative | `awful.layout.suit.carousel` | Unbounded strip with a viewport offset; positions depend on scroll state, not on a finite parent rect. Outside Clay's anchor-a-rect-inside-a-rect model. |
| Absolute-position emission | `wibox.widget.systray` (multi-row case) | Computes a grid of icon positions (`col * (icon + spacing)`) and builds placements with `base.place_widget_at` directly. The other absolute-position layouts (`wibox.layout.{stack, manual, grid}`, `wibox.layout.ratio` non-default, `wibox.container.border`) now route through `layout.stack` with absolute child props; only systray's multi-row override still skips the substrate. |
| Matrix transform | `wibox.container.{mirror, rotate}` | Cairo affine transforms applied at draw time; the contained widget fills the parent pre-transform (a trivial fill), then the matrix flips or rotates the result. Adding a Clay solve here would be a no-op round-trip; the wrapped widget's own `:layout()` already goes through Clay if it uses Clay-routed primitives. The wrapper is transparent to that. |

### Public API: `somewm.layout` and `somewm.placement`

Two engine-agnostic public modules expose Clay-backed layout to user code:

- **`somewm.layout`** (`lua/somewm/layout/init.lua`): declarative composition API. `layout.row`, `layout.column`, `layout.stack`, `layout.widget`, `layout.client`, `layout.drawin`, `layout.measure`, `layout.percent`, `layout.solve`. Used by every Clay-backed layout / container under the hood. Solve returns raw rect tables `{widget, x, y, width, height}`; wibox callers wrap into placement objects via `wibox.widget.base.place_rects`. The substrate has no dependency on wibox.

- **`somewm.placement`** (`lua/somewm/placement/init.lua`): single function `solve { parent, target_width, target_height, anchor }` returning `{ x, y, width, height }` in absolute coords. Used by `placement.align`'s fast path.

Naming convention: public surfaces describe what they DO (`layout.row`, `placement.solve`), not what they're MADE OF. Engine-internal identifiers — `_somewm_clay`, `clay_layout.c`, `Clay_*` macros, `clay_apply_client_decorations`, `clay_apply_layer_surface` — keep their honest names because they live at the engine layer. If we ever swap engines, only the engine layer changes; user code is untouched.

### Substrate principle

`somewm.*` is the foundation namespace for somewm-only capabilities. Both `awful.*` and `wibox.*` may depend on `somewm.*`; `somewm.*` does not depend on either. AwesomeWM-mirror modules (`gears`, `wibox`, `awful`, `naughty`, `beautiful`, `ruled`, `menubar`) keep their existing names and shapes — Prime Directive holds; we don't relitigate AwesomeWM's choices on existing public surfaces.

### Workarea: single source of truth

`screen.workarea` is computed exclusively by `clay.compose_screen`. The legacy strut-based path (`screen_update_workarea` in `objects/screen.c`) is gone. `wb:struts(...)` is a no-op deprecation; wibar position contributes to workarea via Clay's column / padding tree. Layer-shell exclusive zones reach `compose_screen` via `screen->layer_exclusive`, populated by `arrangelayers()` after `clay_apply_layer_surface()` walks the layer-surface list.

### Custom layouts: `arrange(p)` still supported

Existing user layouts (`function arrange(p) ... end` populating `p.geometries[c] = {...}`) keep working through the fallback at `lua/awful/layout/init.lua` (`if not p._clay_managed`). Setting `p._clay_managed = true` opts a custom layout into the Clay path; otherwise the legacy arrange flow applies geometries imperatively.

### Soft-aliased layout namespace

`awful.layout.suit.tile == awful.layout.clay.tile` by literal table identity. `tag.layout = awful.layout.suit.tile` keeps working; identity comparisons in user keybindings stay true. The legacy `suit/{tile, max, corner, magnifier, fair, spiral}.lua` files have been deleted; their `mouse_resize_handler` and policy fields now live next to each layout in `clay/*.lua`. `suit/floating.lua` survives as a one-line shim returning `clay.floating` because `awful.placement`, `awful.tag`, and `awful.mouse` import it directly for table-identity comparisons; the shim preserves identity. `suit/init.lua` is a literal alias table and `suit/carousel.lua` keeps its own legacy body (carousel is genuinely separate, see "What stays bespoke" above).

### No frame scheduler

Layout solves are not tied to vblank. Coalescing happens at the event-loop tick level via `gears.timer.delayed_call`:

- **Wibox.** `widget::layout_changed` invalidates a `gears.cache` keyed on `(context, w, h)` (`lua/wibox/widget/base.lua:613`). The drawable schedules `_do_redraw` via `gears.timer.delayed_call` (`lua/wibox/drawable.lua:418`), one-shot per tick. Multiple invalidations within a tick collapse to one `:layout` call.
- **Tag arrange.** `awful.layout.arrange` debounces via its own `gears.timer.delayed_call`. Same one-shot semantics; bursts of geometry changes coalesce.

The vblank-aligned scheduler proposed in earlier design notes (`mark_dirty + flush at output_frame`) was declined. Coalescing is already provided by `delayed_call`; the cache invalidation rule (`widget::layout_changed` clears the per-widget cache) provides determinism. The unique addition vblank alignment would have given is correctness for a "delayed_call resolves after the frame submit, producing a one-frame-stale display" scenario, which the load profile (idle ~0/sec, textclock ~1/min, animations on client geometry not widget layout) doesn't produce. If that scenario ever appears in practice, the scheduler is ~100 LOC away and would be built then as a targeted fix.

The load-profile claim was instrumented and verified in 2026-04 (see `ideas/redraw-loop-data.md`): solve-counters keyed by source confirm idle is ~0.1 solves/sec total, drag-resize is ~625-1252 solves/sec, and every solve corresponds to a real input change. The `delayed_call` coalescer is doing what it was designed to do.

### Decoration sub-pass cache

`clay_apply_client_decorations()` runs from `commitnotify` on every surface commit per visible client, not just on geometry changes. The decoration tree's inputs (`c->geometry.{width,height}`, `c->bw`, `c->fullscreen`, `c->titlebar[*].size`) are invariant across the vast majority of those commits. A per-client stamp cache (`decor_cache_t` field on `client_t` defined in `objects/client.h`) stores the last input state plus the resulting `inner_w`/`inner_h`; the head of `clay_apply_client_decorations()` short-circuits the Clay solve when the stamp matches. The visibility loop and shadow update stay outside the cache because both are already idempotent. No external invalidation is needed: the comparison is the invalidation. Pre-cache idle was ~1057 decoration solves/sec; post-cache it is 0.

### Why some Clay trees stay in C

Two layout paths build their Clay tree from C, not via a Lua descriptor through `somewm.layout.solve`. Both are deliberate exceptions, not migration TODOs:

| Path | C function | Reason to stay in C |
|---|---|---|
| Per-client decoration | `clay_apply_client_decorations()` (`clay_layout.c`) | Fires per pointer-move event during interactive resize, on top of the `SIG_PROPERTY_GEOMETRY` Lua roundtrip already paid in `client_resize_do()`. A Lua descriptor would be a *second* roundtrip per pointer event, with no stated customizability requirement to amortize the cost. |
| Layer-shell anchoring | `clay_apply_layer_surface()` (`clay_layout.c`) | Battle-tested anchor / exclusive-zone math. A Lua port would expose a new layer-surface state surface (margin, desired_size, exclusive_zone modes) for a feature no current consumer asks for, plus a C↔Lua roundtrip per layer-surface commit. Net +LOC across two languages for partial substrate uniformity. |

Both trees are portable to Lua descriptors if a consumer arises (theming hooks, plugin-driven decorations, layer-surface rules that depend on geometry). The substrate (`somewm.layout.solve` plus the engine wrappers in `_somewm_clay.*`) supports it; only the descriptor + glue need to be added.

---

## No-Op APIs

These APIs exist and can be called without error, but have no effect on Wayland.

| API | Status | Reason |
|-----|--------|--------|
| `awful.client.shape.update.all` | No-op | X11 Shape Extension unavailable on Wayland |
| `awful.client.shape.update.bounding` | No-op | X11 Shape Extension unavailable on Wayland |
| `awful.client.shape.update.clip` | No-op | X11 Shape Extension unavailable on Wayland |
| `awful.client.shape.update.input` | No-op | X11 Shape Extension unavailable on Wayland |

### Client Shape (Rounded Corners)

Location: `luaa.c` require() hook, patched at load time

AwesomeWM uses the X11 Shape Extension (`xcb_shape_mask()`) to apply non-rectangular window shapes (e.g. rounded corners via `gears.shape.rounded_rect`). Wayland has no equivalent protocol-level feature. The `awful.client.shape.update.*` functions are replaced with no-ops via a require() hook so that user configs referencing `client.shape_bounding` or `client.shape_clip` load without error.

See `ideas/Shapes.md` for technical rationale and potential future approaches (shader-based clipping, custom render pass).

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
| Client `instance` property | Empty for Wayland | Wayland has no equivalent of `WM_CLASS` instance field |
| Client `machine` property | Empty for Wayland | Wayland has no `WM_CLIENT_MACHINE` equivalent |
| Client `icon_name` property | Empty for Wayland | No Wayland protocol provides this |
| `spawn::change` signal | Never emitted | Startup-notification progress not tracked on Wayland |
| `spawn::canceled` signal | Never emitted | Startup-notification cancellation not tracked |

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
| `awful.layout.suit.carousel` | Scrollable tiling layout (horizontal and vertical) |
| `somewm` | Lazy-loaded namespace for somewm-only Lua modules |
| `somewm.layout_animation` | Animated tiling transitions (mwfact, layout switch, spawn/kill) |

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
awful.input.accel_speed = 0.5
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

### Carousel Layout

A niri-inspired scrollable tiling layout with no AwesomeWM equivalent. Clients are arranged in columns on an infinite horizontal (or vertical) strip, with the viewport auto-scrolling to keep the focused column visible.

Carousel does NOT route through Clay. Column positions are computed imperatively from the focused-column index plus a viewport offset, which is outside Clay's "anchor a rect inside a parent rect" model (see the bespoke list above). Clients off-viewport get assigned negative or out-of-bounds coordinates via `client:_set_geometry_silent`, which the rest of the compositor honors without re-clamping.

**Layout registration:** `lua/awful/layout/suit/init.lua` is modified to include `carousel = require("awful.layout.suit.carousel")`. This is the only change to a Sacred Lua file in this feature.

**New Lua APIs (underscore-prefixed, internal use):**

| API | Object | Purpose |
|-----|--------|---------|
| `client:_set_geometry_silent(geo)` | client | Set geometry without emitting signals or reassigning screens. Used by layouts that position clients offscreen (e.g. scrolling). |
| `awesome.start_animation(duration, easing, tick_fn, done_fn)` | awesome | Frame-synced animation with easing. Returns a handle with `:cancel()` and `:is_active()`. |

**C-side changes:**
- `client_resize()` gains a `silent` parameter to skip signal emission and screen reassignment
- `commitnotify` in `somewm.c` skips `resize()` for tiled clients so offscreen positioning is not clamped
- `animation.c` provides the C-side animation tick loop, integrated into `some_refresh()`

### `somewm.*` - SomeWM-Only Lua Namespace

Lazy-loaded namespace for somewm-specific Lua modules that have no AwesomeWM equivalent. Submodules live under `lua/somewm/` and are loaded on first access via `require("somewm")`.

### `somewm.layout_animation` - Animated Layout Transitions

Hooks into `screen::arrange` and smoothly animates tiled clients from their previous geometry to the new one. Covers all arrange triggers: mwfact changes, client spawn/kill, layout switches, column count changes.

```lua
local layout_anim = require("somewm.layout_animation")
layout_anim.duration = 0.15          -- seconds
layout_anim.easing   = "ease-out-cubic"
layout_anim.enabled  = true           -- default
```

Animation is skipped when disabled, during mousegrabber (direct manipulation), when the geometry delta is negligible (< 2px), or on a client's first arrange.

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
2. **Property storage** - Compositor-side persistent state for clients
3. **Session management** - Wayland-native session protocol support
4. **EWMH frame extents** - Send `_NET_FRAME_EXTENTS` to XWayland clients
5. **EWMH desktop geometry** - Report actual output geometry instead of hardcoded 1920x1080
