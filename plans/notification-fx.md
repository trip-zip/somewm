# Notification FX — FadeIn Animation + Shadow + Visual Refresh

Branch: `feat/notification-fx`
Date: 2026-04-03
Authors: raven2cz, Claude Opus 4.6

## Summary

Notification popups now have:
1. **FadeIn animation** — smooth opacity 0->1 using `awesome.start_animation()` (GPU frame-synced)
2. **Shadow fadeIn** — shadow opacity animates together with content (no pop-in)
3. **Removed border** — cleaner look without the amber border frame
4. **Larger, readable layout** — bigger icon, better fonts, proper text wrapping
5. **Professional typography** — Geist SemiBold amber title, CommitMono body text

## Files Changed

### `lua/wibox/init.lua` (upstream-worthy)
**Bug fix: wibox opacity never propagated to Wayland compositor.**

The wibox `set_opacity` wrapper stored the value only in a Lua table (`self["_opacity"]`),
but never wrote it to the underlying C drawin property (`drawin._opacity`). This meant
`wlr_scene_buffer_set_opacity()` was never called — opacity had zero visual effect on
any wibox (panels, popups, notifications).

```lua
-- Added in setter loop for border_width, border_color, opacity:
if self.drawin then
    self.drawin["_"..prop] = value
end
```

**Key discovery:** C drawin properties use underscore prefix (`_opacity`, `_border_width`),
registered via `luaA_class_add_property(&drawin_class, "_opacity", ...)` in `drawin.c:2559`.
Setting `drawin.opacity` from Lua creates a plain Lua field, bypassing the C setter entirely.

### `plans/somewm-one/anim_client.lua`
- Added `notification` section to defaults (enabled, duration 0.5s, ease-out-cubic)
- Added `anim_client.fade_notification(popup)` public function
- Uses `drawin._opacity` directly (not `popup.opacity`) because wibox widget redraws
  call `drawin_refresh_drawable` which reapplies opacity from `drawin->opacity` — going
  through the wibox Lua setter triggers a redraw cycle that resets the animated value
- Shadow animates together: captures original shadow config, sets opacity=0 initially,
  interpolates shadow opacity in tick callback, restores original on completion

### `plans/somewm-one/rc.lua`
- `request::display` handler: captures `naughty.layout.box` return value, calls
  `anim_client.fade_notification(popup)` after creation
- `border_width = 0` on popup (no amber border)
- `maximum_width = dpi(700)` for text wrapping on long messages
- Simplified image layout: removed constraint+place wrappers, direct imagebox
  with `forced_width=dpi(138), forced_height=dpi(170)` matching icon aspect ratio (208x256)
- Title: Geist SemiBold 13, amber `#e2b55a` via Pango markup
- Message: CommitMono Nerd Font Propo 12
- Spacing: `dpi(12)` between icon and text, `dpi(6)` between title and message
- Added `notification` config section in `anim_client.enable()` call

### `plans/somewm-one/themes/default/theme.lua`
- `notification_border_width = dpi(0)` — no border
- `notification_font = "CommitMono Nerd Font Propo 14"` (up from 11)
- `notification_icon_size = dpi(170)` (up from 128)
- `notification_max_width = dpi(700)` (up from 520)
- `notification_spacing = dpi(10)` (up from 8)
- Shadow tuned: `radius=30, offset_y=6, opacity=0.5` (down from 60/15/1.0)

## Technical Details

### Why `drawin._opacity` instead of `popup.opacity`?

Animation tick callbacks set `popup.opacity = t` which goes through wibox setter ->
sets `self["_opacity"] = t` -> propagates to `drawin["_opacity"] = t` -> C setter calls
`wlr_scene_buffer_set_opacity(t)`. This works.

BUT: naughty widget redraws happen asynchronously. Each redraw calls
`drawin_refresh_drawable()` in C which does:
```c
if (drawin->opacity >= 0)
    wlr_scene_buffer_set_opacity(drawin->scene_buffer, (float)drawin->opacity);
```
This re-applies the stored opacity, which is correct. However, the wibox Lua setter
also triggers `emit_signal("property::opacity")` which can cause cascading redraws
that fight with the animation.

Solution: bypass the wibox layer entirely during animation and write directly to
`drawin._opacity` (the C property). This is atomic and doesn't trigger widget redraws.

### Shadow animation

Shadow cannot be partially transparent during `d._opacity = 0` because SceneFX
renders shadow as a separate scene node — it doesn't inherit parent opacity.
Setting shadow `{ enabled = true, opacity = 0 }` initially, then interpolating
`opacity = t * target_opacity` in each tick produces a smooth synchronized fadeIn.

### Animation timing

`awesome.start_animation(duration, easing, tick_fn, done_fn)` is GPU frame-synced
via `wl_event_loop` timer + `CLOCK_MONOTONIC`. The easing function (ease-out-cubic)
makes the start fast and end slow, which feels natural for fadeIn.

## What's Upstream-Worthy?

### YES — `lua/wibox/init.lua` opacity propagation fix

This is a **real bug** affecting all wibox opacity on Wayland. Without this fix,
`wibox.opacity`, `awful.popup.opacity`, and `naughty.layout.box.opacity` have
zero visual effect. Any user trying to set notification/panel/popup transparency
hits this silently.

The fix is 4 lines, zero risk, and affects all three proxied properties
(border_width, border_color, opacity).

**Recommended:** File as upstream issue + PR on `trip-zip/somewm`.

### NO — everything else

The fadeIn animation, shadow config, font/layout changes, and anim_client module
are user-config level (somewm-one). They depend on `awesome.start_animation()`
which is already upstream, but the Lua integration is our custom module.

## Testing

Tested in:
- Nested sandbox (WLR_BACKENDS=wayland) — confirmed opacity animation via IPC
- Live DRM session (NVIDIA RTX 5070 Ti) — confirmed visual fadeIn + shadow
- Long text wrapping — confirmed at 700px max_width
- SceneFX compatibility — rounded corners and blur unaffected
