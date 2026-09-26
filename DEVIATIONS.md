# SomeWM Deviations from AwesomeWM

This document tracks all known differences between somewm and AwesomeWM. These exist primarily due to fundamental differences between X11 and Wayland protocols.

### Native widget overlap and clock placement (2.1)

Stack and supported numeric manual children contribute their own floating Clay elements. Their preferred, forced and minimum extents remain on the child; floats never determine the parent's size. Stack spacing plus the accumulated horizontal/vertical offsets now supplies the attachment offset, replacing the anonymous full-parent floats and their simulated padding. Declaration order and `top_only` remain unchanged. Numeric manual allocations retain a child's larger preferred/forced extent as before.

A floating place container without independent bounds contributes native parent/own attachment points, with its original occurrence bound to the child's element. The bundled clock background therefore attaches center to center at its intrinsic size as the bar resizes. Ordinary flow place containers and distinct forced/minimum or text allocation boundaries remain. Widget attachment fields `parent`, `own` and `passthrough` use the drawin attachment point numbering; absent fields keep top-left points and pointer passthrough. Capture stops lower floats, and the scene/tree guard recognizes that the captured descendant belongs to its drawable.

## Architectural Differences (Wayland vs X11)

| Feature | AwesomeWM (X11) | SomeWM (Wayland) | Reason |
|---------|-----------------|------------------|--------|
| Systray | X11 `_NET_SYSTEMTRAY` embed | StatusNotifierItem D-Bus (SNI) | X11 tray protocol doesn't exist on Wayland |
| Titlebar borders | Outside frame (X server draws) | Inset by `border_width` | Scene graph positioning differs |
| Window visibility | `xcb_map_window()` shows immediately | Content must exist before showing | Prevents smearing artifacts |
| WM restart | `awesome.restart()` re-execs the process | In-process Lua hot-reload (clients and persistent client properties survive) | Wayland compositor can't re-exec; tears down and rebuilds Lua VM instead |
| GTK theme detection | Creates GTK widgets, queries `GtkStyleContext` | Parses `gtk-3.0/settings.ini` and `gtk-4.0/settings.ini` | Creating GTK windows inside a compositor is unsafe |
| Xresources | Queries `xrdb` server | Parses `~/.Xresources` file directly | No `xrdb` server on Wayland |
| Wibox shape surfaces | 1-bit (`cairo.Format.A1`) | Full ARGB32 with anti-aliasing | Enables anti-aliased rounded corners and HiDPI scaling |
| Client-drawn titlebar buttons | No equivalent (X11 apps ask via `_NET_WM_STATE`) | `xdg_toplevel.set_maximized` / `set_minimized` set `c.maximized` / `c.minimized` | GTK and Chromium draw their own titlebars; the requests go through the same `request::geometry` path `awful.permissions` already governs |
| Config/cache paths | `~/.config/awesome/`, `~/.cache/awesome/` | `~/.config/somewm/`, `~/.cache/somewm/` | Rebranded |

### Detailed Explanations

**Systray (SNI vs X11 embed)**
- AwesomeWM uses X11's `_NET_SYSTEMTRAY` protocol to embed tray icon windows
- SomeWM uses the modern StatusNotifierItem D-Bus protocol
- Most apps (NetworkManager, Discord, Bluetooth) support SNI already
- Legacy XEmbed-only apps won't show tray icons

**Titlebar Border Positioning**
- In X11, borders are drawn OUTSIDE the window frame by the X server
- In Wayland, somewm draws borders as scene rects around the geometry: the scene tree origin is the outer border corner and the client footprint is `geometry` plus `border_width` on each side
- `c->geometry` excludes the border, matching AwesomeWM
- Titlebars are inside the geometry and must start INSIDE the border area, hence `border_width` inset
- See `titlebar_get_area()` in `objects/client.c`

**WM Restart**
- AwesomeWM re-execs itself via `execvp()`, restarting the entire process
- SomeWM performs in-process Lua hot-reload: tears down the Lua VM, rebuilds it from `rc.lua`, and reattaches existing clients
- Persistent awful.client properties, including floating state and single-instance IDs, also survive a hot reload.
- wlroots, the scene graph, and client surfaces are untouched during reload
- The old Lua state is closed, so a module must release what it registered with GLib or GDBus when `"exit"` is emitted, or its callback outlives the state it points into
- A source sweep in C and an LD_PRELOAD closure guard (`lgi_closure_guard.so`) back that contract up and report when it is broken. The sweep destroys any GLib source the closed state still owned, so it never dispatches; the guard cannot do the same, since libffi reads a closure's `cif` (which lives in the closed state) before the guard is entered

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
- **Request**: `request::activate`, `request::urgent`, plus the systray equivalents (`request::secondary_activate`, `request::context_menu`, `request::scroll`). `request::tag` and `request::select` have event-queue ids reserved but no C emitter yet; both are emitted from Lua today and therefore dispatch synchronously.
- **Output and screen changes** (when triggered by a monitor being plugged or unplugged, or by an external tool changing output state, e.g. wlr-randr / kanshi): output `property::enabled`, `property::scale`, `property::transform`, `property::mode`, `property::adaptive_sync`, `property::screen` (screen attached), output class `added`; screen `property::scale`, `property::geometry`, `property::workarea`, `primary_changed`, screen class `list`, `property::_viewports`. The Lua-initiated paths stay synchronous: `screen.fake_add`, `screen.fake_remove`, and `s:swap(...)` emit `list` inline, and `screen.primary = s` emits `primary_changed` inline.

  `property::workarea` has two emitters and only the C-driven one queues. `screen_update_workarea()` recomputes the workarea from drawin and client struts and emits inline, so a wibar appearing or a client setting struts still notifies Lua immediately. The same function queues instead when it runs as part of the C geometry path (`luaA_screen_update_geometry` -> `luaA_screen_recalculate_workarea`), because `property::geometry` is queued there and a synchronous workarea signal would otherwise overtake the geometry signal it is meant to follow. Handlers rely on that order: `awful.permissions` re-snaps maximized clients on `property::workarea`, and `awful.layout` shifts clients by the geometry delta on `property::geometry`.
- **Layer shell**: `property::layer`, `property::anchor`, `property::exclusive_zone`, `property::keyboard_interactive`, `property::margin`
- **Globals**: `xkb::map_changed`, `xkb::group_changed`, `idle::stop`, `dpms::on` (from input activity; `awesome.dpms_on()` emits synchronously), `spawn::timeout`, `spawn::completed`, `switch::toggle`, `screen::focus`, `client::map`, `client::unmap`

  `xkb::map_changed` and `xkb::group_changed` are queued even though `awful.keyboard` and `awful.keygrabber` use them to drop a cached modifier map. For one loop iteration after a layout switch those caches still hand out the old map, so a keygrabber running across the switch can convert a modifier against stale data. `xkb_refresh` is already a deferred idle callback, so queueing adds one iteration rather than introducing the delay outright, and the window closes at the next drain.

Kept synchronous:

- `request::manage`, `request::unmanage`: rules must run before the client is visible, and client properties must still be valid during the handler
- `request::geometry`: the Lua handler applies new geometry (fullscreen / maximize) via `c:geometry(...)`, and C code inspects `c->geometry` immediately after the emission (`client_set_fullscreen` calls `client_resize_do` on the next line). Queueing would leave that resize operating on stale bounds.
- `request::focus_restore`: C checks whether the handler set a focused client and falls back to the topmost client otherwise, a synchronous request/response
- `scanning`, `scanned`: startup synchronization barriers
- Client scalar `property::*` signals (`property::name`, `property::type`, `property::window`, `property::screen`, `property::fullscreen`, `property::maximized*`, `property::size_hints_honor`): the new value is already in C state when the signal fires; queueing them adds latency with no batching benefit. `property::screen` additionally has a synchronous Lua path (`c.screen = s`); queueing only the C path could deliver a stale change after a newer one.
- Screen and output teardown (`removed` on both, output `property::screen` when the screen is detached): cleanup invalidates the objects before the drain runs, so queued delivery would be silently dropped, the same reason `request::unmanage` is synchronous. That drop is what `screen_checker()` and `output_checker()` are for: they report a torn-down screen or output invalid so `luaA_object_emit_signal` discards any signal still queued against it. Without them the drain would run handlers on a screen whose index already refers to a different, live screen. As in AwesomeWM, `valid` is then the only property readable on such an object; every other read raises `invalid object`, and `screen[s]` returns nil.
- Screen addition (`added`, `_added`): the hotplug code assigns orphaned clients right after the emission and relies on Lua handlers having created the screen's tags and wibars first, the same reason `request::manage` is synchronous. Both wait on the lifecycle redesign (objects created in a pending state, resolved at the frame boundary).
- layer_surface `request::manage`, `request::unmanage`, `request::keyboard`: same reasons as the client variants; for `request::keyboard`, C reads `has_keyboard_focus` immediately after the emission
- Keybinding, button, and grabber dispatch (`press`, `release`, keygrabber/mousegrabber callbacks): C reads the handler's result to decide whether the input propagates to the client. The deferred design splits this into a synchronous lookup against a pre-registered binding table with dispatch through the queue; until then it stays synchronous.
- `dbus.c` method dispatch: handler return values become the D-Bus reply
- `idle::start`: the idle timer emits the signal and then calls the user's `awesome.set_idle_timeout` callback on the next line. Queueing only the signal would run the callback first, so a handler that snapshots pre-idle state would see it already changed.
- `logind::prepare_sleep`: logind gives a bounded window between `PrepareForSleep(true)` and the machine suspending, which handlers use to lock the screen. A queued signal may not drain before the loop stops, and `a_dbus_process_request` goes on to dispatch the raw D-Bus signal synchronously, which would otherwise arrive first.

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

