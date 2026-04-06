# somewm-shell Developer Guide

## What is somewm-shell?

A professional desktop shell for somewm built on **Quickshell (Qt6/QML)**.
It provides overlay panels (dashboard with tabbed interface, dock, control panel,
weather, wallpaper picker, collage viewer, OSD) as Wayland layer-shell surfaces.
It is an **overlay complement** to the existing wibar and Lua widgets in somewm-one
— it does not replace them.

No server, no HTTP, no WebSocket. Everything runs natively in the Quickshell process.

## Architecture

```
somewm (C compositor + Lua API)
│
├── Lua signals (client::manage, tag::selected, screen::focus)
│   └──► awful.spawn("qs ipc call somewm-shell:... ") [PUSH model]
│
├── somewm-client eval "lua code"  [shell QUERIES compositor]
│
└── wlr-layer-shell protocol       [shell panels are layer surfaces]

somewm-shell (Quickshell / Qt6 QML)
│
├── Services layer ─── data sources (IPC, D-Bus, procfs, HTTP, Wayland protocols)
│   └── QML property changes propagate automatically to UI
│
├── Core layer ─── Theme.qml, Anims.qml, Config.qml, Panels.qml, Constants.qml
│   └── Theme.qml watches theme.json via FileView (inotify)
│
└── Modules ─── Dashboard, Dock, ControlPanel, HotEdges, Weather, Wallpapers, Collage, OSD
    └── Each module = PanelWindow + Variants (per-screen instances)
```

### Dashboard Architecture (v2 — Caelestia-inspired)

The dashboard is a **bottom-slide tabbed panel** that replaces the old
separate dashboard, sidebar, and media panels. It uses MD3 BezierSpline
animations and a concave top-edge curve.

```
Dashboard (bottom-slide, full-width - margins)
├── ConcaveShape (top edge)
├── TabBar (Home | Performance | Media | Notifications)
└── StackLayout
    ├── HomeTab ──── ClockWidget, CPU/Mem rings, Calendar, QuickSettings, QuickLaunch, ClientList
    ├── PerformanceTab ── 4x ArcGauge (CPU, GPU, Memory, Storage) — LAZY polling
    ├── MediaTab ──── FrequencyVisualizer (Cava) + album art + controls — LAZY Cava
    └── NotificationsTab ── urgency colors, swipe-to-dismiss, expand/collapse
```

**CRITICAL: Lazy Polling** — All heavyweight data sources are gated by tab visibility:
- `SystemStats.perfTabActive` — GPU/temp/disk only poll when Performance tab is visible
- `CavaService.mediaTabActive` — Cava process only runs when Media tab is visible
- Base CPU/Memory polling stays always-on (wibar integration needs it)

### Dock Architecture

The dock is a **bottom-left corner popout** showing pinned favorites and running
applications with icons, activity dots, and multi-window preview cards.

```
Dock (bottom-left, border strip + ShapePath)
├── Border strip (full-width, always first to animate)
├── ShapePath background (grows LEFT, rounded top corners)
├── App icons row (Repeater over DockApps.dockItems ListModel)
│   ├── DockAppButton (icon + activity dots + hover zoom + glow)
│   └── DockSeparator (between pinned and running sections)
├── Preview popup (z:200, glass card with window info + optional screencopy)
│   └── PreviewCard (icon + title + close + focus status + live thumbnail*)
└── Tooltip overlay (app name, z:300)
```

*Live thumbnails via ScreencopyView require Hyprland protocol; on wlroots (somewm)
it gracefully falls back to rich info cards with focus status.

**Data source:** `DockApps` singleton uses `ToplevelManager` from `Quickshell.Wayland`
— direct Wayland protocol, no Lua IPC, instant reactivity.

**Pin persistence:** Pinned apps saved to `~/.config/quickshell/somewm/dock-pins.json`.
Right-click any icon to toggle pin. Default pins: alacritty, firefox-developer-edition,
thunar, code, spotify.

### Control Panel Architecture

The control panel is a **bottom-right corner popout** with quick-access sliders
for volume, microphone input, and screen brightness.

```
ControlPanel (bottom-right, border strip + ShapePath)
├── Border strip (full-width, same as dock/dashboard)
├── ShapePath background (grows RIGHT, rounded top corners)
└── Horizontal Row of ControlSlider components
    ├── Volume slider + mute toggle (Services.Audio)
    ├── Mic input slider + mute toggle (Services.Audio)
    └── Brightness slider (Services.Brightness)
```

### Hot Edges Architecture

Hot screen edges provide hover-triggered panel activation at the bottom screen edge.
Three invisible PanelWindows per screen, only active on the focused screen:

