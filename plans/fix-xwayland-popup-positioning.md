# Fix: XWayland Position Sync for Popup Menu Placement

**Branch:** `fix/steam-menu-popup-positioning`
**Status:** Partial fix (see [Open Problem](#open-problem) below)
**Date:** 2026-02-15
**Author:** Antonin Fischer (raven2cz) + Claude

## Problem Description

XWayland (X11) clients that use popup menus — most notably **Steam** — display
their menus at incorrect screen positions after the compositor moves the window.
Steam's top navigation bar (STORE, LIBRARY, COMMUNITY, etc.) creates dropdown
menus on hover. These menus use the parent window's X11 position to calculate
where to appear. If the compositor moves the window (via tiling layout, tag
switch, or manual resize) without notifying X11, the popup appears at the
**old** position, sometimes flying off-screen to the right.

### Root Cause

In the original somewm code, `client_set_size()` in `client.h` only sent
`wlr_xwayland_surface_configure()` when the **size** changed. Position-only
changes were never communicated to XWayland. The X11 client retained its
original map position in its internal cache, causing all popup placement to
reference stale coordinates.

The compositor moves windows via the scene graph
(`wlr_scene_node_set_position()`), which is a Wayland-level operation invisible
to X11 clients. X11 clients must be explicitly told their new position via
`wlr_xwayland_surface_configure()` which sends a synthetic `ConfigureNotify`
event per ICCCM 4.1.5.

## Fix Details

### 1. Position-aware `client_set_size()` (`client.h`)

The core fix: `client_set_size()` now checks both size AND position, and sends
`wlr_xwayland_surface_configure()` whenever either changes. The position is
calculated as the content area origin: `geometry.x + border_width + titlebar`.

```c
// Before: only checked size
if (width == c->surface.xwayland->width
        && height == c->surface.xwayland->height)
    return 0;
wlr_xwayland_surface_configure(c->surface.xwayland,
        c->geometry.x + c->bw, c->geometry.y + c->bw, width, height);

// After: checks size AND position, includes titlebar offset
int tl = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_LEFT].size;
int tt = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_TOP].size;
int16_t cx = c->geometry.x + c->bw + tl;
int16_t cy = c->geometry.y + c->bw + tt;
if (width == c->surface.xwayland->width
        && height == c->surface.xwayland->height
        && cx == c->surface.xwayland->x
        && cy == c->surface.xwayland->y)
    return 0;
wlr_xwayland_surface_configure(c->surface.xwayland, cx, cy, width, height);
```

This runs in `apply_geometry_to_wlroots()` on every refresh cycle. For X11
clients, `c->resize` is always 0 (XWayland configure returns no serial), so
`client_set_size()` runs on every frame. The overhead is minimal: 4 field
accesses + 4 integer comparisons in the common no-change case.

### 2. Immediate position sync in Lua path (`objects/client.c`)

When Lua code changes client geometry (e.g., layout arrange, `c:geometry({})`),
`client_resize_do()` updates `c->geometry` but defers the wlroots scene update
to the next refresh cycle. For X11 clients, we now send an immediate position
configure so the X server knows the new position without waiting for the
refresh:

```c
if (c->client_type == X11 && c->surface.xwayland
        && (old_geometry.x != geometry.x || old_geometry.y != geometry.y)) {
    int16_t cx = geometry.x + c->bw + titlebar_left;
    int16_t cy = geometry.y + c->bw + titlebar_top;
    if (cx != c->surface.xwayland->x || cy != c->surface.xwayland->y) {
        wlr_xwayland_surface_configure(c->surface.xwayland,
                cx, cy,
                c->surface.xwayland->width,
                c->surface.xwayland->height);
    }
}
```

This only fires when position actually changes — not a hot path.

## Performance Considerations

- **`client_set_size()` (per-frame, per-client):** Adds 4 field reads +
  4 comparisons for X11 clients. The configure call only fires on actual
  position/size change. No syscalls in the common no-change case.
- **`client_resize_do()` (Lua geometry change):** Only fires when position
  changes. Not per-frame.
- **No `xcb_flush()` calls:** We rely on wlroots' deferred
  `xwm_schedule_flush()` which flushes on the next event loop iteration.
  Direct `xcb_flush()` was tested but provided no measurable improvement
  (see [Open Problem](#open-problem)).

## Open Problem

### First-hover stale position after window move

After the compositor moves a window (e.g., tiling rearrangement), the **first**
hover over a menu button may still show the popup at the old position. Moving to
a second menu item and back corrects it. Clicking the window also corrects it.

**This is a known, cross-compositor XWayland limitation:**

- **KDE/KWin** — [Bug 454358](https://www.mail-archive.com/kde-bugs-dist@kde.org/msg933991.html):
  "Opened menu detaches when moving app's window for some apps on XWayland" —
  marked **RESOLVED INTENTIONAL** (unfixable for XWayland).
- **Hyprland** — [Discussion #13000](https://github.com/hyprwm/Hyprland/discussions/13000):
  "Steam menus out of alignment" — maintainer response: "xwayland funnies.
  It is what it is."
- **Sway** — Uses the same deferred `xwm_schedule_flush()` with no special
  XWayland popup handling.

**Why it happens:** Steam uses Chromium Embedded Framework (CEF) which processes
X11 events lazily in its own event loop. Even though we send
`ConfigureNotify` immediately when position changes, CEF may not process it
before the hover event triggers popup creation. The first interaction forces
CEF's event loop to catch up, so subsequent hovers work correctly.

**Attempted approaches that did NOT solve the remaining issue:**

1. **Immediate `xcb_flush()`** after `wlr_xwayland_surface_configure()` using
   `wlr_xwayland_get_xwm_connection()` — ensures XCB data reaches XWayland
   sooner, but Steam/CEF still processes it lazily.
2. **Position sync on keyboard focus change** (`focusclient()`) — sends
   configure when switching to X11 client. No improvement.
3. **Position sync on pointer enter** (`pointerfocus()`) — sends configure when
   cursor enters X11 client. No improvement.

**Potential future approaches for investigation:**

- **wlroots `_XWAYLAND_ALLOW_COMMITS` protocol** — KWin uses this for frame
  synchronization ([blog post](https://blog.vladzahorodnii.com/2024/10/28/improving-xwayland-window-resizing/)),
  but it only applies to managed windows, not override-redirect popups.
- **Sending additional X11 events** (e.g., synthetic `PropertyNotify`) to force
  CEF event loop processing — untested, may have side effects.
- **XWayland protocol extension** for popup positioning — would require upstream
  XWayland changes. The `xdg_positioner` protocol solves this for native
  Wayland clients but is unavailable to X11 apps.

## Files Changed

| File | Change |
|------|--------|
| `client.h` | `client_set_size()`: position-aware configure with titlebar offset |
| `objects/client.c` | `client_resize_do()`: immediate X11 position sync on Lua geometry change |
| `tests/test-xwayland-position-sync.lua` | Integration test: position sync, rapid moves, focus cycle stability |

## Related Upstream Issues

- **#196** — Titlebar beyond width of client bug (related: titlebar geometry)
- **#160** — Surface Type Architecture (may affect future XWayland handling)
- **#215** — Popup dialog crash (different root cause, but same popup area)

## How to Test

```bash
# Build and install
ninja -C build && sudo make install

# Launch from TTY
dbus-run-session somewm 2>&1 | tee /tmp/somewm.log

# Open Steam, move the window (e.g., switch tags or rearrange layout)
# Hover over STORE/LIBRARY/COMMUNITY menus
# First hover may show popup at old position (known limitation)
# Second hover and all subsequent hovers should be correct
```

### Integration test

```bash
make test-one TEST=tests/test-xwayland-position-sync.lua
```

## Commits

- `2555f60` fix: XWayland position sync for popup menu placement
- `bca0b8b` test: XWayland position sync integration test
- `cef753a` docs: add XWayland popup positioning fix documentation

## Upstream Issue

- **[trip-zip/somewm#231](https://github.com/trip-zip/somewm/issues/231)** — XWayland clients receive no position updates — popup menus appear at stale coordinates

## References

- [ICCCM 4.1.5](https://www.x.org/releases/X11R7.6/doc/xorg-docs/specs/ICCCM/icccm.html) —
  Synthetic ConfigureNotify for position-only changes
- [wlroots xwm.c:2112](https://github.com/swaywm/wlroots/blob/master/xwayland/xwm.c) —
  `wlr_xwayland_surface_configure()` implementation
- [Sway transaction.c](https://github.com/swaywm/sway/blob/master/sway/desktop/transaction.c) —
  XWayland position change detection (lines 800-811)
- [KDE Blog: Improving Xwayland window resizing](https://blog.vladzahorodnii.com/2024/10/28/improving-xwayland-window-resizing/) —
  KWin's `_XWAYLAND_ALLOW_COMMITS` approach
- [KDE Blog: Geometry handling in KWin/Wayland](https://blog.vladzahorodnii.com/2022/01/15/geometry-handling-in-kwin-wayland/)
- [labwc PR #428](https://github.com/labwc/labwc/pull/428) —
  Similar fix for unmanaged window position handling