## Clay Draw Order (somewm 2.1)

somewm 2.1 draws each output from one Clay layout tree. What does not overlap anything is in the tree's flow and has no band: the wibars, layer-shell surfaces with an exclusive zone, and the workarea. What overlaps something is a floating element with a band, Clay's `zIndex`. Clay sorts by band and leaves equal values in declaration order, so clients sharing a band draw in stack order and layer-shell surfaces oldest first. The flow itself sorts at 0, so objects under the bars have a negative band. OUTPUT's own color/image paints before those roots, without a BACKGROUND element or band.

A client's band follows `ontop`, `above`, `below` and `fullscreen`. A transient that sets none of them gets its parent's.

| band | draws |
|------|-------|
| -8 | layer-shell background |
| -6 | desktop clients |
| -4 | desktop and splash drawins (`awful.wallpaper`) |
| -2 | layer-shell bottom |
| 10 | `below` clients |
| 20 | normal floating clients |
| 25 | a wibox placed by its geometry |
| 30 | `above` clients |
| 38 | fullscreen backing rectangle |
| 40 | fullscreen clients |
| 50 | `ontop` clients |
| 60 | `ontop` wibars |
| 70 | layer-shell top |
| 80 | popups, menus and tooltips: `ontop` drawins and xdg popups |
| 90 | notifications |
| 100 | layer-shell overlay |
| 110 | override-redirect X11 windows |
| 120 | the drag icon |
| 200 | the lock backdrop, while the session is locked |
| 210 | the lock covers |
| 220 | the lock surface |
| 32767 | the pointer image |

**Every floating client draws above a wibar that is not `ontop`.** The bar is in flow, so it has no band; a floating client has one. AwesomeWM stacks the same way.

**Override-redirect X11 windows draw above everything.** X11 menus and tooltips set no stacking properties, so somewm gives them the top band. AwesomeWM stacks them with the client that owns them, and somewm 2.0 left the result to scene insertion order. The lock screen still draws above them: it is part of the same tree, in a band above the drag icon.

**The lock screen is part of the output's tree, not a second one.** While the session is locked, somewm declares an opaque backdrop, then the lock covers, then the lock surface, above every band in the table. The backdrop answers every click and every pointer motion itself, so nothing below it can take input, and the compositor sizes it to the output, so a monitor plugged in while locked is covered before the config sees it.

**The pointer is a leaf of the output's tree.** somewm declares the pointer image on the output under the pointer, above every other band: the theme's cursor at that output's scale, or the cursor surface the focused client set, placed at the pointer less its hotspot. wlroots paints no cursor of its own, on a hardware plane or in software, so the leaf is the only pointer drawn. What follows:
- The pointer moves at the output's frame rate, like everything else in the tree. wlroots applied a hardware cursor move at the next output commit too, so the pace is the same.
- The pointer image takes no input. What is under it is what the pointer is over.
- `root.content()` and `screen.content` leave the pointer out, as an X11 screenshot does. A screencopy client such as grim sees it, because it is part of the frame.
- A fullscreen client with the pointer over it is composited rather than scanned out directly. A client that hides its cursor gets direct scan-out back.
- An animated theme cursor (`watch`, `progress`) shows its first frame and does not animate. Animating it would keep an idle output declaring a frame per step for as long as the cursor is up.

**The Clay inspector is not drawn while the session is locked.** Clay declares its panel above every band somewm has, so a locked screen would show the desktop's whole element tree through the lock. `screen.inspector` keeps whatever it was set to and the panel comes back on unlock.

**`wibox:find_widgets` answers from the current frame while locked.** The desktop is still being solved under the lock, so a query against a desktop wibox reports where its widgets are now.

**A drawin keeps the geometry its config gives it.** somewm never resizes a drawin when its screen changes size or moves, so anything sized from `screen.geometry` at construction keeps that size, a percentage `awful.wibar` height or width included, and a full-screen overlay follows `property::geometry` itself; the bundled lockscreen does, and its surfaces always match their screen.

**A drawin's border and shadow do not accept pointer input.** Clicks fall through to whatever draws below, as in 2.0.

**Clicking a client's border focuses that client.** In 2.0 the border was a separate scene rectangle that reported no client, so the click did nothing.

**`border_color` set from Lua survives focus changes.** somewm recolors a client's border on focus only while the config has not set the color itself. AwesomeWM never recolors it.

**xdg popups draw above the client's tiled neighbours.** A popup wider than its client is no longer covered by the next tile.

**`client._scene_layer`** returns the name of the layer a client draws in. It is a test aid, not AwesomeWM API.

---

## Bars and the Workarea (somewm 2.1)

The output is a column: the top bars, then the left bars, the workarea and the right bars in a row, then the bottom bars. Clay solves it, and `screen.workarea` is the box the workarea element solved to. Nothing computes a bar's position or a strut.

- **A wibar is laid out by the compositor at its edge.** `awful.wibar` no longer places itself with `awful.placement`; it tells the drawin its edge, margins, stretch and align (the drawin's `bar` property, somewm-only), and its geometry is what the frame solved. `wibar:geometry()` reads the same box as before, without the margins.
- **`screen.workarea` changes with the frame.** Creating, hiding or resizing a bar changes the workarea at the next frame, and `property::workarea` fires then. AwesomeWM changed it synchronously.
- **Margins are the bar's padding.** A margin rounds to whole pixels.
- **Bars on one edge stack in the order they became visible.** AwesomeWM kept its own list and moved a bar whose `position` changed to the inside. Hiding and showing a bar moves it to the inside here.
- **`beautiful.wibar_favor_vertical` is gone.** Horizontal bars always span the output; vertical bars sit between them.
- **An `ontop` wibar reserves no space.** It floats over the output at its edge in the `ontop` wibar band. AwesomeWM kept the workarea clear under it.
- **A wibar draws no shadow.** A bar in flow has no band to put one under. Its drawin border is also not painted (confirmed by checkpoint pixels); a widget may paint its own border.
- **`restrict_workarea = false`** floats the bar at its edge, in the band of a wibox placed by its geometry.
- **Struts are ignored.** `drawin:struts()` and `client:struts()` store what they are given and emit `property::struts`, and nothing reads it. `awful.placement`'s `update_workarea` option does nothing. A wibox reserves space only as an `awful.wibar`.
- **A layer-shell surface with an exclusive zone is a bar in flow.** It reserves its zone plus its margin at its edge, ahead of the wibars, as wlroots arranged it. Any other layer surface floats over the workarea from its anchors and margins, or over the whole output for a zone of -1. Its configure carries the size the frame solved, one frame after its initial commit.
- **An output-sized wallpaper fill belongs to OUTPUT.** A color or image contribution with equal-area wrappers binds its original widget identities to OUTPUT, without a wallpaper float. The renderer places OUTPUT's color then its untinted image beneath every root, including negative-band desktop objects. The color remains visible through transparent image pixels and filtered edges. Other image declarations retain their tint semantics. A wallpaper widget tree, including a gradient or an image needing its own aspect-sized allocation, remains a float at band -4. Borders, shapes, opacity, multiple desktop drawins, intervening desktop/background surfaces and incompatible image layers retain their paint boundaries. No gradient rasterization changes. The bundled gradient/logo desktop keeps one flow root and two floats: wallpaper and centered clock.
- **Screenshot ownership is preserved.** `root.content(true)` skips the root wallpaper image on OUTPUT, and still includes `awful.wallpaper` contributions and the root color. `screen.content` includes both. Moving the fill does not change these APIs.

---

## Widgets Are Clay Descriptions (somewm 2.1)

A widget is a description of a Clay subtree, and nothing else draws. A drawable's widget tree is compiled to Clay declarations from the root down, Clay solves every box, and the renderer draws every element into the scene: rectangles, borders, text, images and the shape leaves that carry vector art (a piechart, an arc, a separator's shape, a gradient fill). Every stock widget class carries a describer that says what it is in Clay terms, and every stock class's `:draw`, `:fit` and `:layout` code is gone, together with `wibox.hierarchy`, the layout engine behind them. Widget properties and signals are unchanged, and so is what a wibar looks like, with the exceptions below.

**Repeated widgets retain each placement.** Lookups and pointer events return the original Lua object with the area of the matching occurrence, including when an object appears on several outputs. Inserting an unrelated sibling no longer changes its widget element IDs. `emit_signal_recursive` follows every original upward placement path, as documented; the previous converter's single-parent table lost all but the last path. No `rc.lua` syntax changes.