```
HotEdges (3 per-zone PanelWindows, focused screen only)
├── Center strip (full-width minus corners) → Dashboard [bottom of layer stack]
├── Left corner (140px) → Dock [on top of center]
└── Right corner (140px) → Control Panel [on top of center]
```

**Key design decisions:**
- **Per-zone PanelWindows** — each zone is a separate Wayland surface with its own
  `mask: Region { item: mouseArea }`. Avoids pointer-steal issues between overlapping surfaces.
- **Center declared FIRST** — in wlr-layer-shell, surfaces on the same layer stack by
  creation order. Center is created first (bottom), corners after (on top) so corners
  always win pointer events in overlap areas.
- **Focused screen only** — `visible: isActiveScreen` prevents ghost zones on inactive
  screens from stealing pointer events at shared screen edges (multi-monitor fix).
- **Dead pixel workaround** — `margins.bottom: -1` extends surface 1px past screen edge
  so cursor at absolute bottom pixel still triggers `wl_pointer.enter`.
- **Timer-based activation** — 250ms (corners) / 300ms (center) delay prevents accidental
  triggers when cursor passes through.

### Panel Architecture Pattern (Border Strip + ShapePath)

Dashboard, Dock, and ControlPanel share the same visual pattern:

1. **Border strip** — thin bar at screen bottom edge, animates first (350ms)
2. **ShapePath background** — rounded shape grows from strip (700ms, sequenced after strip)
3. **Content** — inside the shape, clips during animation

**Sequenced animation flow:**
```
Open:  strip appears (350ms) → pause → content grows (700ms)
Close: content shrinks (700ms) → pause → strip disappears (350ms)
```

This is implemented with `SequentialAnimation` + `PropertyAction` + `PauseAnimation`.

### Hover Trigger System

The dashboard's border strip contains hover triggers at its edges:
- **Left edge** (120px) → opens Dock panel
- **Right edge** (120px) → opens Control Panel

Both triggers are `MouseArea` elements with `hoverEnabled: true`, only visible when
the dashboard strip is shown and the target panel is not already open. When triggered,
panels enter "hoverMode" and auto-close on mouse exit (400ms timer).

### Wayland Input Mask & Hover Architecture

**CRITICAL LESSON LEARNED** — Wayland compositors only deliver input events to
areas defined by the panel's `mask: Region { item: clickTarget }`. This creates
unique challenges for hover-driven UIs:

**The flicker loop problem:** If a popup's visibility toggles the mask region,
the compositor alternately starts/stops sending hover events → rapid ENTERED/EXITED
cycling. This happens when popup visibility is bound to hover state.

**Solution — Unified clickTarget architecture:**

```qml
PanelWindow {
    mask: Region { item: clickTarget }

    Item {
        id: clickTarget
        anchors.fill: parent

        // ALL interactive elements MUST be children of clickTarget
        Item { id: wrapper; /* dock icons */ }

        // Preview popup INSIDE clickTarget at z:200
        Item {
            id: previewPopup
            z: 200  // above wrapper for hover priority

            // PERMISSIVE visibility: keep in mask while timer runs
            visible: shouldBeVisible || closeTimer.running || hoverHandler.hovered

            HoverHandler {
                id: hoverHandler
                // HoverHandler doesn't compete with child MouseAreas
                onHoveredChanged: {
                    if (hovered) closeTimer.stop()
                    else closeTimer.restart()
                }
            }
        }

        // Dismiss area at z:-1 (behind everything)
        MouseArea { z: -1; onClicked: close() }
    }

    // Visual layer BEHIND clickTarget (does not affect mask)
    Item {
        z: -1
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true }
        // ShapePath + border strip rendered here
    }

    Timer {
        id: closeTimer
        interval: 400
        onTriggered: {
            // Guard: only close if mouse is NOT on popup
            if (!hoverHandler.hovered) previewAppId = ""
        }
    }
}
```

**Key rules:**
1. **Unified z-order** — wrapper and popup both inside `clickTarget` so hover
   events flow correctly through the z-tree
2. **Permissive visibility** — popup stays visible (in mask) during close timer,
   preventing mask toggle → flicker loop
3. **HoverHandler over MouseArea** — `HoverHandler` doesn't compete with child
   `MouseArea` elements for hover events (critical for cards with close buttons)
4. **Visual layer at z:-1** — ShapePath + shadows render behind `clickTarget`,
   never intercepting events
5. **Guarded close timer** — `onTriggered` re-checks hover state before closing

### Panel Routing & Exclusivity

`Panels.qml` manages panel state with these rules:

- **Exclusive group:** `["dashboard", "wallpapers", "collage", "weather", "ai-chat"]`
  — opening one closes all others in the group
