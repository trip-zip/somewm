# Changelog

All notable changes to somewm will be documented in this file.

## [Unreleased]

### Added

- Client and drawin animation effects `scale`, `scale_top`, `scale_bottom`,
  `scale_left` and `scale_right` scale the complete picture about its center or
  an edge midpoint without changing layout allocation or client configure sizes.
  Scale composes with fade and one slide. Grow (including its collapse alias)
  and the five scale effects share one size group: conflicting effects warn
  once and keep the first.
- The lock screen shows an image, theme.lockscreen_wallpaper and
  theme.lockscreen_wallpaper_overlay, or the wallpaper and wallpaper_overlay
  options of lockscreen.init; the image is letterboxed like the desktop
  wallpaper and dimmed by the overlay colour.
- A childless wibox.container.background inside wibox.layout.stack paints
  its colour over the stack again, and a floating wibox.container.place keeps
  its whole allocation.

- awesome._active_modifiers reports current keyboard modifiers, including
  root.fake_input presses, so awful.keyboard can release held modifiers.

- client.shape: nil, a corner radius in pixels, or a gears.shape function.
  gears.surface.apply_shape_bounding sets it on a client as it sets
  wibox.shape. gears.shape.rounded_rect, or a function drawing its path, is
  read as that radius; any other function warns once naming the client, which
  stays square. A titlebar takes the corners on its edge and the surface the
  rest. The suite's headless runner keeps a WLR_RENDERER already set in the
  environment instead of forcing pixman.
- awful.widget.calendar_popup.month and .year take a width argument,
  defaulting to beautiful.calendar_popup_width, and the popup is an
  awful.popup placed by its position inside the workarea; awful.popup gains
  honor_workarea.
- screen.inspector: Clay's debug inspector on that screen, its element tree
  and the selected element's solved box and configuration; property::inspector
  fires on a change, also when the panel's close button closes it.
  somewm.inspector.toggle(s) flips it on s or the focused screen, and
  somewm.inspector.restyle() re-reads the theme: beautiful.inspector_bg,
  inspector_bg_alt, inspector_border, inspector_fg, inspector_bg_selected,
  inspector_highlight, inspector_width and inspector_font.
- somewm-client clay tree [screen] prints what the last frame solved on every
  output, or on one screen: counters per band, then one line per retained node
  in draw order.
- beautiful.launcher_width: the menubar launcher's width, ahead of
  menubar.geometry.width; without either the launcher spans the workarea.

- Client and drawin entrances and exits accept lists such as
  `{"fade", "slide_left"}` to compose simultaneous effects in one transition.
  One slide, grow and fade can run together with one duration; existing strings
  still work. Repeated effects and collapse-as-grow are deduplicated. Conflicting
  slide directions, or none with another effect, warn once and keep the first
  named effect so incompatible settings are not silently ignored.
- Client animation by trigger: `c.animation = {appear, disappear, tag, focus,
  maximize, floating}` and the rule property of the same name, with the theme
  keys beautiful.animation_appear, animation_disappear and animation_tag
  (grow, slide_left, slide_right, slide_up, slide_down, fade) and the durations
  animation_appear_duration, animation_disappear_duration,
  animation_tag_duration, animation_focus_duration,
  animation_maximize_duration and animation_floating_duration.
  beautiful.animation_duration supplies the fallback for triggers without
  their own duration, including layout. A focus change eases the border
  colour. With a tag duration set, a tag switch grows clients in and out
  unless c.animation.tag or beautiful.animation_tag names another entrance.
  A client exit animates its frame only; the surface snaps.
- `animation = {visible = {duration, enter, exit}}` on wibox and awful.popup,
  with the same entrances. A drawin's exit drops its shadow at once.
- `widget.animation = {property = duration}` for bg, border_color, border_width,
  forced_width, forced_height and the progressbar and slider value, and
  `widget:animate{property = value, duration = d}` for one change. Positions
  snap. Past 200 transition records per output, including configured idle
  records, the remaining nodes snap, with one warning.
  The `.animation` property stores the policy separately from the `:animate`
  method. With `widget.animation = false`, the method applies values immediately
  and remains callable. Policy changes emit `property::animation`.
- Animation policies on clients, wiboxes, popups and widgets are copied on
  assignment and access. Reassign an edited policy to apply it and notify
  observers. `animation = false` suppresses the object and its descendant
  animations; `nil` removes the override. The global
  `somewm.animation.enabled` switch and mouse grabs also suppress drawin
  transitions. Active transitions finish on the next rendered frame when
  disabled, including retained exits.