**Attachments preserve the selected occurrence.** `move_next_to` keeps a widget hit's host and placement token. A programmatic widget target uses its hovered placement, or resolves a unique visible placement within an explicitly supplied host or across the compiled hosts. A plain widget reference continues following that widget when its host rebuilds its parent layout. Ambiguous targets report an error and require a widget hit; they do not select the first copy. Removing an explicitly selected occurrence leaves the attachment absent until a new target is supplied.

**Compatible widget declarations share real elements.** A background and its inner padding container can occupy the same solved element while retaining both original Lua objects for lookup, input and attachment targets. Padding outside a painted child, conflicting paint, sizing limits, clipping and floating placement retain separate elements where their areas differ. The same local checks apply to supported ad-hoc describers. Original occurrence bindings share cached list tails; the inspector shows the actual element tree.

**A textbox is a container with a text child.** The container carries the widget's ID, FIT/GROW sizing and child alignment from `halign` and `valign`. Original Lua objects use that allocated area for lookup, input and attachments, including space outside the glyphs. Its anonymous pinned Clay text child has no bindings or attachments and publishes no box. Built-in textboxes and supported ad-hoc descriptions use the same representation.

**A widget that draws itself is left out, loudly.** A widget that defines `draw`, `fit`, `layout`, `before_draw_children` or `after_draw_children`, on its class or on the instance, or whose class has no describer, is refused: one warning per class names the class and the methods it defines, and the widget's whole subtree is left out of the tree. The bar keeps drawing around the hole. A custom widget is written as a describer now: `widget._clay = { describe = function(w, fg, st) ... end }`, returning the node table `wibox.clay` documents, and `wibox.widget.base.make_widget(template)` gives a template widget a describer that passes through to the template. The stock classes that never had a describer are refused the same way: `wibox.container.rotate`, `wibox.container.mirror`, `wibox.container.tile` (Clay has no transforms and no tiling).

**Unsupported properties warn; some modes omit the widget.** Numeric spacing, padding and border widths are rounded and clamped to unsigned 16-bit values by `clay.pixels`. Imagebox clip shapes and scaling caps are ignored with warnings; non-auto fit policies use auto. Every SVG imagebox is refused, including SVGs with intrinsic or forced dimensions, because the describer requires a raster image surface. Rotate, mirror and tile containers have no describer and are omitted. Border containers refuse `honor_borders=false`, `ontop=false`, `border_merging`, `expand_corners`, `border_image_dpi` and unsupported SVG side images. Manual function-valued positions skip those children with a warning.

Textbox attributes outside the native text vocabulary are ignored with warnings: multiple markup runs become one run, unsupported attributes are not drawn, justify/indent/line spacing are ignored, and start/middle ellipsizing uses end. Unsupported solid-color properties become transparent; nonrectangular background shapes draw as their box. Margin `draw_empty=false`, progressbar ticks/bar borders, slider bar borders, systray extra rows, and systray hover/urgent/overlay styling are ignored with named warnings. None of these paths invokes a widget painter or rasterizes a widget subtree outside the renderer.

**Deleted API.** `wibox.hierarchy`, `wibox.widget.base.fit_widget`, `layout_widget`, `place_widget_at`, `place_widget_via_matrix` and `rect_to_device_geometry`, `wibox.widget.draw_to_cairo_context`, `draw_to_svg_file` and `draw_to_image_surface`, `wibox:to_widget` and `wibox:save_to_svg`, `wibox.drawable.surface` and `drawable:refresh()`. A widget is never handed a cairo context, so there is nothing for them to draw with; a picture of a widget comes from `root.content()` or `screen.content` while it is on screen.

**visible and opacity.** A widget with `visible = false` is left out of the tree, silently. A widget `opacity` multiplies the alpha of every solid color and gradient stop in its subtree; images are unchanged.

**A translucent drawin blends per node.** A drawin `opacity` below 1 applies to every element the drawin draws, not once to the drawin as a layer, so where two fills overlap they compound: a bar at 0.5 holding a background container of the same color shows as 0.75.

**A shaped drawin is a rounded rectangle or nothing.** A `shape` that draws a rounded rectangle, with or without a `border_width`, becomes the corner radius of the drawin's own background, with its border ring painted separately at the same host radius; any other shape is drawn unshaped, with a warning naming the drawin, since the masks used to cut the drawin's own pixels and there are none. `shape_input` masks are ignored with a warning: input follows the box, rounded by the shape; `wibox.input_passthrough` still passes everything through (and now works, where the 0x0 mask it sets was dropped before).

**A tree the output cannot hold shows nothing.** A drawin whose tree is past the output's element budget (`WIDGET_NODES_OUTPUT_MAX` in widget.h, shared by every drawin on the output) or malformed shows nothing, with a warning once, until the tree changes; `somewm-client clay tree` lists it with the reason.

