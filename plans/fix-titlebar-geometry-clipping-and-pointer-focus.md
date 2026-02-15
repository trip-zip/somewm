# Fix: Titlebar geometry, surface clipping, and pointer focus

**Issue:** https://github.com/trip-zip/somewm/issues/230
**Fork branch:** https://github.com/raven2cz/somewm/tree/fix/titlebar-geometry-clipping-and-pointer-focus
**Commits:**
- [`f213c3e`](https://github.com/raven2cz/somewm/commit/f213c3e) fix: surface clip accounts for titlebars and border width
- [`826c64b`](https://github.com/raven2cz/somewm/commit/826c64b) fix: titlebar-aware geometry bounds and fullscreen rendering
- [`997d308`](https://github.com/raven2cz/somewm/commit/997d308) fix: pointer focus over titlebars, borders, and on client map
- [`754d127`](https://github.com/raven2cz/somewm/commit/754d127) feat: client aspect ratio constraint for resize

## Summary

Multiple interrelated bugs cause incorrect rendering, lost pointer focus, and
crashes when using clients with titlebars (mpv, GNOME Calculator, any client
with `awful.titlebar`). The root cause is that the compositor's C-side geometry,
clipping, and pointer focus code was written before titlebars were fully
integrated, and never updated to account for the space titlebars occupy inside
client geometry.

**Affected clients:** Any client with titlebars enabled (mpv, GNOME Calculator,
Nautilus, etc.), and fullscreen clients that previously had titlebars.

## Bug 1: Surface bleeds past bottom/right borders (visual corruption)

### Symptoms
- Bottom border appears to "creep into" the application content
- At small window sizes, the bottom border visually overlaps the app
- The effect is exactly `titlebar_top` pixels (typically 29px) of overflow

### Root Cause

`client_get_clip()` in `client.h` computes the clip rectangle that restricts
how much of the client surface is visible. The surface scene node is positioned
at `(bw + titlebar_left, bw + titlebar_top)` within the parent, but the clip
dimensions were `geometry - bw` instead of `geometry - 2*bw - titlebars`:

```c
// BEFORE (wrong):
.width = c->geometry.width - c->bw,
.height = c->geometry.height - c->bw,

// The visible bottom edge in parent coords becomes:
//   bw + titlebar_top + (geometry.height - bw) = titlebar_top + geometry.height
// This extends titlebar_top pixels PAST the bottom of the window!
```

### Fix

**File:** `client.h` - `client_get_clip()`

Compute clip as the content area size (geometry minus borders minus all four
titlebars), with fullscreen handling (titlebars are hidden in fullscreen):

```c
int tl = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_LEFT].size;
int tt = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_TOP].size;
int tr = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_RIGHT].size;
int tb = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
int cw = c->geometry.width - 2 * c->bw - tl - tr;
int ch = c->geometry.height - 2 * c->bw - tt - tb;
if (cw < 1) cw = 1;
if (ch < 1) ch = 1;
```

Now the visible area correctly ends at `(geometry.width - bw - tr, geometry.height - bw - tb)` -- exactly adjacent to the borders.

## Bug 2: Crash on extreme resize (unsigned integer underflow)

### Symptoms
- Resizing a window with titlebars to very small sizes crashes the compositor
- The crash occurs in wlroots when it receives huge width/height values
- Only affects windows with titlebars; windows without titlebars hit a
  reasonable minimum of `1 + 2*bw = 3px`

### Root Cause

Two issues in `somewm.c`:

1. **`applybounds()`** enforced minimum geometry of `1 + 2*bw` (e.g., 3px) but
   didn't account for titlebar sizes. A window with a 29px titlebar and bw=1
   needs at least `1 + 2 + 29 = 32px` height, but was allowed to shrink to 3px.

2. **`apply_geometry_to_wlroots()`** computed surface size by subtracting
   borders and titlebars from geometry without checking for underflow. When
   geometry was smaller than `2*bw + titlebars`, the subtraction produced a
   negative value that was passed as unsigned to `client_set_size()`, causing
   wlroots to receive enormous values.

### Fix

**File:** `somewm.c` - `applybounds()` (~line 415)

Include all four titlebar sizes in the minimum geometry:

```c
int min_w = 1 + 2 * (int)c->bw
    + c->titlebar[CLIENT_TITLEBAR_LEFT].size
    + c->titlebar[CLIENT_TITLEBAR_RIGHT].size;
int min_h = 1 + 2 * (int)c->bw
    + c->titlebar[CLIENT_TITLEBAR_TOP].size
    + c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
```

**File:** `somewm.c` - `apply_geometry_to_wlroots()` (~line 3920)

Defense-in-depth: compute surface dimensions as signed int and clamp to >= 1:

```c
int sw = c->geometry.width - 2 * c->bw - titlebar_left - titlebar_right;
int sh = c->geometry.height - 2 * c->bw - titlebar_top - titlebar_bottom;
if (sw < 1) sw = 1;
if (sh < 1) sh = 1;
c->resize = client_set_size(c, sw, sh);
```

## Bug 3: Pointer focus lost over titlebars and borders

### Symptoms
- Moving the mouse over a titlebar or border clears pointer focus
- The client stops receiving scroll events and hover effects
- mpv video controls don't appear on hover when cursor is over titlebar
- Mouse cursor may change to default arrow unexpectedly

### Root Cause

`pointerfocus()` in `somewm.c` receives `surface = NULL` when the cursor is
over compositor-drawn decorations (titlebars, borders) because these are
`wlr_scene_rect` nodes, not `wlr_surface` nodes. The function immediately
cleared pointer focus:

```c
if (!surface) {
    wlr_seat_pointer_notify_clear_focus(seat);
    return;
}
```

### Fix

**File:** `somewm.c` - `pointerfocus()` (~line 3752)

When surface is NULL but a client exists (cursor over titlebar/border), fall
back to the client's main surface with recalculated coordinates:

```c
if (!surface && c && client_surface(c) && client_surface(c)->mapped) {
    surface = client_surface(c);
    sx = cursor->x - c->geometry.x - c->bw;
    sy = cursor->y - c->geometry.y - c->bw;
}
```

## Bug 4: Pointer focus not delivered on map when cursor is already in geometry

### Symptoms
- Opening a new window under the cursor doesn't give it pointer focus
- Must move the mouse out and back in to get hover effects

### Root Cause

`mapnotify()` emits Lua signals and sets keyboard focus, but never checks
whether the cursor is already within the new client's geometry. Without a
motion event, `pointerfocus()` is never called for the new window.

### Fix

**File:** `somewm.c` - `mapnotify()` (~line 3320)

After emitting `client::map`, check if cursor is within the new client's
geometry and deliver pointer focus directly:

```c
if (client_surface(c) && client_surface(c)->mapped
        && cursor->x >= c->geometry.x && ...)
    pointerfocus(c, client_surface(c), sx, sy, 0);
```

## Bug 5: wlroots pointer enter race condition

### Symptoms
- First pointer enter after client creation is silently dropped
- Client never receives `wl_pointer.enter` even though
  `seat->pointer_state.focused_surface` is set correctly

### Root Cause

`wlr_seat_pointer_enter()` sets `focused_surface` and `focused_client` even
if the client hasn't yet bound `wl_pointer` (the `pointers` list is empty).
On subsequent calls, it sees `focused_surface == surface` and returns early
(no-op), but the `wl_pointer.enter` event was never actually sent because
there were no pointer resources to send it to.

### Fix

**File:** `somewm.c` - `pointerfocus()` (~line 3770)

Detect stale pointer focus (surface matches but no pointer resources) and
clear it so `wlr_seat_pointer_enter()` re-delivers:

```c
if (seat->pointer_state.focused_surface == surface) {
    struct wlr_seat_client *sc = seat->pointer_state.focused_client;
    if (!sc || wl_list_empty(&sc->pointers)) {
        wlr_seat_pointer_notify_clear_focus(seat);
    }
}
```

## Bug 6: Fullscreen rendering broken with titlebars

### Symptoms
- Fullscreen windows show smaller than expected (titlebar space subtracted)
- Titlebar scene nodes remain visible as artifacts over fullscreen content

### Root Cause

`apply_geometry_to_wlroots()` always subtracted titlebar sizes from the
surface configure size, even in fullscreen mode. And
`client_update_titlebar_positions()` kept titlebar scene nodes enabled
regardless of fullscreen state.

### Fix

**File:** `somewm.c` - `apply_geometry_to_wlroots()` (~line 3886)

Zero out titlebar sizes when fullscreen, and use a separate fullscreen path
that only subtracts borders:

```c
titlebar_left = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_LEFT].size;
titlebar_top = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_TOP].size;
// ...
if (c->fullscreen) {
    c->resize = client_set_size(c, geo.width - 2*bw, geo.height - 2*bw);
} else { ... }
```

**File:** `objects/client.c` - `client_update_titlebar_positions()` (~line 3948)

Hide titlebar nodes when fullscreen:

```c
bool visible = c->titlebar[bar].size > 0 && !c->fullscreen;
```

## Feature: Aspect ratio constraint (Lua API)

### Motivation

mpv and other video players need to maintain aspect ratio during resize.
Without this, resizing mpv distorts the video or leaves black bars that change
size unpredictably.

### Implementation

**New Lua property:** `client.aspect_ratio` (number, 0 = disabled)

```lua
-- In rc.lua rules:
client.connect_signal("manage", function(c)
    if c.class == "mpv" then
        c.aspect_ratio = c.width / c.height
    end
end)
```

**Files:**
- `objects/client.h` - new `double aspect_ratio` field on `client_t`
- `objects/client.c` - Lua getter/setter, enforcement in `client_resize()`
- `somewm.c` - enforcement in `resize()` (C interactive resize path)

Aspect ratio is enforced in both the Lua resize path (`client_resize()`) and
the C interactive resize path (`resize()`) with a 1-pixel epsilon tolerance
to prevent rounding oscillation.

## Files Changed

| File | Changes |
|------|---------|
| `client.h` | `client_get_clip()` - titlebar-aware clip rectangle |
| `somewm.c` | `applybounds()` - titlebar-aware minimum geometry |
| `somewm.c` | `apply_geometry_to_wlroots()` - fullscreen path, underflow clamp |
| `somewm.c` | `pointerfocus()` - titlebar/border fallback, pointer race fix |
| `somewm.c` | `mapnotify()` - pointer focus on map |
| `somewm.c` | `resize()` - aspect ratio enforcement |
| `objects/client.c` | `client_resize()` - aspect ratio enforcement |
| `objects/client.c` | `client_update_titlebar_positions()` - fullscreen hide |
| `objects/client.c` | Lua `aspect_ratio` property |
| `objects/client.h` | `aspect_ratio` field on `client_t` |

## Testing

Tested in nested compositor sandbox (`WLR_BACKENDS=wayland`) with:
- **GNOME Calculator** - titlebars render correctly, bottom border stays at edge
  during resize, no crash at minimum size
- **mpv** - titlebar + pointer focus works, fullscreen correct, aspect ratio
  maintained during resize
- **Alacritty** - no regression in non-titlebar windows

### Test steps
1. Launch any client with titlebars (e.g., GNOME Calculator)
2. Resize to very small size -> window stops at minimum titlebar+border size, no crash
3. Check bottom border -> flush with window edge, no overlap with content
4. Move mouse over titlebar -> pointer focus maintained, no cursor flicker
5. Fullscreen (Super+F) -> no titlebar artifacts, surface fills entire screen
6. mpv with aspect ratio -> resize maintains video proportions