### Changed

- Assigning a table that is not an animation policy to widget.animation, client.animation or a wibox's animation
  keeps the table as the object's own field and warns once, instead of copying it. Configs that already used that name for their own objects (yoru, KwesomeDE) load again.
- Widgets in a wibox or popup receive pointer events while its entrance
  animation runs; previously the entrance window swallowed them.
- somewm always builds with XWayland support; the -Dxwayland build option is
  gone, and a build without it had not compiled. Building needs xcb, xcb-icccm
  and Xwayland installed, and running X11 applications needs the Xwayland
  binary.
- Client shape masks are accepted and never read: shape_bounding, shape_clip and
  shape_input, and client_shape_bounding, client_shape_clip and
  client_shape_input, which always read nil. A client's corners come from its
  shape property.
- A wibox with an opacity below 1 blends each of its fills at that opacity, so
  fills that overlap add up: a blue background container on a blue wibox at
  opacity 0.5 shows denser blue than either alone. 2.0 blended the whole wibox
  once.
- A drawin's widget tree holds at most 4096 nodes; a larger tree shows nothing
  and the drawin warns once that it is over the output's element budget.
- An imagebox without a forced size takes its size from the bound above it: the
  cross-axis bound times its aspect, lowered to the flow-axis bound when that is
  smaller, as 2.0's fit did. With no bound on either axis, along a flex or
  linear layout's flow, it declares its natural size and can leave slack or
  overflow its parent. An imagebox forced on one axis scales its image to that
  axis.
- Hotkeys help and menubar scroll instead of paging; every key and item stays
  reachable. Hotkeys: one column per group, continued every
  `beautiful.hotkeys_rows` rows (new theme value, default 20); PgDn/PgUp scroll
  by one viewport; the "PgDn - Next Page"/"PgUp - Prev Page" labels are gone.
  Menubar: `left_label`/`right_label` show while items lie beyond that side. A
  bordered popup whose content is larger than its slot keeps its slot geometry;
  the content is clipped as it was already drawn.
- A non-homogeneous grid no longer sizes its columns to the widest cell across
  rows.
- A homogeneous grid inside a content-sized box takes content-sized cells and
  warns.
- A row span occupies its first row only and warns.
- Grid border dashes draw as solid lines and gradient border colours are
  transparent, both warn.
- A client whose protocol minimum exceeds its tiled cell overhangs the cell; the
  workarea and its neighbours keep their size and c:geometry() reports the cell.
- An ontop, above or below client under a stock layout now tiles into its slot,
  as in AwesomeWM, instead of keeping its last box.
- Under max and magnifier a floating client is above the layout's clients
  whatever the raise order, as under tile, including a floating parent whose
  transient is tiled under max.
- A transient of a max or magnifier client is a root of its own above every
  client of that layout, not above its parent only.
- c.size_hints now reports min_width, min_height, max_width and max_height for
  Wayland clients, from the toplevel's committed bounds (0 means none);
  property::size_hints fires when they change. A Wayland client whose min equals
  max now reports is_fixed and floats, as an X11 client with those hints did.
- A client whose rules set no border_width now draws no border, as in AwesomeWM;
  before, the theme's border_width was applied from C and could not be read from
  Lua.
- property::border_color also fires on a client when the focus recolour changes
  the drawn border, with c.border_color unchanged unless a config set it.
- property::scroll_factor on wibox.layout.overflow fires once the frame has
  applied a change, from a setter, scroll() or the mouse wheel, with the applied
  factor; before, it fired inside the setter with the requested value and never
  for the wheel.
- property::scroll_factor on wibox.layout.overflow also fires when a change in
  content or viewport size moves the factor without a scroll, and does not fire
  when a set leaves the applied factor unchanged.
- A slider bar_color gradient without bar_margins is drawn in the bar's box;
  upstream used the widget's box. Clay centres the bar.
- An arcchart colors gradient in a non-square box is drawn in the box; upstream
  used the centred square.
- A separator color gradient on a horizontal or vertical line is drawn in the
  line's box; upstream used the widget's box.
- Text under a rotate or mirror draws as one line; a textbox with more than one
  line under one is left out with a warning.
- A wibox.container.scroll under a rotate or mirror, and a rotate or mirror
  inside another, are left out with a warning.
