# somewm-shell Developer Guide

## What is somewm-shell?

A professional desktop shell for somewm built on **Quickshell (Qt6/QML)**.
It provides overlay panels (dashboard with tabbed interface, weather, wallpaper picker,
collage viewer, OSD) as Wayland layer-shell surfaces. It is an **overlay complement**
to the existing wibar and Lua widgets in somewm-one — it does not replace them.

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
├── Services layer ─── data sources (IPC, D-Bus, procfs, HTTP)
│   └── QML property changes propagate automatically to UI
│
├── Core layer ─── Theme.qml, Anims.qml, Config.qml, Panels.qml
│   └── Theme.qml watches theme.json via FileView (inotify)
│
└── Modules ─── Dashboard (tabbed), Weather, Wallpapers, Collage, OSD
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

### Panel routing

Old keybindings (`toggle sidebar`, `toggle media`) are **routed** through
`Panels.toggle()` to the appropriate dashboard tab:
- `sidebar` / `notifications` → Dashboard tab 0 (Home) / tab 3 (Notifications)
- `media` → Dashboard tab 2 (Media)

### Theme chain

```
theme.lua (somewm-one)
    ↓  theme-export.sh (atomic JSON write)
theme.json (~/.config/somewm/themes/default/theme.json)
    ↓  FileView { watchChanges: true }
Theme.qml (singleton, QML property bindings)
    ↓  bindings
All UI elements auto-update
```

### Wallpaper chain

```
Shell picker (WallpaperPanel.qml)
    ↓  somewm-client eval "require('fishlive.services.wallpaper').set_override(tag, path)"
Lua wallpaper service (fishlive/services/wallpaper.lua)
    ↓  per-tag override map, survives tag switches
    ↓  (optional) theme-export.sh if "Apply Theme" toggle is on
Theme.qml auto-reloads via FileView
```

### Data flow: how widgets get updated

There are 4 patterns — **no polling loops needed for most data**:

| Pattern | When to use | Example |
|---------|------------|---------|
| **Push IPC** | Compositor events | `qs ipc call somewm-shell:compositor invalidate` |
| **Timer + Process** | procfs (inotify doesn't work) | SystemStats reads `/proc/stat` every 2s |
| **FileView watchChanges** | Config/theme files | Theme.qml, Config.qml |
| **Quickshell built-in D-Bus** | MPRIS, PipeWire | Media.qml (MprisController) |

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
│   ├── Panels.qml             # Panel visibility state + IPC handler + tab routing
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
��
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
���   └── qmldir
│
├── modules/                   # Feature panels
│   ├��─ ModuleLoader.qml       # Lazy loader (enabled via config.json)
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
│   ├── sidebar/ (DEPRECATED)  # Kept for test references, not loaded by shell.qml
│   ├── media/ (DEPRECATED)    # Subcomponents still referenced by some tests
│   ├── osd/                   # On-screen display (volume/brightness)
│   ├── weather/               # Weather panel
│   ├── wallpapers/            # Wallpaper picker (carousel + grid + preview)
│   ├── collage/               # Image collage viewer
│   └── qmldir
│
└── tests/
    └── test-all.sh            # Structural + syntax + import validation (no runtime)
```

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
vim plans/somewm-shell/modules/dashboard/PerformanceTab.qml

# 2. Deploy to Quickshell config directory
plans/somewm-shell/deploy.sh

# 3. Restart Quickshell (from a running somewm session)
kill $(pgrep -f 'qs -c somewm'); qs -c somewm -n -d &

# Or one-liner:
plans/somewm-shell/deploy.sh && kill $(pgrep -f 'qs -c somewm'); qs -c somewm -n -d &
```

**IMPORTANT:** Always edit in `plans/somewm-shell/`, never in `~/.config/quickshell/somewm/`.
The deploy script rsyncs source → config. Direct edits in config are overwritten.

### Run tests

```bash
# All tests (structural, syntax, imports — no running compositor needed)
bash plans/somewm-shell/tests/test-all.sh

# Verbose output
bash plans/somewm-shell/tests/test-all.sh --verbose
```

Tests validate: file structure, required files exist, QML import consistency,
singleton patterns, known bug fixes are still in place, rc.lua keybindings.
They do NOT require Quickshell or somewm running.

### View logs

```bash
# Quickshell stderr (QML errors, console.log output)
# If launched with -d flag, debug output appears
qs -c somewm -n -d 2>&1 | tee /tmp/qs-shell.log

# Filter for errors
grep -i "error\|warn\|fail" /tmp/qs-shell.log
```

### Keybindings (defined in rc.lua)

| Key | Action |
|-----|--------|
| `Super+D` | Dashboard (Home tab) |
| `Super+Z` | Dashboard → Notifications tab |
| `Super+Shift+M` | Dashboard → Media tab |
| `Super+Shift+E` | Weather panel |
| `Super+Shift+W` | Wallpaper picker (carousel) |
| `Super+Shift+O` | Collage viewer |
| `Super+Shift+A` | AI chat |
| `Super+C` | Close all panels |
| `Escape` | Close current panel |

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

### Widget colors (matching wibar exactly)

| Property | Color | Widget |
|----------|-------|--------|
| `widgetCpu` | `#7daea3` | CPU stats (teal) |
| `widgetGpu` | `#98c379` | GPU stats (green) |
| `widgetMemory` | `#d3869b` | Memory stats (pink) |
| `widgetDisk` | `#e2b55a` | Disk/brightness (amber) |
| `widgetNetwork` | `#89b482` | Network/WiFi (sage) |
| `widgetVolume` | `#ea6962` | Volume (red) |

### DPI scaling

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

See existing modules for reference.

## Design Principles

### DO

- **Color layering** for depth — `surfaceBase → surfaceContainer → surfaceContainerHigh`
- **MD3 BezierSpline curves** for premium animations (dashboard, carousel, gauges)
- **Lazy polling** — NEVER poll data when panel/tab is not visible
- **Flat colors** — single accent color on interactive elements, neutral elsewhere
- **Minimal borders** — 1px at 6% opacity, only for structure
- **dpiScale on all sizes** — `Math.round(N * Core.Theme.dpiScale)` for hardcoded px values
- **Smooth animations** — 250-500ms with eased curves, never linear

### DO NOT

- ~~Drop shadows~~ — use color layering instead
- ~~Background polling~~ — gate with visibility flags (perfTabActive, mediaTabActive)
- ~~Gradients on buttons~~ — flat color only
- ~~Glow effects~~ — never (except subtle arc gauge endpoint dot)
- ~~Hardcoded pixel sizes~~ — always multiply by dpiScale

## Quick Reference

```bash
# Deploy
plans/somewm-shell/deploy.sh

# Deploy + restart
plans/somewm-shell/deploy.sh && kill $(pgrep -f 'qs -c somewm'); qs -c somewm -n -d &

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
```
