# somewm-shell Developer Guide

## What is somewm-shell?

A professional desktop shell for somewm built on **Quickshell (Qt6/QML)**.
It provides overlay panels (dashboard, sidebar, media player, weather, wallpaper picker,
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
└── Modules ─── Dashboard, Sidebar, MediaPanel, Weather, etc.
    └── Each module = PanelWindow + Variants (per-screen instances)
```

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
│   ├── Theme.qml              # Colors, fonts, spacing, radii, helpers
│   ├── Anims.qml              # Animation durations + easing curves
│   ├── Config.qml             # Module enable/disable, watches config.json
│   ├── Panels.qml             # Panel visibility state + IPC handler
│   ├── Constants.qml          # Dimensions, breakpoints, z-ordering
│   └── qmldir
│
├── components/                # Reusable UI primitives
│   ├── GlassCard.qml          # Base card (color layering for depth)
│   ├── ClickableCard.qml      # Card + click + active state
│   ├── SectionHeader.qml      # Accent dot + title
│   ├── SlidePanel.qml         # Slide-in panel (sidebar, etc.)
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
│   ├── Compositor.qml         # Clients, tags, focus (push IPC)
│   ├── Audio.qml              # Volume via wpctl (timer poll)
│   ├── Brightness.qml         # Brightness via brightnessctl
│   ├── Media.qml              # MPRIS media player (D-Bus)
│   ├── Network.qml            # WiFi/BT via nmcli
│   ├── SystemStats.qml        # CPU/memory from /proc (timer poll)
│   ├── Weather.qml            # wttr.in via XMLHttpRequest
│   ├── Wallpapers.qml         # Wallpaper directory listing
│   └── qmldir
│
├── modules/                   # Feature panels
│   ├── ModuleLoader.qml       # Lazy loader (enabled via config.json)
│   ├── dashboard/             # Dashboard (clock, stats, quick launch, media, clients)
│   ├── sidebar/               # Sidebar (quick settings, calendar, notifications)
│   ├── media/                 # Media player (album art, controls, progress, volume)
│   ├── osd/                   # On-screen display (volume/brightness)
│   ├── weather/               # Weather panel
│   ├── wallpapers/            # Wallpaper picker
│   ├── collage/               # Image collage viewer
│   └── qmldir
│
└── tests/
    └── test-all.sh            # Structural + syntax + import validation (no runtime)
```

## Development Workflow

### Edit → Deploy → Restart

```bash
# 1. Edit source files in plans/somewm-shell/
vim plans/somewm-shell/modules/sidebar/QuickSettings.qml

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

| Key | Panel |
|-----|-------|
| `Super+D` | Dashboard |
| `Super+Z` | Sidebar |
| `Super+Shift+M` | Media player |
| `Super+Shift+E` | Weather |
| `Super+Shift+W` | Wallpaper picker |
| `Super+Shift+O` | Collage viewer |
| `Super+Shift+A` | AI chat |
| `Super+C` | Close all panels |
| `Escape` | Close current panel |

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

### Surface hierarchy (depth through color, not shadow)

| Level | Property | Value | Usage |
|-------|----------|-------|-------|
| Base | `surfaceBase` | `#181818` @ 92% | Default card background (= wibar) |
| Container | `surfaceContainer` | `#232323` @ 94% | Elevated cards |
| High | `surfaceContainerHigh` | `#2e2e2e` @ 96% | Hover states |
| Highest | `surfaceContainerHighest` | `#353535` @ 97% | Elevated + hover |

### Derived accent colors

| Property | Derivation | Usage |
|----------|-----------|-------|
| `accentLight` | `Qt.lighter(accent, 1.3)` | Hover highlights |
| `accentFaint` | accent @ 15% alpha | Tinted backgrounds |
| `accentBorder` | accent @ 25% alpha | Active card borders |
| `glassAccent` | accent @ 8% alpha | Active card bg |
| `glassAccentHover` | accent @ 14% alpha | Active card hover |

### Helper functions

```qml
Theme.fade(color, alpha)              // Color with custom alpha
Theme.tint(base, tintColor, amount)   // Blend two colors
```

### DPI scaling

Automatic based on primary screen resolution:
- FHD (1920px): `dpiScale = 1.0`
- QHD (2560px): `dpiScale = 1.15`
- 4K (3840px): `dpiScale = 1.35`

All sizes (`fontSize`, `spacing`, `radius`, `slider`) are multiplied by `dpiScale`.

## Animation System (Anims.qml)

### Durations (scaled by `Config.animations.scale`)

| Name | Base ms | Usage |
|------|---------|-------|
| `instant` | 80 | Micro-interactions |
| `fast` | 150 | Button feedback |
| `normal` | 250 | Default transitions |
| `smooth` | 400 | Panel slide-in |
| `slow` | 600 | Complex sequences |

### Easing curves

| Name | Curve | Usage |
|------|-------|-------|
| `standard` | OutCubic | General transitions |
| `expressive` | OutBack | Panel enter (slight overshoot) |
| `decel` | OutQuart | Fade-in, appear |
| `accel` | InCubic | Panel exit, dismiss |
| `bounce` | OutBack | Playful interactions |

### Using animations

```qml
// Number property
Behavior on opacity { Components.Anim {} }

// Color property
Behavior on color { Components.CAnim {} }

// Both respect Anims.scale. Set scale=0 for reduced motion.
```

## Component Reference

### GlassCard — base card surface

```qml
Components.GlassCard {
    elevated: false      // true = brighter surface (surfaceContainer)
    accentTint: false    // true = tinted with accent/tintColor
    tintColor: Theme.accent  // override for DND (urgent), WiFi (green), etc.
    hovered: false       // drives hover color shift
}
```

Depth is created through **color layering** (surfaceBase → surfaceContainer →
surfaceContainerHigh), not through drop shadows. Borders are minimal (6% opacity
idle, 14% hover).

### ClickableCard — interactive card

```qml
Components.ClickableCard {
    active: false         // true = accentTint activated
    tintColor: Theme.urgent  // red tint when active
    onClicked: (mouse) => { ... }
}
```

### SectionHeader — accent header

```qml
Components.SectionHeader {
    title: "Quick Settings"
    accentColor: Theme.accent  // override per-section
}
```

### CircularProgress — ring chart

```qml
Components.CircularProgress {
    value: 0.75             // 0.0 - 1.0
    lineWidth: 5 * Theme.dpiScale
    progressColor: Theme.widgetCpu
    trackColor: Theme.fade(Theme.widgetCpu, 0.15)

    // Center content slot
    Text { text: "75%"; anchors.centerIn: parent }
}
```

### SlidePanel — slide-in panel

```qml
Components.SlidePanel {
    edge: "right"        // "left" | "right"
    panelWidth: 420 * Theme.dpiScale
    shown: Panels.isOpen("sidebar")

    // Children go in content slot
    ColumnLayout { ... }
}
```

## How to Add a New Module

### 1. Create the module directory

```
plans/somewm-shell/modules/mymodule/
├── MyModule.qml    # Main panel
└── qmldir          # Module registration
```

### 2. Write the qmldir

```
module mymodule
MyModule 1.0 MyModule.qml
```

### 3. Write the panel (overlay example)

```qml
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
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
                elevated: true
                anchors.centerIn: parent
                width: 500 * Core.Theme.dpiScale
                height: 400 * Core.Theme.dpiScale

                // Your content here
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Core.Theme.spacing.xl
                    // ...
                }
            }
        }
    }
}
```

### 4. Register in shell.qml

```qml
import "modules/mymodule" as MyModuleNS

// Inside ShellRoot:
Modules.ModuleLoader {
    moduleName: "mymodule"
    sourceComponent: Component { MyModuleNS.MyModule {} }
}
```

### 5. Add to Panels.qml exclusive list

In `Panels.qml`, add `"mymodule"` to the `exclusive` array (line ~36 and ~59)
so opening your panel closes others.

### 6. Add keybinding in rc.lua

```lua
awful.key({ modkey, "Shift" }, "x", function()
    awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle mymodule")
end, { description = "toggle my module", group = "shell" })
```

### 7. Enable in config

Add to `config.default.json`:
```json
"mymodule": { "enabled": true }
```

## How to Add a New Service

### 1. Create the service singleton

```qml
// services/MyService.qml
pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    // Public properties (UI binds to these)
    property string myData: ""

    // Timer polling (for data that can't use inotify/push)
    Timer {
        interval: 5000
        running: true; repeat: true; triggeredOnStart: true
        onTriggered: fetchProc.running = true
    }

    Process {
        id: fetchProc
        command: ["my-command", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Parse and update properties
                root.myData = text.trim()
            }
        }
    }
}
```

### 2. Register in services/qmldir

```
singleton MyService 1.0 MyService.qml
```

### 3. Use from any module

```qml
import "../../services" as Services

Text { text: Services.MyService.myData }
```

## How to Add a New Component

### 1. Create the component file

```qml
// components/MyWidget.qml
import QtQuick
import "../core" as Core

Item {
    id: root
    property string label: ""
    // ...
}
```

### 2. Register in components/qmldir

```
MyWidget 1.0 MyWidget.qml
```

### 3. Use from any module

```qml
import "../../components" as Components

Components.MyWidget { label: "Hello" }
```

## Design Principles (Modern 2025 Approach)

### DO

- **Color layering** for depth — `surfaceBase → surfaceContainer → surfaceContainerHigh`
- **Flat colors** — single accent color on interactive elements, neutral elsewhere
- **Minimal borders** — 1px at 6% opacity, only for structure (not decoration)
- **Restraint** — accent color on interactive elements only, neutral text/backgrounds
- **Semi-bold typography** — `Font.DemiBold` for headers, `Font.Medium` for emphasis
- **Smooth animations** — 250-400ms with eased curves, never linear
- **Consistent spacing** — always use `Theme.spacing.*` tokens

### DO NOT

- ~~Drop shadows~~ — use color layering instead
- ~~Gradients on buttons/sliders~~ — flat color only
- ~~Glow effects~~ — never
- ~~Font.Thin/Light~~ — use Medium/DemiBold for hierarchy
- ~~Canvas gradient separators~~ — use simple `Separator` component
- ~~Heavy borders~~ — 0.06 opacity max for idle state
- ~~Top-edge highlights~~ — no 2005 glass morphism

### Color usage rules

- **Interactive elements** (buttons, toggles, sliders): accent color
- **Active states** (WiFi on, BT on): accent-tinted card background (8% alpha)
- **Text**: `fgMain` for primary, `fgDim` for secondary, `fgMuted` for disabled
- **Backgrounds**: surface hierarchy — never bright/saturated
- **Widget-specific** (CPU, memory, volume): use `widget*` colors to match wibar

## somewm-shell-ai (Optional)

Separate sub-project at `plans/somewm-shell-ai/` — AI chat via local Ollama.
Imported optionally into shell.qml:

```qml
import "../somewm-shell-ai/modules/chat" as AiChat
AiChat.ChatPanel {}
```

Requires `ollama` running locally. Not loaded by default.

## Quick Reference

```bash
# Deploy
plans/somewm-shell/deploy.sh

# Deploy + restart (from running somewm session)
plans/somewm-shell/deploy.sh && kill $(pgrep -f 'qs -c somewm'); qs -c somewm -n -d &

# Run tests
bash plans/somewm-shell/tests/test-all.sh

# Check current theme
cat ~/.config/somewm/themes/default/theme.json

# Export theme from Lua to JSON
bash plans/theme-export.sh

# IPC test (from another terminal)
qs ipc -c somewm call somewm-shell:panels toggle dashboard

# Config location
~/.config/quickshell/somewm/config.json
```