- A widget under a rotate receives press coordinates relative to its rotated
  box; v2.0.0 mapped them through the container's matrix into the widget's own
  frame.
- Setting c.shape stores it, emits property::shape and arranges the screen; a
  shape that is not a rounded rectangle warns once naming the client, and the
  client stays square.
- The client and drawin shape mask warnings name shape_bounding, shape_clip and
  shape_input.
- A layout leaf that is both placed (x or y) and sized (grow, fit or a percent)
  on the same axis is left out of the tree with one warning naming the client.
  Before, the leaf floated at x,y with its sized box and could run past the
  output.
- somewm builds its own wlroots 0.20.2 and links it in; an installed wlroots is
  not used. The wlroots 0.19 path and `-Dwlroots_version` are gone. A distro
  whose wayland, libdrm, xkbcommon, pixman or wayland-protocols is older than
  wlroots 0.20.2 gets that library built alongside it.
- wibox.layout.align with expand none lets an outer widget wider than its half
  push the centre widget off centre instead of cutting the outer widget at the
  half; v2.0.0 cut it.
- A function bgimage on a wibox or a wibox.container.background is not drawn;
  setting one warns and clears the image. 2.0 called it to paint the
  background.
- A shape function is used as the path it traces; anything else it does, such
  as setting a source or painting, is dropped. 2.0 ran it on the widget's cairo
  context.
- A client frame declares a transition only when the layout duration is above
  0, so an output with clients solves its layout once per frame instead of
  twice. A client's first frame after the duration is set, or after a reload,
  does not animate.
- A textbox wraps at words whatever its wrap is; wrap = "char" warns once. 2.0
  broke inside a word for "char", and for the default "word_char" when a word
  did not fit the line.
- wibox.container.tile with tiled true, its default, draws one copy of its
  widget, placed as wibox.container.place places it, and warns once. 2.0
  repeated the widget across its box.
- A fractional padding, gap, offset or border width rounds to the nearest whole
  pixel. 2.0 kept the fraction.
- The interactive awful.screenshot's overlay covers the screen under the
  pointer when snipping starts, rather than the whole root; 2.0 drew it across
  every output. A drag that crosses screens still selects its root-space box,
  and the rectangle shows on the screen it started on.

- `somewm.layout_animation` is deprecated. Layout changes animate when
  `somewm.animation.layout_duration` or `beautiful.animation_layout_duration`
  is above 0; requiring the old module still sets 0.15 as it always did.

### Removed

- The `fit`, `draw`, `layout`, `before_draw_children` and `after_draw_children`
  methods of the stock widget, container and layout classes (73 methods over 33
  classes). Clay sizes and places every widget from its description, so no stock
  class measures, lays out or paints itself.
- `wibox.hierarchy` and the `wibox.hierarchy` field: `new`, `count_widget`,
  `update`, `get_widget`, `get_matrix_to_parent`, `get_matrix_to_device`,
  `get_matrix_from_parent`, `get_matrix_from_device`, `get_draw_extents`,
  `get_size`, `get_children`, `get_count` and `draw`. The widget tree is
  declared to Clay; no tree of placed widgets is kept to walk.
- The `wibox.widget.base` placement helpers `fit_widget`, `layout_widget`,
  `place_widget_at`, `place_widget_via_matrix` and `rect_to_device_geometry`.
  Clay places every widget.
- `wibox.widget.draw_to_cairo_context`, `draw_to_image_surface` and
  `draw_to_svg_file`. Widgets no longer paint into cairo; the renderer draws
  their description.
- `wibox:to_widget` and `wibox:save_to_svg`, for the same reason.
- `wibox.container.border`. No configuration uses it; loading it is an error.
- Properties no configuration sets: `horizontal_offset` (wibox.layout.stack),
  `minimum_column_width` and `superpose` (wibox.layout.grid, which always
  refuses a widget added over another), `inner_fill_strategy`
  (wibox.layout.ratio), `stretch_horizontally` and `stretch_vertically`
  (wibox.container.background), `paddings` (wibox.container.radialprogressbar),
  `horizontal_crop` and `vertical_crop` (wibox.container.tile), `auto_dpi` and
  `source_width` (wibox.widget.imagebox), `ticks_gap` (wibox.widget.progressbar),
  `bar_border_color`, `bar_border_width` and `handle_margins`
  (wibox.widget.slider), `empty_cell_mode`, `empty_color` and `empty_widget`
  (wibox.widget.calendar), and `check_border_color`, `check_border_width` and
  `check_shape` (wibox.widget.checkbox, whose check takes `shape`). Setting one
  warns once that it is ignored; reading one gives nil. The theme variables
  only they read are gone too: `radialprogressbar_paddings`,
  `slider_bar_border_color`,
  `slider_bar_border_width`, `slider_handle_margins`, `calendar_empty_color`,
  `checkbox_check_border_color`, `checkbox_check_border_width` and
  `checkbox_check_shape`.