**Gradients are shape-leaf fills.** A linear or radial gradient (`gears.color`'s table or string forms, up to 16 stops) on a `background` container, a drawable's own `bg`, or an `awful.wallpaper` `bg` is rasterised by the renderer as the fill of a rectangle holding the widget; rounded background fills retain their radius, and native border declarations paint the border separately.

**awful.wallpaper is a desktop wibox.** Each wallpaper owns one wibox of type desktop at its panning area, below every client, passing input through, holding its widget in the same background container as before. Screen areas its panning area does not cover show the plain root wallpaper (`gears.wallpaper`); `uncovered_areas_color` and `dpi` are gone (a value set is stored and ignored), and a tiled wallpaper (`wibox.container.tile`) is gone with the tile container.

**A transparent wibox converts.** A drawable whose own background is a transparent color (an `awful.tooltip`, a popup that draws its background in a container inside) is a root that draws nothing and still takes pointer input over its whole box, as a wibox does.

**Attachment hosts share equal areas.** An undecorated popup, tooltip, launcher or notification owns its drawable contribution directly. Borders use Clay border paint at the solved size, including rounded borders and first open. Border width alone reserves padding; a shadow is a floating first child that never sizes its owner. Original widget objects, content areas, border input passthrough and drawin opacity behavior are preserved.

Content-sized drawable roots use the same contribution rules as widget parents. Fully transparent solid colors contribute no paint, matching the renderer; visible nested paint, definite sizing and incompatible bounds retain their real elements. Original widget bindings and cached children survive changes between combined and separate representations.

An image can carry its original widget bindings when both declared axes guarantee the same area. A larger minimum, independent growing allocation, padding or paint keeps a real container, including input in the unpainted area beside an image. This applies equally to built-in imageboxes and supported ad-hoc image declarations. Image sizing uses natural source dimensions and authored compiler offers, including flex shares; it does not read a previous host rectangle.

**A rounded background cuts its children to the arc.** A `background` whose shape is a rounded rectangle holds whatever it holds, filled or not, and the renderer clips every node under it to the shape's box and arc, as the container's own cairo clip did. Rounded clipping is a renderer scope. Rectangular hosts also cut pixels through renderer scopes. Clay has 100 shared clip records per output: authored widget and client scrolling takes priority, then definite hosts receive the remainder in declaration order. A host beyond that budget still cuts pixels at its edge, but overflowing content compresses toward its authored minimum instead of retaining its natural size. A named warning identifies the first affected host on each output. A `background` border's straight edges are the one thing not cut: a bordered widget touching a rounded corner shows its edge past the arc.

**A popup's tree sizes its drawin.** An `awful.popup` sizes itself to its widget: the drawin's root element wraps the tree (`CLAY_SIZING_FIT`) within the popup's `minimum_width`, `maximum_width`, `minimum_height` and `maximum_height`, and the popup takes the box Clay solves, one frame after the tree changes. Geometry and draw-order reads expose the completed frame; they do not advance layout or run an isolated measurement.

**Image sizes are composed from authored constraints.** Imagebox, client icon and tray dimensions use their source size, forced sizes, scaling flags and the compiler offer after padding and flex sharing. Both fitted axes round outward in Lua. A content-sized host without an authored definite axis starts from natural image size. `resize=false` retains the natural dimensions, and `downscale=false` prevents shrinking below them; those images can overflow a smaller allocation. Other resizable images use paired FIT bounds for the composed size. This preferred size is not recomputed from sibling content inside the solver. Source replacement, original objects, occurrences and input delivery are unchanged. Image fit policies, clip shapes and maximum-scaling options retain their named warnings and ignored-property behavior. SVG imageboxes remain refused regardless of intrinsic size.

**Border containers declare native rows and cells.** Side widths, corner sizes and content padding come from authored values; remaining space is allocated by Clay in the same solve. Image crops use only source dimensions and border widths, and survive host resize without recropping. Changing borders, source images or source styles invalidates the corresponding input cache. Widget-only and separate-image borders need no source image. Sliced borders are bounded by the source even when some cells have widget/image overrides; opposing widths that consume the whole source are clamped to leave a nonempty center, and zero-width sides produce no images. With `slice=false`, authored border widths and padding inset content without being limited by the background image dimensions. `honor_borders=false`, `ontop=false`, `border_merging`, `expand_corners` and `border_image_dpi` still refuse the border by name. Non-fit policies still warn and render as fit; separate SVG border images remain refused. Grid sizing and general host folding are unchanged.

**A forced size is Clay's, where a parent asks for it.** `forced_width` and `forced_height` on a widget are its sizing: a `fixed` or `align` slot places the widget at that size, and a container that hands its child the whole box (`margin`, `background`) still gives it the whole box, counting the forced size as the least the box can be. An `imagebox` with one forced axis wraps its image on the other, where the engine kept the other axis from the offer.

**Told sizes do not shrink.** A widget of its own size (an imagebox, an icon) keeps it; a bar its content overflows compresses its text before its icons, where the engine squeezed everything in the order it laid out.

**Odd leftovers round differently.** The engine floored: `flex` handed out its leftover pixels one at a time from the left, `align` with `expand = "outside"` or `"none"` floored the half beside the middle widget, and `place` floored a centered child's offset. Clay solves in float and rounds at the boundary, so when the space to split is odd a box can sit one pixel to the right of, or one pixel wider than, where the engine put it. Sizes that divide evenly are identical.

**A slot that grows keeps content wider than its share.** The engine gave every `flex` child the same share whatever it held, and gave `align`'s expanded slots what the fixed ones left. Clay grows an element up from the size of its own content and never compresses it below that, so a slot whose content is already wider than its share keeps that width and the slots beside it get what is left. An `align` whose middle widget wants the whole length no longer drops the outer two; it places all three and the middle takes what they leave. A `ratio` layout under a parent that wraps its content has no size of its own.

**A tree wider than its drawin is cut, not squeezed.** The widget lays out at its own size, at least the drawin's, and the drawin's edge cuts what overflows, a text with its ellipsis there; only a `constraint` or a forced size squeezes what it holds. The engine gave every layout the drawin's box to divide.

**A fixed layout's spacing is between every pair of children.** Clay's `childGap` does not know a child's size. The engine skipped the spacing beside a child whose `:fit` was zero along the direction, and stopped placing children once one started past the edge; a `fixed` places every child with the spacing between each pair, and the drawin clips what overflows. A child that is not in the tree at all costs no spacing.

**A FIT stack sizes from its first participating child.** `wibox.layout.stack`
keeps that child in flow and declares later children as native floats, in
declaration order. Unlike AwesomeWM's maximum of all child sizes, only the
in-flow content (plus its spacing inset) sizes a FIT axis: a 100x20 first
child with a 40x60 overlay fits to 100x20. This removes the first child's
detached float and uses Clay's normal content sizing; floats never size a
parent. Hidden, refused and empty children are skipped when choosing the
content, including with `top_only`; a stack with no participating child
declares nothing, even if the stack has a forced size. Later offsets retain
their original declaration indices. The content's offset becomes a native
left/top inset, while later children attach to the full stack box.

**A widget with nothing to show is not in the tree.** An empty textbox, an imagebox with no image, an empty tasklist, a list item's unused icon slot: a widget that draws nothing, holds nothing and takes nothing along its parent's direction has no element, so it takes no space and no spacing beside it. It stays connected to its signals, so a text or an image declares its element again in the same place. A widget with a colour, a ring, a padding, a told size, a floor, or anything else Clay would act on keeps its element, however small it solves; a spacer is still a spacer.

**A systray icon that fills its square is its image.** An icon whose image is the same shape as its slot fills it exactly, so the image is the element and there is no container around it. An icon of a different shape, or one that may not be resized, keeps a container and is centred in it. Either way clicks, menus and tooltips reach the icon widget.

**A taglist, tasklist or layoutlist names the element it shares with its base layout.** The list and the layout inside it have the same box, so they are one element, named after the list. Both objects are still found there by `find_widgets` and both still receive its input.

**A textbox is laid out by Clay, and drawn by the renderer.** Clay measures the text through the renderer's Pango setup at the output's scale, with the font's size taken at the screen's dpi, and wraps by words: `wrap = "char"` and `"word_char"` wrap by words too, and a word wider than the box overflows it. Each line is a text command the renderer rasters; a line the box's clip cuts is ellipsized there when `ellipsize = "end"`, which is the default, so a title wider than the bar ends in an ellipsis at the bar's edge rather than at its slot. The text's own size is one line wide, so a layout that asks the textbox its size gets its unwrapped width, and wraps it only when something narrower holds it; a text Clay squeezes takes the width it was squeezed to, so a popup wrapping its message is as wide as its cap, where the widget measured the widest line. An empty textbox takes no size of its own.

**An imagebox is an image element with an aspect ratio.** The renderer shows the widget's own surface, scaled into the box Clay solved. A surface whose pixels change under the same object is drawn again only when something else in the tree changes.

**A margin's `color` draws above its child instead of below it.** The ring is the margin band, and the child is placed inside it, so the two do not overlap unless a widget draws outside its own box.

**Padded art pads all four sides.** A `radialprogressbar` pads its content by its border and padding on every side, where the engine's fit added only the left and top offsets. An `arcchart` centres an inner square composed in Lua from its authored offer after thickness, border and padding, and clips its real child to a circle. Its ring keeps the rectangular outer allocation. A `checkbox` paints a leading square inside its original allocated/input box; Lua supplies square bounds only for its FIT axes. With two definite axes the smaller offer supplies the side, with one definite axis that offer supplies it. Without either axis the widget is left out of the tree with a warning to force a size or put it in a sized host. Forced sizes remain authored inputs. Asymmetric arc padding is applied before choosing the inner square. These bounds do not follow later sibling allocation or text wrapping: an arcchart offered a 120px share in a 240x100 flex row beside a 160px sibling keeps its 90px inner square and 100px outer width, so the row overflows by 20px. An unforced checkbox in that row still takes the remaining 80px because both allocated axes are GROW. A forced height of 30px supplies a 30px FIT width even in a 100px-tall row. Unconstrained arc children no longer determine the inner square from measured text or child content; set a forced size when that content needs space.

**A border container's sides are told.** The engine carried a side's minimum from a resized image's aspect-scaled fit and placed sliced sides past the box; a `border`'s sides and corners are told sizes inside the box. Its paddings count whenever a widget is set, where the engine counted them only when the child had a size.

**A background image sits inside an inner border.** With `border_strategy = "inner"` a `background`'s `bgimage` is inside the border's padding, where the engine painted it over the whole box under the border; only a translucent border shows the difference.

**An overflow layout follows the previous solve.** Its scrollbar and offset are those of the last solve, one redraw behind, so the first frame after it converts shows the content unscrolled and without a bar. A content change that shows or hides the bar takes two frames, one to show the bar and one to size the thumb for the narrowed content. Clay places every child and cuts to the box, where the engine placed only the children in view. The bridge admits at most 100 widget scroll containers per output (`WIDGET_SCROLLS_OUTPUT_MAX`). Client layout scrolling shares those 100 native records; an open inspector reserves three records for its main pane and alternative details panes. A combined scrolling declaration beyond the budget retains the previous scene; an inspector that would exceed it is closed before declaration. Exceeding widget admission refuses the additional tree.

**A scroll container uses Clay's scroll record.** `wibox.container.scroll` writes its position at `fps`, and Clay clamps the record to the content bounds. While scrolling, the child is declared twice with `extra_space` between the copies, so a wrapping step function has no seam. A child that has just become too long is initially clipped at zero and starts scrolling on the following tick. A child that fits has one copy at zero and stops the ticker. `pause` stops the ticker, `continue` re-arms it, and `reset_scrolling` writes the record to zero without undoing a pause.

A step function is supported when its five arguments (`elapsed`, `size`, `visible_size`, `speed`, `extra_space`) produce an offset between zero and `size + extra_space`, as every function in `scroll.step_functions` does. An offset outside that range is clamped by Clay's content bounds instead of drawn out of range. `expand` is accepted but no longer lays the child out over the extra space: Clay cannot size a child to its own extent plus a constant, so the extra space is always empty. Mouse events reach the widgets inside the container, with a click delivered to whichever copy is under it; the drawing-only container swallowed those events.

**Large widget layouts have bounded capacity.** Each output owns a fixed 65536-element Clay context. A tree may contain at most 2048 native widget nodes, with 12288 admitted per output. Clients, decorations, layout slots, inspector rows and retained transitions also consume native capacity, so admission alone cannot guarantee a solve. Clay's separate transition table holds 200 records. Widget and inspector budgets leave room for pinned Clay's exit-subtree copies; the solver does not reserve their arena-tail slots from new declarations. A full ID map can reject even an existing ID before searching for reusable slots, triggering the same recovery as a new-ID overflow. If capacity is exhausted, the last successful scene and public widget geometry remain in use, but the same arena is reinitialized: native scroll offsets, transitions and the text measurement cache reset. A scroll query has no record until its container is declared again, starting at zero; old exit transitions do not resume. The next valid frame measures its text again. An open inspector closes and permits one retry; otherwise recovery waits for changed input. Private grid measurements publish neither tentative geometry nor public solved callbacks. The arena stays at its original address and size throughout normal operation.

The inspector declares the complete expanded tree. Before its traversal, SomeWM reserves 18 times the authored element count plus 2048 elements, and 20 times that count plus 2048 temporary string bytes, including live ID-map headroom. A tree exceeding either budget is refused by name with one warning, completing the authored frame without the debug view and closing the inspector. Refusal does not reset the context or scroll offsets; the next frame removes the panel space reserved during declaration. This can refuse a tree whose actual collapsed inspector would fit. The full inspector can be substantially slower than a viewport-sized widget list. Its generated ID collisions are reported once per output and left to Clay's debug collision handling; application-authored duplicate IDs remain fatal.

**A grid declares shared tracks measured from its original content.** `wibox.layout.grid` and month/year calendars use `_grid_constructor.lua`. Natural and native-minimum requirements shrink or grow after content, font, visibility and membership changes. Row/column operations invalidate the declarations, including removal of the last covered track of a span. Grids with no logical tracks or borders use ordinary empty declarations: an unallocated empty grid has no native element or pointer target, while authored forced allocations and later child restoration remain available. Homogeneous sizing, proportional expansion, authored minima, spans and integer floor/trailing-remainder allocation use ordinary Clay rows and cells. Wrapping and nested heights can require additional solves; the output completes those dependency stages before presenting geometry, pixels and pointer targets.

**`find_widgets` asks Clay which widgets are under a point.** The widgets under a point are the elements Clay's own pointer query names against the output's last solve, in the tree's order: parents before children, a stack's children bottom to top. A result carries `.widget`, `.drawable` and Clay's box as `.x`, `.y`, `.width` and `.height`; the `.hierarchy` field is gone with `wibox.hierarchy`. During the window between a failed frame and its retry, `declare_widget_hits` returns zero hits.

**Root wallpaper selects the shared source in the renderer.** Each output uses the layout-sized surface painted by `root._wallpaper` as OUTPUT's image, which the renderer paints beneath every root. Its layout origin selects the source pixels; the renderer alone creates the output-sized raster at the output's scale. Moving or resizing an output selects its new rectangle on the next frame. Growing the layout beyond the existing source leaves a transparent edge until another wallpaper call paints a new source, as before.

**Screenshots read the scene and nothing else.** `root.content()` and `screen.content` walk the scene for rectangles as well as buffers, so a container's background is in the capture. `root.content(true)` leaves the root wallpaper image on OUTPUT out, and a translucent drawin captures at its opacity. The scene walk also replaced `screen.content`'s own buffer pass, which ignored a scene buffer's destination size and scaled HiDPI captures wrong.

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

Location: `lua/awful/client/shape.lua`

AwesomeWM uses the X11 Shape Extension (`xcb_shape_mask()`) to apply non-rectangular window shapes (e.g. rounded corners via `gears.shape.rounded_rect`). Wayland has no equivalent protocol-level feature. The `awful.client.shape.update.*` functions are no-ops so that user configs referencing `client.shape_bounding` or `client.shape_clip` load without error.

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

The global APIs (`luaA_register_xproperty()`, `luaA_set_xproperty()`, `luaA_get_xproperty()` in `property.c`) remain stubs. The per-client methods (`luaA_client_get_xproperty()`, `luaA_client_set_xproperty()` in `objects/client.c`) use a client-owned store of named booleans, numbers and strings; nil removes an entry. This store survives Lua hot reloads and is freed with the client, without reading or writing X11 properties.

X11 properties were used for:
- Storing persistent per-window state
- Inter-client communication
- Session management

Wayland alternatives (not yet implemented):
- D-Bus for IPC

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
| `wibox/init.lua` | ARGB32 shape masks (AwesomeWM uses A1), HiDPI scaling, surface lifetime | Wayland scene graph and compositing model; ARGB32 gives anti-aliased edges on curved shapes. The rendering path accepts either format, so a config may still assign A1 masks. |
| `wibox/drawable.lua` | HiDPI scale-change handler | Recreates surfaces when `screen.scale` changes |
| `awful/client.lua` | `c.type or "normal"` fallback | Native Wayland clients may not set window type |
| `awful/permissions/init.lua` | Layer surface keyboard focus handlers | Wayland layer-shell has no X11 equivalent |
| `awful/mouse/snap.lua` | ARGB32 shapes, surface lifetime | Same Wayland surface patterns as `wibox/init.lua` |
| `gears/filesystem.lua` | `somewm/` paths | Rebranded config/cache directories |
| `naughty/dbus.lua` | `awesome.version or "somewm-dev"` fallback | Version string safety |

### Removed APIs

| API | Replacement | Reason |
|-----|-------------|--------|
| `_timer` | `gears.timer` | An undocumented C wrapper around `wl_event_loop_add_timer` with no callers in the tree. Its timers were never removed on a hot-reload, so each one outlived the Lua state that owned it. `gears.timer` is GLib-based and unaffected. |
| `_key` | `awful.key` | An undocumented C module (`_key.bind`, `_key.get_all`) with no callers in the tree. Nothing read back the function it stored, so a binding made through it could never fire, and the array it kept grew by a duplicate set per hot-reload. Real keybindings go through `awful.key` and the `key` object, which are untouched. |
| `<class>.add_signal` and `gears.object.add_signal` | none needed | Signals have not needed declaring since AwesomeWM 4. The C version was a no-op generated onto every class (`client`, `screen`, `tag`, `drawin`, `key`, `button`, `output`, `layer_surface`), the Lua one only printed a deprecation. Neither had a caller. Calling either now errors instead of doing nothing. |
| the `.data` property on capi objects | `._private` | An alias that warned and then returned the same table `._private` returns. No caller in the tree. `._private` is unchanged. |
| `awful.ipc.remove_subscriber` | none needed | Nothing ever called it, so the subscriber count it maintained only grew and the broadcast fast path stayed permanently on. C tracks subscriber fds itself now (`_ipc_has_subscribers`). |
| `gears.wallpaper` | `awful.wallpaper` | Deprecated upstream; somewmrc already uses `awful.wallpaper`. Removing it also deletes the somewm-side machinery that existed only to serve it: the `require()` hook that recorded wallpaper globals and the per-screen wallpaper cache in `root.c` (`root.wallpaper_cache_show`/`_has`/`_clear`/`_preload`), which `awful.wallpaper` never populated. An rc.lua calling `gears.wallpaper.*` errors. release/1.4 keeps it, matching AwesomeWM master. |
| `awesome.api_level` | none | 2.0 is a hard reset and does not promise behavior across versions, so there is nothing for a config to select. Reading it now returns `nil`, so an rc.lua that compares it to a number errors. Three library behaviors that used to branch on it are now fixed at what level 4 did: `awful.autofocus` loads without a warning, `awful.permissions` does not wire `mouse::enter` to `request::autoactivate` (rc.lua does that), and `wibox.widget.base.make_widget` still defaults `enable_properties` to `false`. |
| `gears.debug.deprecate_class` | none | Existed only to proxy a class that moved between API levels. No callers in the tree. |
| `_wibox` | `wibox` | An undocumented C module that put a layer-shell surface on screen and showed a buffer Lua drew into it, from before drawins rendered through the scene. No callers in the tree. |
| `awesome.systray` | `wibox.widget.systray` | The X11 tray's C entry point, kept as a host that painted StatusNotifierItem icons into a wibox's pixels. Nothing in the tree called it: the systray widget draws every icon itself, and a wibox hosting it could not convert to Clay. Calling it now errors with a nil field. |
| `awful.util` | `gears.*` | 34 of its 38 functions already redirected to `gears.*` with a deprecation warning, so those move to the function that warning named (`awful.util.table.join` is `gears.table.join`, `awful.util.get_cache_dir` is `gears.filesystem.get_cache_dir`, and so on). Most are a straight module swap; the six that need more are listed under the table. The remaining four had no `gears` equivalent: `checkfile` was inlined into its only consumer, and `eval`, `restart` and `geticonpath` are gone, as is the `shell` field. An rc.lua touching any `awful.util` field errors, since the module itself no longer exists. |

The `awful.util` redirects whose `gears` name differs, plus the two whose
target is gone in 2.0 as well:

| Old | Use instead |
|-----|-------------|
| `awful.util.escape` / `.unescape` | `gears.string.xml_escape` / `xml_unescape` |
| `awful.util.mkdir` | `gears.filesystem.make_directories` |
| `awful.util.get_rectangle_in_direction` | `gears.geometry.rectangle.get_in_direction` |
| `awful.util.getdir("config"/"cache")` | `gears.filesystem.get_xdg_config_home() .. "somewm/"` / `gears.filesystem.get_cache_dir()` |
| `awful.util.deprecate_class` | nothing, `gears.debug.deprecate_class` is gone too |

AwesomeWM's stock `rc.lua` uses `awful.util.eval` for its "run Lua code" prompt.
There is no replacement to call, so inline it:

```lua
exe_callback = function(s) return assert((loadstring or load)(s))() end,
```

`gears.debug.deprecate` stays, minus its `args.deprecated_in` option: it now always prints the warning. It no longer emits `debug::deprecation`, which had no listener anywhere, and no longer routes deprecations into `debug::error`. `debug::error` itself is unchanged and still carries real Lua errors. At level 4 a deprecation could reach neither signal, so nothing observable changed.

### Removed deprecated aliases

With no API level to gate them, the aliases that carried a `deprecated_in`
version gate are gone, along with the ones AwesomeWM had already reduced to
documentation. Each had a working replacement and no caller in the tree.

| Removed | Use instead |
|---------|-------------|
| `awful.screen.getdistance_sq(s, x, y)` | `s:get_square_distance(x, y)` |
| `awful.screen.padding(s, p)` | the `screen.padding` property |
| `awful.mouse.client.dragtotag.border(c)` | set `awful.mouse.snap.drag_to_tag_enabled`, then `awful.mouse.client.move(c)` |
| `awful.mouse.client.corner(c, corner)` | `awful.placement.closest_corner` |
| `awful.mouse.client_under_pointer()` | `mouse.current_client` |
| `awful.key.execute(mod, k)` | `awful.keyboard.emulate_key_combination(mod, k)` |
| `menubar.get(s)` and calling `menubar(s)` | `menubar.refresh(s)` |
| `beautiful.theme_assets.recolor_titlebar_normal/_focus(t, c)` | `beautiful.theme_assets.recolor_titlebar(t, c, "normal"/"focus")` |
| `gears.filesystem.mkdir(dir)` | `gears.filesystem.make_directories(dir)` |
| `gears.filesystem.get_dir("config"/"cache")` | `gears.filesystem.get_xdg_config_home() .. "somewm/"` / `gears.filesystem.get_cache_dir()` |
| `wibox.layout.ratio:ajust_ratio` / `:ajust_widget_ratio` | `:adjust_ratio` / `:adjust_widget_ratio` (the spelling was a typo) |
| `wibox.layout.grid:get_dimension()` | the `row_count` and `column_count` properties |
| `naughty.notification.run` and `.destroy` properties | the `invoked` and `destroyed` signals |
| the client `marked` and `unmarked` signals | `property::marked` |
| the textbox `property::align` signal | `property::halign` |
| `naughty.notificationClosedReason` | `naughty.notification_closed_reason` |
| `notification_closed_reason.dismissedByUser` / `.dismissedByCommand` | `.dismissed_by_user` / `.dismissed_by_command` |

`naughty.notification.run` and `.destroy` were already inert: nothing read them
once the legacy notification layout was dropped, so setting them did nothing
before this change either.

The two camelCase notification-reason spellings were undocumented aliases of the
snake_case ones and had no caller in the tree. The snake_case names are unchanged.

`naughty.notify` itself is gone. It has no implementation and the `naughty`
index handler returns `nil` for it, so calling it errors. Construct notifications
with `naughty.notification { message = ... }`. The constructor still accepts
`text` and maps it to `message`, so `naughty.notification { text = ... }` works.

A further set of `@deprecatedproperty` entries documented names that had no
getter or setter behind them: the ten directional `wibox.layout.grid`
properties (`forced_num_rows`, `min_cols_size`, `horizontal_spacing`, and so
on), the old background border aliases,
`naughty.notification.text`, and `wibox.widget.textbox.align`. Assigning to any
of them was already a silent no-op. Only the documentation was removed. The
`text` entry covers the property only; the constructor argument of the same name
still works, as above.

Some `@deprecated` entries were left in place because they are not aliases.
`beautiful.xresources.get_dpi` is the only way to read the DPI without a
screen; `wibox.container.background.bgimage` draws `beautiful.taglist_squares_*`
and the tasklist background images; `wibox.layout.grid:add_widget_at` is the
method the grid uses internally; and `menubar.icon_theme` / `menubar.index_theme`
mark their whole API deprecated while `wibox.widget.systray_icon` depends on it.

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
awful.input.xkb_model = "pc105"
awful.input.xkb_rules = "evdev"
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

### Shadows

Compositor-level drop shadows for clients and wiboxes (no AwesomeWM
equivalent; under X11 this is picom's job). Configured through
`beautiful.shadow_*`, per-object via `client.shadow` / wibox `shadow`.

The shadow is the object's frame grown by `spread`, moved by
`offset_x`/`offset_y`, rounded by `corner_radius`, fading out over
`radius` pixels. `color` accepts `#RRGGBBAA`; its alpha multiplies
`opacity`.

Changed in 2.1: `clip_directional` no longer has an effect. The shadow is
drawn at its offset and fades out on every side; sides fully covered by
the window are simply not visible. Configs that set it still parse.

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

`awful.layout.suit.carousel` and its vertical variant declare a native Clay tree.
Reconciled client membership forms fixed-fraction columns with equal percentage
client slots, gap padding and twice-gap separation. The workarea padding contains
a clipped viewport and one FIT strip. Peek and centring room are margin slots;
Clay solves client boxes, centres short strips and clamps scrolling. Surface
protocol minima do not change column fractions.

The strip position is Clay's scroll record. Switching tags starts it at 0 because
Clay drops undeclared records. Focus-follow reads solved column boxes and requests
at most one more solve. Gestures pan the record and centre the nearest column on
release. A wheel over a client does not pan the strip.
`carousel.get().position` reports the strip's scroll position without the dynamic peek adjustment applied by the old geometry writer.

`carousel.scroll_duration` is accepted and ignored. Scrolling animates client
slots through `somewm.layout_animation` when enabled and snaps when disabled.
No Lua or C compositor path interpolates a client box; Clay owns those transitions.
`awesome.start_animation` remains a public frame-synced tick source with easing
and cancellable handles for animating things other than client boxes.
`client:_set_geometry_silent(geo)` remains available, but carousel does not call it.

`carousel._build_declarations(inputs)` accepts reconciled `columns`, `vertical`,
`viewport_extent`, `gap`, `peek`, `lead` and `trail`. The fraction basis is
`max(1, viewport_extent - 2 * peek)`, where the viewport excludes workarea padding.
Non-client slots publish solved IDs, boxes and scroll records before the root's
`solved` callback. `carousel._native` implements target selection, follow, pan and
nearest-column selection against those results.

### `somewm.*` - SomeWM-Only Lua Namespace

Lazy-loaded namespace for somewm-specific Lua modules that have no AwesomeWM equivalent. Submodules live under `lua/somewm/` and are loaded on first access via `require("somewm")`.

### `somewm.layout_animation` - Animated Layout Transitions

Animates tiled clients from their previous geometry to the new one. Covers all arrange triggers: mwfact changes, client spawn/kill, layout switches, column count changes.

```lua
local layout_anim = require("somewm.layout_animation")
layout_anim.duration = 0.15          -- seconds
layout_anim.easing   = "ease-out-cubic"
layout_anim.enabled  = true           -- default
```

Animation is skipped when disabled, during mousegrabber (direct manipulation), or on a client's first arrange. See "Layout animation runs in Clay" for what drives it.

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

### Client layout declarations (2.1)

Tile, tile.left, tile.top and tile.bottom declare clients in the Clay
workarea. Each client is a column of titlebars and its surface; side titlebars
add a body row. Client borders are padding. Protocol min/max hints constrain
the surface, so a surface minimum wider than its percent slot overhangs the
slot; the configure carries that solved surface size.

A client minimum wider than the whole workarea can widen WORKAREA under tile, which does not use size containment; fair, corner and carousel with percent cells follow the same behavior.

`useless_gap = g` now means **g** at each workarea edge and **g** between
clients, instead of AwesomeWM's **2g** between clients. With one client,
`gap_single_client = false` declares no gap or padding. Mouse resize changes
`master_width_factor`; per-client window factors no longer resize tile rows.

**Authored zero client shares remain zero percentages.** A missing share still means GROW. At `master_width_factor = 0`, tile/corner master allocations and magnifier's centered allocation can have zero area, instead of being accidentally replaced with GROW. Their original client/surface declarations remain in the tree; empty realized nodes are disabled and do not receive pointer input. The existing client geometry getter keeps its1px minimum, and the protocol path skips zero-area configures, retaining the last positive client buffer size until a positive allocation returns. Native zero areas are not replaced by the old corner/magnifier writer's1px painted fallback.

**Spiral and dwindle declare native client layouts.** Their alternating split directions, spiral ordering, first fraction `(master_width_factor + 0.5) / 2`, client order and per-client gap insets are preserved. Real row/column groups and percentage allocations replace their Lua rectangle writers. With a nonzero gap, a real cell carries the inset without changing the parent split fraction; zero-gap cells share the client element. Geometry queries remain reads of the completed solve. Native percentage rounding applies to fractional coordinates, as for the existing native tile layout. A protocol-minimum surface can overhang its unchanged percent slot. In that overlap, paint and input follow native declaration order, as in tile; the later client covers the earlier one, whereas the former derived floats used their stacking order.

**Max and fullscreen layouts use native attachments.** Max clients grow to WORKAREA; fullscreen-layout clients grow to OUTPUT. These are layout choices, so client borders and titlebars remain, unlike the fullscreen client state. Native floating roots are declared in existing stacking order, preserving raise/lower, inherited transients and band precedence. When `gap_single_client` is true, the existing per-client gap is a real attached cell with padding; false suppresses the gap for both layouts, matching their `skip_gap` policy. The old max rectangle writer is removed.

**Magnifier uses a native centered attachment for its focused client.** Its width/height shares remain the square root of `master_width_factor`; background clients retain their cyclic order after the focused client in the native workarea column. Gap insets remain real cells. The focused surface retains protocol minima without enlarging its allocation. The old geometry writer is removed; the mouse resize handler still changes the authored factor.

**Fair retains its existing column-first client positions.** The horizontal variant transposes the same groups, including the partially filled final group. Native percentage allocation is fractional, and the bridge rounds slot edges so cells tile with no gap or overlap; the odd pixel of a split that does not divide evenly lands where edge rounding puts it, so 1280 three ways is 427, 426, 427 where 2.0 gave 427, 427, 426. Fair rows take equal percentages of the workarea, and each client takes an equal percentage based on the actual number of clients in its row; a singleton fills its column. Full axes use percent(1). Protocol SURFACE minima may overhang these cells. Per-client gap insets remain real cells. In overlapping minimum-size surfaces, paint and input follow native flow declaration order, as for tile and spiral.

**Corner uses native row/column groups in all four orientations.** Alternating column/row client membership, master fraction, privilege policy and per-client gap insets remain. The master fraction and its complement size the two regions, and each group divides its actual children by percentage. Full axes use percent(1). Protocol minima can overhang the cells; overhang paint/input follow native flow order. Two-client row privilege uses a master row and slave row. A single non-expanded master centers in every orientation.

All tiled layouts declare native client slots without computed client boxes.
Floating geometry is a user input, fullscreen grows to OUTPUT at band 40, and
raise changes declaration order within a band.

Shadows in 2.1 are one native `SHADOW` custom command per owner. The dump
prints GROW sizing, `theme` or `user` provenance, `attach PARENT`, authored
`offset`, nonzero `expand`, and `band`. The renderer paints shared corner and
edge tiles plus interior rectangles from the current owner box plus authored
spread, radius and offset. The lower-band SHADOW box from Clay is not a
placement input; its dump record reports the renderer's box. Resizing never
allocates a full-window shadow image. Plain drawin borders also use native
Clay borders. Drawin opacity still affects content only.

A floating owner puts its shadow one band below itself; an in-flow client or
notification puts it at band -1, above the background and below the main root.
A shadow falls on everything below its owner's band, never on a lower window
in the same band. This differs from 2.0 and the former derived shadow leaves,
which could shadow a lower floating window in the same band. Tiled clients
now have shadows again, visible in gaps without painting over neighbouring
surfaces. The default offset (-15,-15) exceeds the 12px falloff on the right
and bottom, so those sides remain covered by the owner's frame.

### Canonical host contributions

Bars, titlebars, popups, tooltips, notifications and launchers use the same declaration-based contribution folding for built-in and equivalent custom widgets. Compatible host/layout/paint contributions share an element while immutable binding chains preserve every original occurrence and local input area. Empty zero-area FIT paint contributes no command. An opaque rectangular child can cover a plain equal-area background; translucent content, host opacity below one, rounded masks, borders, padding and authored allocation bounds retain their required layers. Changing drawin opacity across one invalidates the fold cache.

Decorated attachment and notification hosts share one declaration path. An inner renderer clip scope under the host cuts the content to the padded box, while the border and shadow keep their own areas and paint metadata. With a native clip record, that inner element uses GROW sizing; without one, authored 100% sizing keeps its box inside the padded parent while its children compress. Rounded content retains its mask boundary. Anonymous vertical host slots inherit their authored direction. Protocol surface sizing keeps its protocol provenance.

A content-sized parent preserves authored fixed children. A textbox is a container with a text child, including in content-sized rows; the container retains its allocation and alignment. Intrinsic images keep distinct widget allocation boundaries where an aspect image can paint less than its original input area, including short hosts, sibling text, caps and forced dimensions. Genuinely fixed systray slots remain fixed and carry producer/theme sizing provenance. No prior image dimensions or runtime geometry decide a fold. Grid declarations and native scrolling state use separate paths.

### Grid spans and measurement dependencies

The `lua/wibox/layout/_grid_constructor.lua` helper declares spanning
cells: a column span includes its internal gaps, and a row span extends from its
first row through the
shared row heights. Covered cells and intentional holes retain layout space without
extra widget bindings. Clay computes every box and position. `lua/wibox/layout/grid.lua` uses this helper for every public grid, including
month and year calendar compositions.

Wrapping uses the real content in successive natural-width, native-minimum-width,
allocated-width/FIT-height and final allocation declarations. The minimum probe uses
a positive one-pixel cell offer (Clay treats a zero maximum as unbounded). Its boxes
are not retained as preferred requirements or available host space. Nested helpers
wait for descendant measurement, suppress expansion during ancestor measurement,
and distinguish a new height dependency from expansion of an already measured
height. Content/font/membership changes discard requirements; width changes remeasure
wrapped heights. Stable helpers stop requesting updates. There is no production
iteration cap. Pending dependency stages complete inside the output frame before
reconciliation, so intermediate probe and height declarations are not presented.

The bridge supports 2048 nodes per drawable. The aggregate output budget is 12288
within a 65536-element Clay context, allowing a borderless twelve-month calendar's
widget tree to fit without a separate measurement tree. Uniform solid borders
use padded cells with native border/fill commands, so a twelve-month calendar
with week numbers, spacing 3 and `border_width=1` also fits. Distinct solid inner/outer
colors use nested cell padding and fit as well. Gradients and custom strokes
retain separate clipped segments; sufficiently
large styled grids can still exceed the same budget and are refused.

### Grid border segments

The shared sizing helper reserves each authored boundary's border width plus spacing
in ordinary Clay declarations. Variable gaps participate in shared-track minima,
span extents and available-size calculations. For equal solid inner/outer colors
without custom boundary overrides, padding on real cells reserves these gaps;
native borders paint the leading strokes and final outside edges. Holes use native
fills. A spanning cell owns its entire border envelope, while continuation slots
reserve space without repainting it. This retains native rectangle rounding at
fractional output scales and adds no anonymous segment tree.

For distinct solid colors, a cell touching an outside edge adds an outer-color
envelope only when it also contains an inner-color stroke or hole fill. The outer
padding is subtracted from the inner envelope, preserving the content allocation.
The two painted regions do not overlap, including translucent colors and hidden
anchors. Paint stays local to the original cell's command order. Mutable color
arrays belong to each declaration so compiler opacity cannot compound across cells.

Gradients and custom stroke paths use anonymous segment containers
in the real grid subtree. The existing renderer consumes their commands in traversal
order. Shape callbacks rasterize only their own solved segment box, never cells or
a second layout. Borderless grids use shared tracks without border segments.

Logical occupancy masks suppress segments through row/column spans and their
spacing. Hidden content releases its mask; holes retain the documented default
border fill. Row/column overrides support zero and nil fallback, distinct
inner/outer colors, dashes/offsets and butt/round/square caps. Custom row strokes
precede custom column strokes. Original widgets and their occurrence bindings
remain the only widget input targets. Native border edges and corner buffers are
created only when they have an area to draw. A new border is populated before its
scene tree is enabled; a retired border is hidden once before its children are
released. Existing clipping, opacity, rectangle rounding and corner raster rules
still determine their pixels.

When border command membership changes, native reconciliation can temporarily
hide its owned scene subtree while updating, retiring and restacking the same
nodes. Both command generations must contain only rectangles, borders, text and
scissors. Borrowed trees and callback-bearing commands prevent this batch, as do
buffer output/frame listeners in any enabled branch of the scene and destruction
or buffer listeners on any owned descendant. This global guard also protects
other branches from observable transient exposure. The synchronous call restores
visibility before verification, frame submission or pointer dispatch. Previously
disabled trees stay disabled, and unchanged membership does not toggle visibility.
Scenes with observable listeners retain ordinary per-node reconciliation cost.

Measurement declarations temporarily omit border paint. The frame completes
these stages before reconciliation and presents the final border commands with
the content geometry. Stable forced frames request no helper updates or scene
mutations.

A measurement pass can remove all shape slots before the allocated pass recreates
them, without intervening native reconciliation. Shape generations advance
monotonically per widget tree across slot removal, so an identical command ID/box cannot retain an obsolete
path. This uses the existing shape bridge and preserves renderer geometry and
the 2048-node limit.


### Grid overlap anchors

The shared sizing helper treats later intersecting authored occurrences as native
floats. Their content supplies no natural, minimum-width or height requirements;
logical membership still preserves cells and authored track minima. Exact areas
reuse existing cells. Other areas share real anonymous `grid.span-area` anchors,
positioned by ordinary track-sized row/column spacers in a passthrough floating
scaffold. Anchors have no widget bindings, paint or pointer capture. Overlays do
not suppress grid borders or fill holes; their actual paint covers decoration
in native floating order, and removal exposes that decoration again.

A private `_attach` declaration reference exposes Clay's existing attachment to
an earlier element. The bridge resolves only references to earlier nodes in the
same current tree; forward, foreign and nonfloating references are refused.
Overlays stay in authored order independently of target row order. Each original
occurrence is compiled once. FIT defaults retain natural overlay content, including
wrapped/nested heights; explicitly authored GROW remains available. Native capture
stops at the top floating occurrence, while default passthrough retains underlying
occurrences. Negative offsets and host clips use existing native behavior.

In `tests/test-clay-grid-overlap.lua`, a 200x60 overlay leaves the underlying
40/70/gap5 grid at 115x20. Overlay content does not enlarge shared tracks.
`tests/test-clay-grid-overlay-presentation.lua` covers nested overlay measurement
stages and checks that each returned frame exposes settled geometry. Stable
frames request no helper updates, and idle event-loop windows stop scheduling.

### Hotkeys help sizing and page membership

Hotkeys help remains centered on OUTPUT, including when bars reserve workarea.
Lua computes its popup minima from `screen.workarea` and its border width.
For each dimension, a request strictly below the workarea extent is retained;
at equality or above, that extent minus both borders supplies the content
extent, floored at zero. The ordinary launcher attachment fixes the outer width,
while height remains a content-growing floor. `beautiful.launcher_width`
overrides the popup width minimum and attachment width without a workarea cap;
pagination still uses the requested workarea budget. Explicit hotkeys dimensions
otherwise precede the dpi-scaled 1200x800 defaults. The dump and inspector expose
ordinary fixed/FIT constraints rather than a separate sizing reference.
Workarea-composed fixed widths are marked `derived`; an explicit launcher
width retains its `theme` source.

A bar reservation changes the public `screen.workarea` after native layout.
Visible help refreshes its constraints and pages on `property::workarea`, so it
follows that notification rather than resolving the new reservation inside the
same native solve. Bar and inspector workarea changes can therefore repaginate
visible help immediately, just as reopening does. No popup or widget box is used
to calculate these limits.

The outer frame, content allocation and public popup size are distinct. Native
content minima may overhang the fixed-width frame, with existing inner clipping;
a tall indivisible text record may grow height beyond the output. Borders,
rounding and original widget input bindings retain their normal behavior.

Lua font/text metrics select hotkey records, columns and page membership only.
Their outputs are never assigned to widget sizes, popup bounds, offsets or
rectangles. Group-label and navigation-label widths are not included in these
membership estimates; Clay measures and allocates their actual elements. Large
groups split repeatedly with at least one real record per segment. An oversized
first column occupies its own page without an empty preceding page. A single
indivisible record can still overflow; there is no additional scrolling or
special dismissal-key behavior.

Reopening cached help refreshes changed output/workarea, font, content, theme
and dimension inputs while preserving the popup object. Unchanged pages retain
their widgets and bindings. Rebuilt pages contain ordinary widgets with their
own original bindings. Newly registered or changed key descriptions are imported
again before grouping; explicit instance settings retain precedence over theme
refreshes. Page navigation, filtering and mouse/keyboard dismissal are unchanged.

### Output frame publication

A dirty output frame runs one declaration pass and one reconcile. A drawin or
client receives its solved geometry as published properties with the same
geometry signals, without recompiling its tree for that size. Drawable moves
only recompile when the widget context changes screen or dpi. A describer sizes
from the space it is offered, never from the host's solved size.
awful.layout.arrange does nothing for a client geometry the solve itself wrote.
An output the backend never frames runs off a display-rate deadline instead.
A slot whose client has closed is skipped until the layout publishes again,
rather than declaring a dead handle.

The workarea for awful.layout, a carousel follow, the inspector's close, the
overflow thumb and a real shape mask re-rendered at the solved size are genuine
inputs to the next frame. The grid helper's pending dependency stages are the
exception and run inside the frame before reconcile.
A hover attachment (a tooltip) appears on the frame after the pointer reaches
its target, because Clay evaluates pointer-over against the last solve.
The tree dump header's `passes` counter shows the declaration count.

### Grid presentation and calendar responsiveness

The shared sizing helper completes its pending dependency stages inside the output
frame transaction before reconciliation. Its declaration updates mark a separate
grid continuation bit; ordinary invalidation schedules the next frame. Clay still
computes every box, attachment and hit region. No additional
tree, rectangle writer, retained-pixel snapshot, authored row height, header edit
or iteration cap is introduced. The event loop dispatches pointer input only
after final geometry, occurrence indices and rasterized scene agree. Solved
callbacks remain internal measurement readback within that transaction.

Redundant minimum probes are skipped when rigid requirements already equal all
natural column requirements. That rigidity propagates through nested helpers.
Height readback is reused only when every dependent occurrence was already
measured at exactly its next declared width. Other wrapping, nested-height,
border and overlay phases remain. This is a bound from dependency progress for
supported compositions, not a general guarantee for arbitrary cyclic describers.

Textbox metadata is cached until a widget redraw/layout signal or DPI change;
mutable declarations and their opacity colors are never cached as shared inputs.
Plain-markup empty attribute ranges avoid unnecessary Pango attribute queries.
Ordinary compiler subtrees without layout observers ignore ancestor measurement
scope changes. Calendar constructors use the public grid path. Applying styles
before assigning a date avoids redundant initial construction through existing
setters.

`tests/test-clay-grid-constructor.lua` checks ordinary grid sizing;
`tests/test-clay-grid-presentation.lua`,
`tests/test-clay-grid-overlay-presentation.lua` and
`tests/test-clay-calendar-presentation.lua` check dependency settling, first
presentation, updates, occurrence identity and real pointer delivery.
`tests/test-clay-calendar-two-color-presentation.lua` covers distinct translucent
border colors through calendar updates. `tests/test-clay-calendar-settlement.lua`
observes the current compiled generation and presented frame through normal event
dispatch, including the ordinary surface-size refresh after grid settling. An old
tree's settled helper flags alone do not establish that a pending mutation has
reached the screen.

Known limitations remain in the second-output occurrence, widget-attachment
clock equality and content-host paint-boundary checks in
`tests/test-clay-widget-occurrences.lua`, `tests/test-clay-widget-attachments.lua`
and `tests/test-clay-content-hosts.lua` respectively.

### Surface clips

A surface inside a clip element is cropped to its rectangle. It keeps its full
configure size and geometry and takes input only where it is visible. Popups are
not cropped by their parent's clip. A protocol-minimum surface overhang outside
any clip is unchanged.

### Scroll state lives in Clay

Scroll offsets persist across frames in the output's Clay context. The wheel
moves 30 pixels per tick regardless of `step`, which still scales `scroll()`.
`scroll_factor` reads back from the scroll record. A Lua reload starts scroll
positions from zero.

### The scrollbar thumb is declared from Clay's record

The thumb's length and offset come from Clay's scroll record inside the declare
pass. Content growth and the wheel move it without a Lua relayout. When the
content fits, the track collapses to zero width and the content takes that space.
The record is one solve behind; a changed record schedules the next
frame to declare the updated thumb.

### Layout animation runs in Clay

Tiled client boxes animate through Clay's own transitions while
`somewm.layout_animation` is enabled. The module is the switch and nothing else:
it pushes `enabled and duration or 0` into the declare pass, and no Lua or C
interpolator remains.

- `easing` is accepted and ignored. Clay eases out, and that is the only curve.
- A client's first appearance, a mouse drag and a screen resize snap.
- Boxes are animated on whole pixels, so an animating element and its neighbour
  stay flush.

Every box the scene draws rounds both of its edges to whole pixels, the same
rule `c:geometry()` uses, so a client's configure equals its geometry and two
boxes that share a solved edge share a realized one with no gap between them. A
clip rectangle is the exception and keeps its solved edges, so it can still cut
content at a fraction of a pixel.

A declared slot animates its own box the same way. It names a duration, which of
its position and size to animate, whether it collapses on the way in and on the
way out, and where an exiting one sits among its siblings.

An exiting element shrinks in place and does not reflow its siblings, which is
Clay's semantics: it is drawn, but it holds no space. The sibling order it asks
for places it in the flow, so `above` draws it after its siblings. A panel that
must reflow while it closes declares a fixed width of zero and removes itself
once that has settled, which is a transition rather than an exit.

### Public placement and strut boundaries

`awful.placement` still handles public floating-client geometry requests, rule placement callbacks, interactive resize/snap and IPC placement commands. Startup `no_offscreen` keeps restored floating clients reachable. These calls update geometry inputs that the output tree subsequently declares. A popup's named corner placement uses a native attachment to OUTPUT; an arbitrary callback remains callable. Hotkeys help uses the named `centered` attachment. Popup centering is relative to OUTPUT, including when a placement callback passes `honor_workarea=true`, because the popup branch of `awful.placement.align` delegates to the same attachment.

Wibars reserve space through declared flow elements and layer surfaces through protocol exclusive-zone declarations. Public `struts()` properties retain stored values and change signals, but those values do not independently subtract rectangles from the workarea. The workarea is the solved native element.