- **Non-exclusive:** `dock` and `controlpanel` can coexist with exclusive panels
- **Tab routing:** Legacy panel names are routed to dashboard tabs:
  - `"sidebar"` / `"notifications"` → Dashboard tab 0 / 3
  - `"media"` / `"performance"` → Dashboard tab 2 / 1
- **IPC target:** `somewm-shell:panels` — all functions callable from rc.lua

### Theme Chain

```
theme.lua (somewm-one)
    ↓  theme-export.sh (atomic JSON write)
theme.json (~/.config/somewm/themes/default/theme.json)
    ↓  FileView { watchChanges: true }
Theme.qml (singleton, QML property bindings)
    ↓  bindings
All UI elements auto-update
```

### Wallpaper Chain

```
Shell picker (WallpaperPanel.qml)
    ↓  somewm-client eval "require('fishlive.services.wallpaper').set_override(tag, path)"
Lua wallpaper service (fishlive/services/wallpaper.lua)
    ↓  per-tag override map, survives tag switches
    ↓  (optional) theme-export.sh if "Apply Theme" toggle is on
Theme.qml auto-reloads via FileView
```

### Data Flow: How Widgets Get Updated

There are 4 patterns — **no polling loops needed for most data**:

| Pattern | When to use | Example |
|---------|------------|---------|
| **Push IPC** | Compositor events | `qs ipc call somewm-shell:compositor invalidate` |
| **Timer + Process** | procfs (inotify doesn't work) | SystemStats reads `/proc/stat` every 2s |
| **FileView watchChanges** | Config/theme files | Theme.qml, Config.qml |
| **Quickshell built-in D-Bus** | MPRIS, PipeWire | Media.qml (MprisController) |
| **Wayland protocol** | Window management | DockApps uses ToplevelManager directly |

**Push IPC detail:** When a Lua signal fires in rc.lua (e.g., a window opens),
rc.lua immediately calls `awful.spawn("qs ipc call somewm-shell:compositor invalidate")`.
The shell's `Compositor.qml` has an `IpcHandler` that receives this, debounces rapid
events (50ms window), then runs `somewm-client eval` to fetch fresh state.

**Why no server?** QML property bindings are reactive — when `SystemStats.cpuPercent`
changes, every UI element bound to it re-renders automatically via the Qt scene graph.
No DOM, no virtual DOM, no diffing.

## Directory Structure

```
plans/somewm-shell/
├── shell.qml                  # Entry point (ShellRoot + ModuleLoaders)
├── deploy.sh                  # Sync to ~/.config/quickshell/somewm/
├── config.default.json        # Default module enable/disable + animation scale
├── theme.default.json         # Fallback theme colors
├── GUIDE.md                   # This file
│
├── core/                      # Framework singletons
│   ├── Theme.qml              # Colors, fonts, spacing, radii, helpers, dpiScale
│   ├── Anims.qml              # Animation durations + easing + MD3 BezierSpline curves
│   ├── Config.qml             # Module enable/disable, watches config.json
│   ├── Panels.qml             # Panel visibility + IPC handler + tab routing + exclusivity
│   ├── Constants.qml          # Dashboard dimensions, arc gauge sizes, carousel params
│   └── qmldir
│
├── components/                # Reusable UI primitives
│   ├── GlassCard.qml          # Base card (color layering for depth)
│   ├── ClickableCard.qml      # Card + click + active state
│   ├── SectionHeader.qml      # Accent dot + title
│   ├── SlidePanel.qml         # Slide-in panel
│   ├── ArcGauge.qml           # 270° arc gauge (Shape + PathAngleArc)
│   ├── ConcaveShape.qml       # Concave top-edge curve (Shape + PathArc CCW)
│   ├── TabBar.qml             # MD3 tab bar with animated indicator
│   ├── FrequencyVisualizer.qml # Radial audio frequency bars (Cava)
│   ├── WallpaperCarousel.qml  # Isometric skew carousel (ilyamiro-inspired)
│   ├── CircularProgress.qml   # Canvas-based progress ring
│   ├── Graph.qml              # Canvas-based line graph
│   ├── AnimatedBar.qml        # Horizontal progress bar
│   ├── PulseWave.qml          # Animated bar wave (media playing)
│   ├── MaterialIcon.qml       # Material Symbols Rounded icon
│   ├── ScrollArea.qml         # Scrollable area with custom scrollbar
│   ├── Separator.qml          # 1px divider line
│   ├── StateLayer.qml         # Hover/press feedback overlay
│   ├── StyledRect.qml         # Base rectangle
│   ├── StyledText.qml         # Base text with theme color
│   ├── Tooltip.qml            # Hover tooltip
│   ├── FadeLoader.qml         # Loader with fade-in
│   ├── ImageAsync.qml         # Async image with fallback
│   ├── StatCard.qml           # Stat display card
│   ├── Anim.qml               # NumberAnimation (respects Anims.scale)
│   ├── CAnim.qml              # ColorAnimation (respects Anims.scale)
│   └── qmldir                 # Component registration
│
├── services/                  # Data layer (singletons)
│   ├── Compositor.qml         # Clients, tags, focus (push IPC + tag-switch focus)
│   ├── Audio.qml              # Volume via wpctl (timer poll)
│   ├── Brightness.qml         # Brightness via brightnessctl
│   ├── Media.qml              # MPRIS media player (D-Bus)
│   ├── Network.qml            # WiFi/BT via nmcli
│   ├── SystemStats.qml        # CPU/mem (always-on) + GPU/temp/disk (lazy, perfTabActive)
│   ├── Weather.qml            # wttr.in via XMLHttpRequest
│   ├── Wallpapers.qml         # Wallpaper listing + set via Lua service + theme toggle
│   ├── CavaService.qml        # Cava audio visualizer (lazy, mediaTabActive)
│   ├── DockApps.qml           # Dock apps: ToplevelManager, pin persist, icon resolve
│   └── qmldir
│
├── modules/                   # Feature panels
│   ├── ModuleLoader.qml       # Lazy loader (enabled via config.json)
│   ├── dashboard/             # Bottom-slide tabbed dashboard
│   │   ├── Dashboard.qml      # Main panel (ConcaveShape + TabBar + StackLayout)
│   │   ├── HomeTab.qml        # Clock, stats, calendar, settings, launch, clients
│   │   ├── PerformanceTab.qml # 4x ArcGauge (CPU, GPU, Memory, Storage)
│   │   ├── MediaTab.qml       # FrequencyVisualizer + album art + controls
│   │   ├── NotificationsTab.qml # Urgency colors, swipe-dismiss, expand/collapse
│   │   ├── ClockWidget.qml    # Digital clock
│   │   ├── StatsGrid.qml      # Stat cards grid
│   │   ├── QuickLaunch.qml    # App launcher grid
│   │   ├── QuickSettings.qml  # WiFi/BT/DND toggles (moved from sidebar)
│   │   ├── CalendarWidget.qml # Calendar (moved from sidebar)
│   │   ├── ClientList.qml     # Open windows (click → focus + tag switch + close)
│   │   ├── MediaMini.qml      # Compact media widget for HomeTab
│   │   └── qmldir
│   ├── dock/                  # Bottom-left app dock
│   │   ├── Dock.qml           # Main panel (border strip + ShapePath + app row + preview)
│   │   └── qmldir
│   ├── controlpanel/          # Bottom-right quick controls
│   │   ├── ControlPanel.qml   # Main panel (border strip + ShapePath + sliders)
│   │   └── qmldir
│   ├── hotedges/              # Hot screen edges (bottom-edge hover triggers)
│   │   ├── HotEdges.qml      # Per-zone PanelWindows (left→dock, center→dashboard, right→controlpanel)
│   │   └── qmldir
│   ├── osd/                   # On-screen display (volume/brightness)
│   ├── weather/               # Weather panel
│   ├── wallpapers/            # Wallpaper picker (carousel + grid + preview)
│   ├── collage/               # Image collage viewer
│   ├── sidebar/ (DEPRECATED)  # Kept for test references, not loaded by shell.qml
│   ├── media/ (DEPRECATED)    # Subcomponents still referenced by some tests
│   └── qmldir
│
└── tests/
    └── test-all.sh            # Structural + syntax + import validation (no runtime)
```

## Services Reference

### DockApps.qml — Dock Application Manager

**Data source:** `ToplevelManager` from `Quickshell.Wayland` — direct Wayland
foreign-toplevel-management protocol. No Lua IPC overhead.

**Model:** `ListModel`-based `dockItems` with in-place updates. This prevents the
Repeater from destroying/recreating all delegates on every change (critical for
smooth hover interactions).

Each item in the model:
```
{ appId, icon, isPinned, isRunning, isActive, isSeparator, toplevelCount }
```

**Icon resolution cascade** (6 steps):
1. Hardcoded overrides (case fixes: alacritty→Alacritty, code→visual-studio-code, etc.)
2. `DesktopEntries.byId(appId)` — exact desktop entry match
3. `DesktopEntries.heuristicLookup(appId)` — fuzzy match
4. `Quickshell.iconPath(appId)` — direct XDG icon theme lookup
5. Normalize: strip reverse-domain prefix, lowercase, dots-to-hyphens
6. `steam_app_NNN` → `steam_icon_NNN` regex
7. Fallback: `"application-x-executable"` (for IconImage, NOT Material Symbol)

**No icon cache** — cascade is cheap after `DesktopEntries` loads. Avoids stale
entries. Hooks `DesktopEntries.onApplicationsChanged` to re-resolve on startup.

**Pin persistence:** Reads/writes `~/.config/quickshell/somewm/dock-pins.json`
via `Process` commands.

**API:**
```qml
DockApps.dockItems          // ListModel for Repeater
DockApps.itemCount          // Number of items
DockApps.getToplevels(appId) // Get raw toplevel objects for an app
DockApps.activateApp(appId)  // Activate/cycle windows (round-robin)
DockApps.launchApp(appId)    // Launch via DesktopEntries or direct exec
DockApps.togglePin(appId)    // Toggle pinned state
DockApps.isPinned(appId)     // Check if pinned
DockApps.resolveIcon(appId)  // Icon name for Quickshell.iconPath()
```

### Other Services

| Service | Data Source | Polling | Key Properties |
|---------|-----------|---------|----------------|
| **Compositor** | IPC (`somewm-client eval`) | Push + debounce | `clients`, `tags`, `focusedScreenName` |
| **SystemStats** | `/proc/stat`, `/proc/meminfo`, `nvidia-smi` | 2s always-on, GPU lazy | `cpuPercent`, `memPercent`, `gpuPercent`, `cpuTemp` |
| **Audio** | `wpctl` | 2s poll | `volume`, `muted`, `inputVolume`, `inputMuted` |
| **Brightness** | `brightnessctl` | on-change | `percent` |
| **Media** | MPRIS D-Bus | reactive | `title`, `artist`, `artUrl`, `playing` |
| **Network** | `nmcli` | 10s poll | `wifiName`, `wifiStrength`, `btConnected` |
| **Weather** | `wttr.in` HTTP | 30min | `temp`, `condition`, `forecast` |
| **Wallpapers** | filesystem scan | on-demand | `wallpapers`, `setWallpaper()` |
| **CavaService** | Cava process stdout | lazy (mediaTabActive) | `values`, `barCount` |
| **DockApps** | ToplevelManager (Wayland) | reactive | `dockItems`, `itemCount` |

## New Components (v2)

### ArcGauge — 270° arc progress

```qml
Components.ArcGauge {
    value: Services.SystemStats.cpuPercent / 100
    progressColor: Core.Theme.widgetCpu
    trackColor: Qt.rgba(Core.Theme.widgetCpuR, Core.Theme.widgetCpuG, Core.Theme.widgetCpuB, 0.15)
    lineWidth: Core.Constants.arcGaugeLineWidth

    // Center content slot
    Text { text: Services.SystemStats.cpuTemp + "°C"; anchors.centerIn: parent }
}
```

Shape-based with `PathAngleArc` (not Canvas). 270° sweep, animated with
600ms expressiveDefaultSpatial BezierSpline curve. Glow dot at progress endpoint.

### ConcaveShape — concave top edge

```qml
Components.ConcaveShape {
    curveHeight: Core.Constants.dashboardTopCurveHeight * Core.Theme.dpiScale
    fillColor: Core.Theme.surfaceBase
}
```

Creates inward curve using `PathArc` with `Counterclockwise` direction.
Used as dashboard panel background top edge.

### TabBar — MD3 animated tabs

```qml
Components.TabBar {
    currentIndex: 0
    tabs: [
        { icon: "\ue88a", label: "Home" },
        { icon: "\ue1b1", label: "Performance" },
        { icon: "\ue030", label: "Media" },
        { icon: "\ue7f4", label: "Notifications" }
    ]
    onTabChanged: (index) => stackLayout.currentIndex = index
}
```

3px animated indicator pill, emphasized BezierSpline. Mouse wheel tab cycling.

### FrequencyVisualizer — radial Cava bars

```qml
Components.FrequencyVisualizer {
    values: Services.CavaService.values
    barCount: Services.CavaService.barCount
    color: Core.Theme.accent
}
```

Repeater with radially positioned bars. 80ms animation for audio reactivity.
Idle pulse animation when no audio data.

### WallpaperCarousel — isometric skew

```qml
Components.WallpaperCarousel {
    wallpapers: Services.Wallpapers.wallpapers
    onWallpaperApplied: (path) => Services.Wallpapers.setWallpaper(path)
}
```

ListView with `SnapToItem`, `Matrix4x4` skew transform on non-current items.
Current: de-skewed, 1.4x scale. Others: skewed, opacity 0.5.

## Development Workflow

### Edit → Deploy → Restart

```bash
# 1. Edit source files in plans/somewm-shell/
vim plans/somewm-shell/modules/dock/Dock.qml

# 2. Deploy to Quickshell config directory
plans/somewm-shell/deploy.sh

# 3. Restart Quickshell (from a running somewm session)
kill $(pgrep -f 'qs -c somewm'); qs -c somewm -n -d &

# Or one-liner:
plans/somewm-shell/deploy.sh && kill $(pgrep -f 'qs -c somewm'); qs -c somewm -n -d &
```

**IMPORTANT:** Always edit in `plans/somewm-shell/`, never in `~/.config/quickshell/somewm/`.
The deploy script rsyncs source → config. Direct edits in config are overwritten.

### QML Cache

Quickshell caches compiled QML at `~/.cache/quickshell/qmlcache/`. After structural
changes (new files, renamed components, changed imports), clear the cache:

```bash
rm -rf ~/.cache/quickshell/qmlcache/
```

Then restart QS. Without clearing, QS may use stale cached versions.

### QS Respawn Behavior

somewm's rc.lua launches QS with `awful.spawn.once("qs -c somewm -n -d")`. This means:
- Killing QS with `kill`/`pkill` triggers respawn by somewm
- For quick restarts: just `kill $(pgrep -f 'qs -c somewm')` — it auto-respawns
- For a clean restart with cache clear:
  ```bash
  rm -rf ~/.cache/quickshell/qmlcache/ && kill $(pgrep -f 'qs -c somewm')
  ```
- `pkill -USR2 quickshell` can reload without full restart (simple changes only)

### Run Tests

```bash
# All tests (structural, syntax, imports — no running compositor needed)
bash plans/somewm-shell/tests/test-all.sh

# Verbose output
bash plans/somewm-shell/tests/test-all.sh --verbose
```

Tests validate: file structure, required files exist, QML import consistency,
singleton patterns, known bug fixes are still in place, rc.lua keybindings.
They do NOT require Quickshell or somewm running.

### View Logs

```bash
# Quickshell stderr (QML errors, console.log output)
# If launched with -d flag, debug output appears
qs -c somewm -n -d 2>&1 | tee /tmp/qs-shell.log

# Filter for errors
grep -i "error\|warn\|fail" /tmp/qs-shell.log

# Filter dock debug output
grep "DOCK" /tmp/qs-shell.log
```

### Keybindings (defined in rc.lua)

| Key | Action | Panel Type |
|-----|--------|------------|
| `Super+D` | Dashboard (Home tab) | Exclusive |
| `Super+X` | Dock (app launcher/switcher) | Non-exclusive |
| `Super+Z` | Control Panel (vol/mic/brightness) | Non-exclusive |
| `Super+Shift+M` | Dashboard → Media tab | Exclusive |
| `Super+Shift+E` | Weather panel | Exclusive |
| `Super+Shift+W` | Wallpaper picker (carousel) | Exclusive |
| `Super+Shift+O` | Collage viewer | Exclusive |
| `Super+Shift+A` | AI chat | Exclusive |
| `Super+C` | Close ALL panels | — |
| `Escape` | Close current panel | — |

**Exclusive** panels close each other (only one open at a time).
**Non-exclusive** panels (dock, controlpanel) can coexist with exclusive panels.

**Hot screen edges** (always active on focused screen):
- Bottom-left corner → opens Dock (250ms hover delay)
- Bottom-center strip → opens Dashboard (300ms hover delay)
- Bottom-right corner → opens Control Panel (250ms hover delay)

**Dashboard strip hover triggers** (when dashboard strip is visible):
- Hover left edge of strip → opens Dock
- Hover right edge of strip → opens Control Panel

## Animation System (Anims.qml)

### Standard durations (scaled by `Config.animations.scale`)

| Name | Base ms | Usage |
|------|---------|-------|
| `instant` | 80 | Micro-interactions |
| `fast` | 150 | Button feedback |
| `normal` | 250 | Default transitions |
| `smooth` | 400 | Panel slide-in |
| `slow` | 600 | Complex sequences |
| `expressiveSpatial` | 500 | Dashboard enter, carousel |
| `large` | 600 | Arc gauge animations |
| `extraLarge` | 1000 | Wallpaper transitions |

### Standard easing curves

| Name | Curve | Usage |
|------|-------|-------|
| `standard` | OutCubic | General transitions |
| `expressive` | OutBack | Panel enter (slight overshoot) |
| `decel` | OutQuart | Fade-in, appear |
| `accel` | InCubic | Panel exit, dismiss |
| `bounce` | OutBack | Playful interactions |

### MD3 BezierSpline curves (v2)

| Name | Usage |
|------|-------|
| `standard` | General MD3 transitions |
| `emphasized` | Panel enter, tab indicator |
| `emphasizedDecel` | Entrance emphasis |
| `emphasizedAccel` | Exit emphasis |
| `expressiveSpatial` | Dashboard, carousel, arc gauge |
| `expressiveFast` | Quick spatial moves |
| `expressiveEffects` | Decorative effects |

### Using animations

```qml
// Standard behavior
Behavior on opacity { Components.Anim {} }

// MD3 BezierSpline (for premium animations)
NumberAnimation {
    duration: Core.Anims.duration.expressiveSpatial
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Core.Anims.curves.expressiveSpatial
}

// Both respect Anims.scale. Set scale=0 for reduced motion.
```

## Theme System (Theme.qml)

### Color palette

All colors come from `theme.json` (exported from `theme.lua` via `theme-export.sh`).

| Property | Default | Usage |
|----------|---------|-------|
| `bgBase` | `#181818` | Wibar background, base panels |
| `bgSurface` | `#232323` | Elevated surfaces |
| `bgOverlay` | `#2e2e2e` | Highest elevation |
| `fgMain` | `#d4d4d4` | Primary text |
| `fgDim` | `#888888` | Secondary text |
| `fgMuted` | `#555555` | Disabled text, separators |
| `accent` | `#e2b55a` | Primary accent (warm amber) |
| `accentDim` | `#c49a3a` | Darker accent variant |
| `urgent` | `#e06c75` | Errors, DND active |
| `green` | `#98c379` | Success states |
| `glass1` | — | Glass card background |
| `glassBorder` | — | Glass card border |
| `glassAccentHover` | — | Accent hover highlight |
| `surfaceContainer` | — | Card backgrounds |
| `surfaceContainerHigh` | — | Hover state card backgrounds |
| `accentBorder` | — | Active/hover borders |

### Widget colors (matching wibar exactly)

| Property | Color | Widget |
|----------|-------|--------|
| `widgetCpu` | `#7daea3` | CPU stats (teal) |
| `widgetGpu` | `#98c379` | GPU stats (green) |
| `widgetMemory` | `#d3869b` | Memory stats (pink) |
| `widgetDisk` | `#e2b55a` | Disk/brightness (amber) |
| `widgetNetwork` | `#89b482` | Network/WiFi (sage) |
| `widgetVolume` | `#ea6962` | Volume (red) |

### DPI Scaling

Automatic based on primary screen resolution:
- FHD (1920px): `dpiScale = 1.0`
- QHD (2560px): `dpiScale = 1.15`
- 4K (3840px): `dpiScale = 1.35`

All sizes (`fontSize`, `spacing`, `radius`, `slider`) are multiplied by `dpiScale`.

## Wallpaper System

### Lua service (`fishlive/services/wallpaper.lua`)

Manages per-tag wallpaper state with override support. Replaces the old
inline wallpaper code in rc.lua.

```lua
-- API (callable via somewm-client eval):
local wp = require('fishlive.services.wallpaper')
wp.init(screen, wppath, "1.jpg")           -- called in screen setup
wp.set_override("1", "/path/to/wall.jpg")  -- override tag 1 wallpaper
wp.clear_override("1")                     -- revert to theme default
wp.get_current()                           -- current wallpaper path
wp.get_overrides_json()                    -- JSON override map
```

### Shell integration (`Wallpapers.qml`)

- `setWallpaper(path)` — sets override for currently selected tag
- `setWallpaperForTag(tag, path)` — sets for specific tag
- `applyTheme` toggle — when ON, runs `theme-export.sh` after wallpaper change
- `clearOverride(tag)` — reverts to theme default

### Wallpaper picker (WallpaperPanel.qml)

Two views:
- **Carousel** (default) — isometric skew carousel (ilyamiro-inspired)
- **Grid** — traditional thumbnail grid (toggle via view button)

Features:
- "Apply Theme" toggle pill — controls whether theme colors update with wallpaper
- Apply button + current wallpaper indicator
- Preview overlay (right-click in grid view)

## How to Add a New Module

### 1. Create the module directory

```
plans/somewm-shell/modules/mymodule/
├── MyModule.qml    # Main panel
└── qmldir          # Module registration
```

### 2. Write the panel (overlay example)

```qml
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../components" as Components

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel
        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("mymodule") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeOut.running
        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:mymodule"
        WlrLayershell.keyboardFocus: shouldShow
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors { top: true; bottom: true; left: true; right: true }
        mask: Region { item: backdrop }

        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.3)
            opacity: panel.shouldShow ? 1.0 : 0.0
            focus: panel.shouldShow
            Keys.onEscapePressed: Core.Panels.close("mymodule")

            Behavior on opacity {
                NumberAnimation {
                    id: fadeOut
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.standard
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: Core.Panels.close("mymodule")
                onWheel: (wheel) => { wheel.accepted = true }
            }

            Components.GlassCard {
                anchors.centerIn: parent
                width: Math.round(500 * Core.Theme.dpiScale)
                height: Math.round(400 * Core.Theme.dpiScale)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Core.Theme.spacing.xl
                }
            }
        }
    }
}
```

### 3. Register in shell.qml + config + Panels exclusive list + rc.lua keybinding

See existing modules for reference. Remember:
- Add `import "modules/mymodule" as MyModuleModule` in `shell.qml`
- Add `ModuleLoader` entry in `shell.qml`
- Add `qmldir` with `MyModule MyModule.qml`
- Add to exclusive group in `Panels.qml` if it should close other panels
- Add keybinding in `plans/somewm-one/rc.lua`
- Run `deploy.sh` after all changes

## Design Principles

### DO

- **Color layering** for depth — `surfaceBase → surfaceContainer → surfaceContainerHigh`
- **MD3 BezierSpline curves** for premium animations (dashboard, carousel, gauges)
- **Lazy polling** — NEVER poll data when panel/tab is not visible
- **Flat colors** — single accent color on interactive elements, neutral elsewhere
- **Minimal borders** — 1px at 6% opacity, only for structure
- **dpiScale on all sizes** — `Math.round(N * Core.Theme.dpiScale)` for hardcoded px values
- **Smooth animations** — 250-500ms with eased curves, never linear
- **Glass cards** for popups/overlays — `glass1` background + `glassBorder`
- **Unified clickTarget** for Wayland mask — all interactive children in one tree

### DO NOT

- ~~Drop shadows~~ — use color layering instead (exception: dock preview, control panel)
- ~~Background polling~~ — gate with visibility flags (perfTabActive, mediaTabActive)
- ~~Gradients on buttons~~ — flat color only
- ~~Glow effects~~ — never (except subtle arc gauge endpoint dot and dock hover glow)
- ~~Hardcoded pixel sizes~~ — always multiply by dpiScale
- ~~MouseArea for hover tracking on containers with interactive children~~ — use HoverHandler
- ~~Visibility bound directly to hover state~~ — use permissive visibility pattern

## Dock-Specific Implementation Notes

### Inline Components

The Dock uses QML `component` declarations for delegate types to keep everything
in a single file (avoiding import complexity for tightly-coupled elements):

- **`DockSeparator`** — thin vertical line between pinned and running sections
- **`DockAppButton`** — icon + activity dots + hover zoom + glow + click handlers
- **`PreviewCard`** — window info card with icon, title, close button, focus status,
  optional ScreencopyView live thumbnail

### DockAppButton Interactions

| Action | Behavior |
|--------|----------|
| **Hover** | Scale 1.0→1.25 (OutBack spring), glass accent glow, tooltip |
| **Press** | Scale→0.85 (80ms snap) |
| **Left click (not running)** | Launch app, close dock |
| **Left click (1 window)** | Activate window, close dock |
| **Left click (multi)** | Open preview popup |
| **Right click** | Toggle pin/unpin |
| **Middle click** | Launch new instance |
| **Hover (multi, 150ms)** | Auto-open preview popup |

### Preview Popup Behavior

- Opens on hover (150ms delay) or click for multi-window apps
- Shows one PreviewCard per toplevel window
- Glass background with shadow, scale+opacity entry animation
- Cards have staggered entry animation (scale 0.85→1.0, OutBack)
- Close timer: 400ms after mouse exits (guarded — re-checks hover)
- Click card → activate window + close dock
- Close button on each card → close that window

## Quick Reference

```bash
# Deploy
plans/somewm-shell/deploy.sh

# Deploy + restart QS
plans/somewm-shell/deploy.sh && kill $(pgrep -f 'qs -c somewm')

# Deploy + clear cache + restart
plans/somewm-shell/deploy.sh && rm -rf ~/.cache/quickshell/qmlcache/ && kill $(pgrep -f 'qs -c somewm')

# Run tests
bash plans/somewm-shell/tests/test-all.sh

# Check current theme
cat ~/.config/somewm/themes/default/theme.json

# Export theme from Lua to JSON
bash plans/theme-export.sh

# IPC test
qs ipc -c somewm call somewm-shell:panels toggle dashboard

# Config location
~/.config/quickshell/somewm/config.json

# QML cache (clear after structural changes)
~/.cache/quickshell/qmlcache/

# Dock pins
~/.config/quickshell/somewm/dock-pins.json
```