- The scroll container's draw-context fields `context`, `first_x`, `first_y`,
  `fit_width`, `fit_height`, `hierarchy`, `surface_width` and `surface_height`.
  The container is a Clay scroll element and no longer draws its child into a
  surface of its own.
- `awful.wallpaper` `uncovered_areas_color`, `dpi` and `get_dpi`. Setting one
  warns once: the root wallpaper shows in the uncovered areas, and the output
  scale applies.
- `carousel.scroll_duration`. Scrolling animates client slots over the layout
  duration.
- `somewm.layout_animation.easing`. Clay animates the transition; setting it
  warns.
- The drawin `surface_scale` property. A drawin has no surface of its own to
  scale.
- The drawable `refresh` method and `surface` property. A drawable holds no
  cairo surface.
- `awesome.systray`; use `wibox.widget.systray`. See the [2.0 to 2.1 upgrade guide](https://somewm.org/docs/next/getting-started/upgrading-from-2.0/#classes-and-properties).
- `wibox.widget.textbox:get_preferred_size`,
  `wibox.widget.textbox:get_preferred_size_at_dpi`,
  `wibox.widget.textbox:get_height_for_width`,
  `wibox.widget.textbox:get_height_for_width_at_dpi`,
  `wibox.widget.textbox.get_markup_geometry` and
  `menubar.utils.compute_text_width`. Clay measures text; nothing measures it in
  Lua.
- `awful.client.shape`: `get_transformed`, `update.all`, `update.bounding`,
  `update.clip` and `update.input`. The shape was never applied on Wayland.
- `menubar.utils.compute_textbox_width`. It measured through
  `textbox:get_preferred_size`, which is gone.
- `ruled.client.completed_with_payload_callback`. It was an alias of
  `ruled.client.execute`; call that.
- The drawin `shape_border` property, a border surface drawn in Lua. The
  renderer draws the border of a shaped wibox itself.
- `wibox.widget.base.no_parent_I_know_what_I_am_doing`, the marker for
  `base.fit_widget` and `base.layout_widget`, which are gone.
- The wibox `__tostring`. `tostring()` of a wibox prints the table, where 2.0
  printed `wibox: <drawable> (<table>)`.

- `awesome.start_animation`. An animation is a transition on the declaration.

### Fixed

- A tree dump taken in the last frames of a right-anchored scale animation
  read past its list of anchor names.
- A tree dump taken in the same dispatch a client unmapped read freed
  memory. The dead client's surface now reads as `no-node` until the next
  frame drops it.
- An explicit `disappear = "none"` or `exit = "none"` closes without an
  animation instead of falling back to the tag exit.
- A bordered or shadowed wibox or popup that grows in or out shows its
  content inside the growing frame, instead of at its full size behind it.
- Xwayland content-size requests are declared inside the Clay client frame,
  so repeated and partial requests no longer shift or shrink decorated
  floating windows. Geometry replies use the completed solve, with request
  masks, gravity, size limits and compositor allocations respected.
- Xwayland clients default to full opacity, keeping Steam and Proton windows
  visible after switching tags without needing a hover to redraw them.

- Explicitly positioned `awful.popup` windows size to their content and respect size limits when a border, shadow or visibility animation adds an outer frame, instead of remaining at their initial 1×1 geometry.

- Packages built with `--auto-features enabled`, such as Arch's `arch-meson`, no longer abort when the pointer moves from the bar into a menu. The renderer's debug verifier is on only in sanitizer and test builds, and the `render_verify` build option is gone.

- Nested X11 and Wayland pointers map to their host output, so multiple outputs no longer stretch absolute pointer coordinates across the whole layout.

- client.icon rejects LGI surface records and other non-pointer values with a
  Lua type error instead of interpreting userdata storage as a Cairo surface.
  Assign awesome.load_image() or a Cairo surface's _native pointer instead.

- Systray registrations share one pending property fetch per item, preventing duplicate icons after a reload and allowing retries when the fetch fails.

- wibox.widget.textbox keeps its last applied font when setting a font fails, so a rejected name can be retried.
- somewm-client tag commands use the loaded layout module, so adding a tag and setting its gap, layout or master width factor no longer fail on an undefined global.
- A toplevel's bounds are the workarea, never the size it drew. A GTK window that drew its own size once (ghostty) was sent that size as its bounds and stayed at it, 800 wide in a full cell, whatever the compositor asked afterwards.
- wibox.layout.grid emitted property::minimum_column_width when
  minimum_row_height changed.
- A rounded background, border or clipped widget draws through somewm's
  wlroots build instead of a cairo raster: resizing, moving or clipping it
  rasters nothing, and a titlebar's or bar's corner radius is no longer cut to
  half the bar's height when only two corners are rounded.
- A client shaped with a rounded rectangle (gears.surface.apply_shape_bounding
  with gears.shape.rounded_rect, or client.shape) draws rounded corners on
  Wayland, through somewm's own wlroots 0.20.2 build: the surface and the
  titlebar on an edge are cut by their radii under gles2 and pixman, nothing
  under a cut corner is culled, a click in the corner reaches what is below,
  and screen.content shows the cut. 2.0 accepted the shape and drew a square.
- A client that commits a size other than the one it was configured is drawn
  at the committed size: its titlebar, border, shadow and corners wrap the
  surface, and the next configure still carries the layout's or the user's
  box. 2.0 drew the frame at the configured size, so a terminal keeping whole
  cells had its titlebar overhang the surface.
- A slider bar_active_color gradient now draws. Upstream raised an error for a
  gradient string (parse_color returns nil for it and add_color_stop_rgba fails)
  and skipped the active part for a gradient table.
- Every new client starts with size_hints_honor true, as the property documents
  and as 1.4 and AwesomeWM do; 2.0.0 started it false. A client's protocol
  minimum and maximum now reach the dump and the solve without a rule setting
  the flag. Rules that set it false keep winning.
- client.get(), client::list, the stack and _NET_CLIENT_LIST see a client from
  its first map, as in AwesomeWM. Before, a surface that was created and never
  mapped was listed with no name, class or pid, and wlroots' no-focus window
  stayed listed from the first X client until exit.
- The systray urgent, hover and overlay backgrounds and the grid hole take a
  gradient, filling the node's own box with its points as authored. A surface or
  mesh pattern warns once naming urgent_bg, hover_bg, overlay_bg or
  border_color, and the node stays transparent. Before, each of these drew
  nothing and said nothing.
- Wrapped text with a word wider than its box, then a space, then a newline no
  longer crashes the compositor. That line draws as an empty line.
- The bundled bar puts the clock between its left and right groups; before it
  floated over the tasklist.
- A client that acknowledges a new size and keeps drawing its old one, as
  ghostty does after moving to a screen with another scale, is sent the size
  again up to three times a second apart and takes its cell. Before, it was
  sent once more and could stay at its old width beside an empty strip.
- A client that draws larger than its cell, as a terminal moved from a bigger
  screen does, no longer grows the cell, the row and the screen's workarea; its
  drawing is cut at the cell and it is asked for the cell.
- A Wayland window that hides by dropping its buffer and shows again is
  configured, maps and is managed again, as a new client object, as AwesomeWM does
  for a window withdrawn and mapped again. Before, it waited for a configure
  that never came and never showed again.
- make install removes the installed Lua tree (somewm/lua in the install's
  datadir) before installing, so a module removed since the last install is
  gone. Before, 2.0's wibox.hierarchy and wibox.container.border stayed and
  loaded in place of the error a config should get.

## [2.0.1] - 2026-10-10

Patch release. 37 commits since 2.0.0: drawing tablets, touchscreens, fake
screens, hot-reload fixes, `somewm --check`, and builds on more platforms.
Only additions to the API, apart from shadow `clip_directional` no longer
having an effect; existing rc.lua configs run unchanged.

### Added

- Drawing tablets (tablet-v2). Pressure, tilt, distance, rotation, slider,
  wheel, and pad buttons, rings and strips reach apps that support tablets;
  other apps, wibars and titlebars get pointer motion and a left click on tip.
  `awful.input.rules` take `tool_mode`, `map_to_output`, `map_to_region` and
  `map_from_region`
- `map_to_output` takes a connector name, a `"make model serial"` identifier
  that survives the connector being renumbered, or a list tried in order
- Touchscreens (`wl_touch`). A tap clicks apps that do not handle touch,
  wibars and titlebars included; `emulate_pointer = false` in a touch rule
  turns that off. When only one output is enabled, a touch device or tablet
  maps onto it by default
- `awesome.dpms_ignore_activity = true` stops input from turning monitors back
  on after DPMS off
- A panic prints Lua and C tracebacks
- An unsupported input device is logged
- `somewm --check` flags a GTK app run inside the compositor,
  `Gtk.IconTheme.get_default()` and bare `xrdb`, and links each finding to its
  section on the migration page

### Changed

- Client and wibox shadows are a rounded nine-patch: the frame grown by
  `spread`, moved by its offset and faded over `radius` on every side, with
  `corner_radius` applied and the color's alpha multiplying `opacity`. This
  removes the double-blended fill and the hard corner cutoffs.
  `clip_directional` and `beautiful.shadow_clip` no longer have an effect
- The boot scan of the config only warns; a matched X11 pattern no longer
  makes somewm skip the config
- Type and range errors from somewm's C functions no longer carry a traceback
  inside the error message

### Fixed

- `awesome.startup` is true during a hot-reload, as it is on an AwesomeWM
  restart
- Moving the pointer over an open popup after a hot-reload no longer reads
  freed memory
- Fake screens are arranged and show their own tags, each has its own workarea
  from its wibar struts, and a wibar moves to a remaining screen when its fake
  screen is removed
- Titlebar button events on the left, right and bottom titlebars carry
  titlebar-relative coordinates, so clicks land on the right button
- Key bindings accept literal Unicode keys such as `"ä"`, and prompts count
  UTF-8 characters correctly
- libinput settings such as `tap_to_click` and `accel_speed` apply to every
  input device, not only pointers
- `c.content` and `root.content` crop client-side decoration shadow margins
  instead of squeezing them in, and follow the buffer transform
- Fractional `awful.placement` margins and offsets are rounded to whole
  pixels; they grew an attached drawable by a pixel per pass until the stack
  overflowed. Port of AwesomeWM PR #4122
- `somewm --check` and the boot scan read the same files: the whole config,
  including modules required without a dot in the name, found through Lua's
  package path, but not somewm's own libraries or installed rocks, which
  `--check` no longer reports missing. `somewm --check rc.lua` with no
  directory reads the whole config
- `somewm --check` reports each finding once with its line, no longer takes
  `xsettingsd` for `xset`, and reports an unbound `get_xproperty` or
  `set_xproperty` call as critical rather than a warning, since the config
  cannot load
- `somewm-client test start` keeps the nested compositor's log when the start
  fails, instead of deleting it right after printing its path
- The default config starts without warnings: an absent XDG data directory is
  treated as empty rather than warned about, and when no output is at scale 1
  `root.cursor()` accepts cursor names and XWayland gets its root cursor
- The systemd session wrapper no longer deletes other Wayland sessions'
  sockets from `XDG_RUNTIME_DIR`
- Builds on libcs without `execinfo` or `dlvsym`, such as musl; on 32-bit
  platforms; and on distributions whose PAM ships no `pam.pc`, such as Debian

## [2.0.0] - 2026-08-28

Major release. 202 commits since 1.4.0. The Lua/C boundary is reworked: C
events are queued and delivered to Lua at a defined point, instead of Lua
running in the middle of C event handling. The deprecated API surface
accumulated through the 1.4 line is removed. Fixes already released in 1.4.1
through 1.4.4 are included but not re-listed here.

### Removed

Every removal is listed with its replacement in
[`DEVIATIONS.md`](DEVIATIONS.md) under "Removed APIs".

- `awesome.api_level` and the machinery behind it. Nothing selects a
  compatibility level anymore; the library behaviors that branched on it are
  fixed at what level 4 did, and `gears.debug.deprecate` is a plain warning
- `gears.wallpaper` and its cache. Use `awful.wallpaper`
- `awful.util`, whole module. Its functions have lived in `gears.*` and
  `awful.*` since AwesomeWM 4.0
- `naughty.notify()` and the other deprecated `naughty.core` functions. Use
  `naughty.notification`
- The deprecated redirect shims and the deprecated functions in `awful.tag`
  and `awful.client`
- The `manage`/`unmanage` client signals. Connecting to them warns and does
  nothing; use `request::manage`/`request::unmanage`
- The legacy `_key` module, the `add_signal` no-ops, and the `.data` alias

### Changed

- C-to-Lua signals go through an event queue. Geometry, focus, mouse,
  lifecycle, and `request::` signals are queued in C and delivered together at
  a defined point in the frame; pointer motion coalesces to one event per
  delivery
- The default config (`somewmrc.lua`) is rewritten around somewm's own
  features instead of mirroring AwesomeWM's rc.lua. The AwesomeWM-style config
  remains supported; only the shipped default changed
- somewm.c is split into focused modules (input, window, monitor, protocols,
  focus, xwayland). No behavior change

### Added

- Client-side maximize and minimize buttons (GTK header bars) drive the same
  client state as titlebar buttons and keybindings
- Laptop lid and keypad-slide switches emit Lua signals
- Carousel layout: dynamic peek (`beautiful.carousel_dynamic_peek`), layout
  state introspection via `carousel.get()`, vertical `push_window`, and
  per-client column width via the `carousel_column_width` rule property
- 256x256 client icons

### Fixed

- Notification D-Bus method calls always get a reply, so applications that
  block on the reply no longer hang or time out
- XDG toplevels are activated before keyboard enter, fixing focus for clients
  that wait for activation
- Shape masks are read in whichever pixel format they arrive in
- The Lua tree parses under every supported Lua again (5.1 through 5.5,
  LuaJIT), checked by `make test-unit`

### Notes

- 2.0 is its own line and no longer tracks AwesomeWM releases. The public
  `rc.lua` API is preserved by default; deviations are documented in
  [`DEVIATIONS.md`](DEVIATIONS.md)
- `screen.fake_add` creates a screen object, but fake screens are not
  functional: clients moved to one are hidden and bars cannot attach to it
  (#561). This is gated on the 2.2 layout work

## [1.4.4] - 2026-08-20

Patch release. 10 commits since 1.4.3: client popups, input routing, and idle
inhibitors. No API changes; existing rc.lua configs run unchanged.

### Fixed

- Client popup menus open where the application asked, instead of offset up and
  left by the border width and titlebar height, and no longer get cropped at the
  client's content edge. Context menus routinely open above and left of the
  pointer, so this was visible in Firefox and anything else with a context menu
- Popups paint above client borders and shadows instead of behind them
- X11 clients keep the pointer grab when you click the window that already has
  focus, so games no longer lose mouse capture on every click
- Scroll ticks reach the mousegrabber as buttons 4/5, as they do in AwesomeWM.
  BTN_SIDE and BTN_EXTRA no longer land in those slots; they are buttons 8/9
- Clicking a wibar no longer fires the root button binding on top of whatever
  the wibar did with the click
- Pointer focus unpins on the seat's button count instead of a local latch, so a
  release swallowed by a mousegrabber no longer pins focus to a stale surface
- Destroying an idle inhibitor recomputes after wlroots unlinks it, so idle
  timers are no longer latched off for the rest of the session
- Systray icons size by the theme's `base_size` rather than the source pixmap,
  so an app publishing a 256x256 icon no longer takes a 256px wide slot with the
  icon letterboxed inside it
- Tag names that are empty or unset no longer read through a null pointer

## [1.4.3] - 2026-08-08

Patch release. 25 commits since 1.4.2: a hot-reload rework, wlroots 0.20
support, and border geometry fixes. One property removed to match upstream
AwesomeWM; existing rc.lua configs otherwise run unchanged.

### Added

- wlroots 0.20 support, alongside 0.19. The build picks whichever version the
  system provides; `-Dwlroots_version` forces the choice. Restores the build
  on Debian 13 and Ubuntu 24.04 (#579)
- Restart test suite: assertions on both sides of a real `awesome.restart()`,
  driven from outside through `somewm-client test`
- `make check-qa` runs luacheck, mirroring upstream AwesomeWM

### Fixed

- Hot-reload closes the old Lua state instead of leaking it, ending the
  ~90 MB RSS growth per `awesome.restart()` (#574)
- Hot-reload no longer crashes in lgi after reload: lgi's C libraries are
  pinned across the state close (#465)
- naughty and the status notifier watcher release their D-Bus names and
  registrations on exit, so notifications and the systray survive reloads
- Both rebuild paths reset C-held Lua state, including the config-timeout
  recovery path
- Border width no longer inflates client size: geometry is border-exclusive
  as in AwesomeWM, fixing titlebar positioning, shadow sizing, clipping, and
  `c.content` capture offsets
- Destroying the focused client emits `unfocus` and `property::active`,
  matching AwesomeWM
- Timers armed during the refresh cycle wake the poll, so an idle session no
  longer sleeps past a due `gears.timer`
- The seat advertises pointer and keyboard capabilities at startup, not only
  after the first input device appears
- `print()` from rc.lua reaches redirected logs (stdout is line-buffered)
- awful.ipc parses under Lua 5.5 (loop variables are read-only there)
- tasklist and drawable no longer swallow widget errors; undefined-variable
  bugs fixed in ipc, systray tooltips, and focus_tracker
- `clickfinger_button_map` initialized (touchpad clickfinger crash)

### Removed

- `client_shape_input` property and `awful.client.shape.update.input`,
  matching upstream AwesomeWM's revert of the feature (#4100). The drawin
  `shape_input` property is unaffected.

### Notes

- AwesomeWM baseline unchanged from 1.4.0, plus ported upstream fixes #4100
  and #3998.
- See [`DEVIATIONS.md`](DEVIATIONS.md) for Wayland vs X11 differences.

## [1.4.2] - 2026-06-22

Patch release. 43 commits since 1.4.1: mostly bug fixes, plus a few additive
features. No public API breaks; existing rc.lua configs run unchanged.

### Added

- `somewm::ready` and `xwayland::ready` signals, also exposed as `awesome.*`
  properties and re-emitted on hot-reload
- `-c NONE` to start without loading any user config
- XKB keyboard model and rules selection
- `screenshot` interactive (snipping) subcommand in the somewm-client CLI

### Fixed

- Compositor terminates cleanly on SIGTERM/SIGINT and Ctrl-Alt-Backspace
- Timer-driven widget redraws now present on an otherwise idle session (clocks update)
- Client buffer flush deferred out of the map signal emit (disconnect-mid-map crash)
- Titlebar hover no longer leaks pointer events to the client beneath it
- Aerosnap placeholder deferred by dwell, removing cross-monitor flicker
- `request::tag` nil-guard restored for `transient_for.screen`
- `createmon()` bails cleanly when an output commit fails (partial hotplug)
- Per-client geometry signals emitted on the xdg fullscreen path
- Hot-reload assigns all client screens before emitting restore signals
- Drawin struts aggregated per explicit screen pointer (multi-monitor)
- `c.content` captured via scene-tree walk and scaled to logical size on HiDPI
- Screenshot snipping overlay rendered at logical resolution

### Changed

- Default build is optimized release with no sanitizers (packaging-relevant)
- Build supports Lua 5.5; added a `lua_pkg` override
- Cleaned `-Werror` failures under GCC 15/16; stopped propagating `-Werror`
  into the wlroots, v4l-utils, and libdisplay-info subprojects

### Notes

- AwesomeWM baseline unchanged from 1.4.0.
- See [`DEVIATIONS.md`](DEVIATIONS.md) for Wayland vs X11 differences.

## [1.4.1] - 2026-04-24

Patch release. 19 commits since 1.4.0, all bug fixes and one additive
signal change. No public API breaks; existing rc.lua configs run unchanged.

### Fixed

- Use-after-free of `wlr_scene_tree` via `wlr_surface->data`
- SEGV on monitor unplug from missing surface cleanup (#442)
- `createmon()` hardening for partial monitor init failures (#477)
- Carousel: clients render across monitors when outside the carousel layout
- Borders stay visible when a client is partially offscreen
- Pointer enter delivered to newly mapped layer-shell surfaces
- Pointer focus re-evaluated after the banning refresh
- `LyrOverlay` placement preserved for override-redirect clients (XWayland stacking)
- wibox: opacity and border properties propagate to the underlying C drawin
- wibox: A1 surface format restored for shape masks
- Idle-inhibit exclude mechanism honored again (#446)
- Icon resolution falls back to `.desktop` entries when class isn't a theme icon
- Keygrabber stops key repeat when starting mid-press
- Keyboard layout `next_layout()` off-by-one in wrap-around
- README links point at the 1.4 docs site

### Changed

- The `exit` signal now carries a `restart` boolean argument: `true` on
  hot-reload, `false` on shutdown. Matches AwesomeWM behavior. Existing
  handlers that ignore arguments are unaffected.

### Notes

- AwesomeWM baseline unchanged from 1.4.0.
- See [`DEVIATIONS.md`](DEVIATIONS.md) for Wayland vs X11 differences.

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
