# somewm-shell — Quickshell Desktop Shell for somewm

Branch: `feat/somewm-web-widgets`
Date: 2026-04-05
Authors: raven2cz, Claude Opus 4.6
Status: ARCHITECTURE v2.3 (post-review round 4)

## Vision

A professional, animation-rich desktop shell for somewm built on **Quickshell (Qt6/QML)**.
Native Wayland layer-shell surfaces, GPU-accelerated rendering, reactive theming from
the somewm-one Lua theme, and a modular component architecture designed for years of
maintainability and easy extension.

### Scope: Overlay Complement

somewm-shell is an **overlay complement** to the existing somewm compositor, not a
full replacement. The existing wibar, naughty notifications, and compositor-level
features remain in somewm-one (Lua). The shell adds layer-shell overlay panels:
dashboard, sidebar, media player, weather, wallpaper picker, collage, and AI chat.

### Design Principles

1. **Compositor-native** — layer-shell surfaces, not client windows
2. **Theme-driven** — all colors, fonts, radii, animations flow from a single theme source
3. **Component isolation** — each module is self-contained, can be enabled/disabled
4. **Animation-first** — every state change has a smooth transition, with reduced-motion support
5. **Data-reactive** — system state flows through services → QML properties → UI
6. **Push, not poll** — compositor events push state to the shell via IPC, never poll on timer
7. **No server needed** — Quickshell Process + D-Bus + file watchers replace HTTP/WebSocket

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                      somewm (compositor)                            │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────────────────┐  │
│  │ Lua API  │  │ somewm-client│  │ wlr-layer-shell-unstable-v1 │  │
│  │ (tags,   │  │ (IPC eval)   │  │                              │  │
│  │ clients) │  │              │  │  somewm-shell layer surfaces │  │
│  └────┬─────┘  └──────┬───────┘  └──────────────┬───────────────┘  │
│       │               │                         │                   │
│  Lua signals ──► qs ipc call (push)             │                   │
│  (client::manage,     │                         │                   │
│   tag::selected, etc) │                         │                   │
└───────────────────────┼─────────────────────────┼───────────────────┘
                        │                         │
                        ▼                         │
┌─────────────────────────────────────────────────┼───────────────────┐
│                somewm-shell (Quickshell)         │                   │
│                                                  │                   │
│  ┌─────────────────────────────────┐            │                   │
│  │         Services Layer          │            │                   │
│  │                                 │            │                   │
│  │  Compositor ←  push IPC         │            │                   │
│  │  Audio ←→ PipeWire (D-Bus)      │            │                   │
│  │  Media ←→ MPRIS (D-Bus)         │            │                   │
│  │  SystemStats ← FileView /proc   │            │                   │
│  │  Weather ← XMLHttpRequest       │            │                   │
│  │  Wallpapers ← FileSystemModel   │            │                   │
│  └────────────┬────────────────────┘            │                   │
│               │ QML property bindings            │                   │
│               ▼                                  │                   │
│  ┌─────────────────────────────────┐            │                   │
│  │     Theme + Anims + Config      │            │                   │
│  │                                 │            │                   │
│  │  Theme.qml ← theme.json ←──────┼── theme.lua (somewm-one)      │
│  │  Anims.qml (curves, durations)  │                                │
│  │  Config.qml ← config.json       │                                │
│  │  Panels.qml (visibility state)  │                                │
│  └────────────┬────────────────────┘                                │
│               │                                                      │
│               ▼                                                      │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │              Modules (per-screen layer-shell surfaces)           ││
│  │                                                                  ││
│  │  Dashboard · Sidebar · MediaPanel · Weather                      ││
│  │  WallpaperPicker · Collage · OSD                                 ││
│  │  (AI chat — exploratory, separate sub-project)                   ││
│  └──────────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────┘
```

## Why No Server

Quickshell accesses all data sources natively — no HTTP/WebSocket server needed:

| Data Source | Quickshell approach |
|---|---|
| Compositor state | Push IPC: Lua signals → `qs ipc call` → IpcHandler |
| CPU/RAM | `FileView { path: "/proc/stat" }` (no process spawn) |
| Media (MPRIS) | Quickshell built-in `MprisController` |
| Audio (PipeWire) | Quickshell built-in `PipeWire` |
| Network | `Process { command: ["nmcli", ...] }` (async) |
| Weather | `XMLHttpRequest` to wttr.in (JS in QML) |
| Wallpapers | `Process { command: ["find", dir] }` or directory listing |
| Theme | `FileView { path: "theme.json"; watchChanges: true }` |

## Directory Structure

```
plans/
├── somewm-one/                     # Compositor config (Lua) — EXISTING
│   ├── rc.lua                      # somewm config
│   ├── anim_client.lua             # C-level animation framework
│   ├── themes/default/
│   │   ├── theme.lua               # Lua theme source
│   │   └── theme.json              # ← AUTO-GENERATED (atomic write)
│   ├── fishlive/                   # Component/service framework
│   └── deploy.sh                   # Deploy → ~/.config/somewm/
│
├── somewm-shell/                   # Desktop shell (QML) — NEW, SEPARATE PROJECT
│   ├── shell.qml                   # Entry point — ShellRoot, module registry
│   ├── config.default.json         # Default config (committed to git)
│   ├── theme.default.json          # Default theme colors (committed, fallback)
│   │
│   ├── core/                       # Framework infrastructure
│   │   ├── Theme.qml               # Singleton: colors, fonts, radii, shadows
│   │   ├── Anims.qml               # Singleton: animation curves + durations
│   │   ├── Config.qml              # Singleton: FileView → config.json (runtime)
│   │   ├── Panels.qml              # Singleton: panel visibility + mutual exclusion
│   │   └── Constants.qml           # Layout constants, breakpoints
│   │
│   ├── services/                   # Data providers (QML singletons)
│   │   ├── Compositor.qml          # Push-based bridge: tags, clients, screens
│   │   ├── SystemStats.qml         # CPU, RAM, temps via FileView /proc
│   │   ├── Audio.qml               # PipeWire: volume, sinks, mute
│   │   ├── Media.qml               # MPRIS: track, artist, art, controls
│   │   ├── Network.qml             # WiFi, Ethernet, VPN, signal
│   │   ├── Weather.qml             # wttr.in + 1h cache
│   │   ├── Wallpapers.qml          # Filesystem scan + current wallpaper
│   │   └── Brightness.qml          # brightnessctl / ddcutil
│   │
│   ├── components/                 # Reusable UI primitives
│   │   ├── Anim.qml                # NumberAnimation with theme easing
│   │   ├── CAnim.qml               # ColorAnimation with theme easing
│   │   ├── StyledRect.qml          # Rectangle + auto color transition
│   │   ├── StyledText.qml          # Text + theme fonts + change animation
│   │   ├── GlassCard.qml           # Glassmorphism card (pure visual, NO MouseArea)
│   │   ├── ClickableCard.qml       # GlassCard + StateLayer + hover/click
│   │   ├── MaterialIcon.qml        # Material Symbols icon (with fallback text)
│   │   ├── StateLayer.qml          # Hover/press ripple effect
│   │   ├── FadeLoader.qml          # Conditional render with fade
│   │   ├── SlidePanel.qml          # Slide-in/out panel (Translate, not margins)
│   │   ├── StatCard.qml            # Stat display (value + label + icon)
│   │   ├── CircularProgress.qml    # Animated circular gauge
│   │   ├── Graph.qml               # Time-series sparkline
│   │   ├── AnimatedBar.qml         # Horizontal animated progress bar
│   │   ├── PulseWave.qml           # Cosmetic animated wave (fake, no audio data)
│   │   ├── ImageAsync.qml          # Async image loading with fade-in
│   │   ├── ScrollArea.qml          # Themed scrollable area
│   │   ├── Separator.qml           # Themed divider line
│   │   └── Tooltip.qml             # Hover tooltip
│   │
│   ├── modules/                    # Feature modules (each = layer surface)
│   │   ├── ModuleLoader.qml        # Lazy loader with per-module defaults
│   │   │
│   │   ├── dashboard/              # System overview (Super+D)
│   │   │   ├── Dashboard.qml       # PanelWindow: overlay, center
│   │   │   ├── ClockWidget.qml     # Large clock + date
│   │   │   ├── StatsGrid.qml      # CPU, RAM, disk, GPU cards
│   │   │   ├── ClientList.qml     # Active windows per tag
│   │   │   ├── QuickLaunch.qml    # Favorite app shortcuts
│   │   │   └── MediaMini.qml      # Compact media info
│   │   │
│   │   ├── sidebar/                # Right slide-in panel (Super+N)
│   │   │   ├── Sidebar.qml         # SlidePanel edge="right"
│   │   │   ├── NotifHistory.qml    # Notification history (reads from naughty IPC)
│   │   │   ├── QuickSettings.qml   # Volume, brightness, wifi, bluetooth
│   │   │   └── CalendarWidget.qml  # Calendar
│   │   │
│   │   ├── media/                  # Music player (Super+M)
│   │   │   ├── MediaPanel.qml      # PanelWindow: bottom or floating
│   │   │   ├── AlbumArt.qml        # Large art + blurred background
│   │   │   ├── TrackInfo.qml       # Title, artist, album
│   │   │   ├── Controls.qml        # Play/pause, next, prev, shuffle
│   │   │   ├── ProgressBar.qml     # Seekable progress
│   │   │   └── VolumeSlider.qml    # Volume control
│   │   │
│   │   ├── weather/                # Weather widget (corner overlay)
│   │   │   ├── WeatherPanel.qml    # PanelWindow: top-right corner
│   │   │   ├── CurrentWeather.qml  # Temp, icon, conditions
│   │   │   └── Forecast.qml        # 5-day forecast row
│   │   │
│   │   ├── wallpapers/             # Wallpaper picker (Super+W)
│   │   │   ├── WallpaperPanel.qml  # PanelWindow: fullscreen overlay
│   │   │   ├── WallpaperGrid.qml   # Thumbnail grid with categories
│   │   │   └── Preview.qml         # Full-size preview on hover
│   │   │
│   │   ├── collage/                # Pinterest-style viewer (Super+P)
│   │   │   ├── CollagePanel.qml    # PanelWindow: overlay
│   │   │   ├── MasonryGrid.qml     # Masonry layout
│   │   │   └── Lightbox.qml        # Fullscreen image view
│   │   │
│   │   └── osd/                    # On-screen display (volume, brightness)
│   │       ├── OSD.qml             # PanelWindow: bottom-center popup
│   │       ├── VolumeOSD.qml       # Volume indicator
│   │       └── BrightnessOSD.qml   # Brightness indicator
│   │
│   ├── assets/                     # Static resources
│   │   └── icons/                  # SVG icons
│   │
│   └── deploy.sh                   # Deploy → ~/.config/quickshell/somewm/
│
├── somewm-shell-ai/                # AI chat — SEPARATE exploratory sub-project
│   └── (deferred to Phase 4+)
│
└── theme-export.sh                 # Export theme.lua → theme.json (atomic)
```

## Core Architecture Details

### 1. Theme Engine (`core/Theme.qml`)

Reads from `theme.json` (auto-exported from Lua). Properties are **mutable** (not `readonly`)
so `loadTheme()` can update them reactively. Derived glass colors use bindings.

```qml
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // === Colors (mutable, updated by loadTheme) ===
    property color bgBase:    "#181818"
    property color bgSurface: "#232323"
    property color bgOverlay: "#2e2e2e"
    property color fgMain:    "#d4d4d4"
    property color fgDim:     "#888888"
    property color fgMuted:   "#555555"
    property color accent:    "#e2b55a"
    property color accentDim: "#c49a3a"
    property color urgent:    "#e06c75"
    property color green:     "#98c379"

    // Widget-specific colors (from theme.lua widget_* variables)
    property color widgetCpu:     "#7daea3"
    property color widgetGpu:     "#98c379"
    property color widgetMemory:  "#d3869b"
    property color widgetDisk:    "#e2b55a"
    property color widgetNetwork: "#89b482"
    property color widgetVolume:  "#ea6962"

    // === Derived glass colors (readonly, auto-update via bindings) ===
    readonly property color glass0: Qt.rgba(bgBase.r, bgBase.g, bgBase.b, 0.75)
    readonly property color glass1: Qt.rgba(bgSurface.r, bgSurface.g, bgSurface.b, 0.80)
    readonly property color glass2: Qt.rgba(bgOverlay.r, bgOverlay.g, bgOverlay.b, 0.85)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.08)

    // === Typography ===
    property string fontUI:   "Geist"
    property string fontMono: "Geist Mono"
    readonly property string fontIcon: "Material Symbols Rounded"

    // === Typography sizes (child QtObject + alias, valid QML) ===
    QtObject {
        id: _fontSize
        property int xs: 10; property int sm: 12; property int base: 14
        property int lg: 16; property int xl: 20; property int xxl: 28
        property int display: 52
    }
    readonly property alias fontSize: _fontSize

    // === Spacing & Layout ===
    QtObject {
        id: _spacing
        property int xs: 4; property int sm: 8; property int md: 12
        property int lg: 16; property int xl: 24; property int xxl: 32
    }
    readonly property alias spacing: _spacing

    QtObject {
        id: _radius
        property int none: 0; property int sm: 6; property int md: 10
        property int lg: 16; property int xl: 24; property int full: 9999
    }
    readonly property alias radius: _radius

    // === Theme loading from JSON (with error handling) ===
    FileView {
        id: themeFile
        path: Quickshell.env("HOME") + "/.config/somewm/themes/default/theme.json"
        watchChanges: true
        onFileChanged: root.loadTheme()
    }

    function loadTheme() {
        try {
            var data = JSON.parse(themeFile.text())
            if (!data) return
            // Only update if key exists (preserves defaults on partial JSON)
            if (data.bg_base)        root.bgBase = data.bg_base
            if (data.bg_surface)     root.bgSurface = data.bg_surface
            if (data.bg_overlay)     root.bgOverlay = data.bg_overlay
            if (data.fg_main)        root.fgMain = data.fg_main
            if (data.fg_dim)         root.fgDim = data.fg_dim
            if (data.fg_muted)       root.fgMuted = data.fg_muted
            if (data.accent)         root.accent = data.accent
            if (data.accent_dim)     root.accentDim = data.accent_dim
            if (data.urgent)         root.urgent = data.urgent
            if (data.green)          root.green = data.green
            if (data.font_ui)        root.fontUI = data.font_ui
            if (data.font_mono)      root.fontMono = data.font_mono
            // Widget colors
            if (data.widget_cpu)     root.widgetCpu = data.widget_cpu
            if (data.widget_gpu)     root.widgetGpu = data.widget_gpu
            if (data.widget_memory)  root.widgetMemory = data.widget_memory
            if (data.widget_disk)    root.widgetDisk = data.widget_disk
            if (data.widget_network) root.widgetNetwork = data.widget_network
            if (data.widget_volume)  root.widgetVolume = data.widget_volume
        } catch (e) {
            console.error("Theme parse error:", e)
            // Keep current colors on error — don't crash
        }
    }

    Component.onCompleted: loadTheme()
}
```

### 2. Animation System (`core/Anims.qml`)

Centralized, globally scalable. Durations use `property int` (not `readonly`) so
they react to `scale` changes. Separate curves for enter vs exit.

```qml
pragma Singleton
Singleton {
    id: root

    // Global speed (1.0 = normal, 0.5 = slow-mo, 2.0 = fast, 0 = reduced motion)
    property real scale: 1.0
    readonly property bool reducedMotion: scale === 0

    // === Durations (reactive to scale, child QtObject + alias) ===
    QtObject {
        id: _duration
        property int instant: Math.round(80 * root.scale)
        property int fast:    Math.round(150 * root.scale)
        property int normal:  Math.round(250 * root.scale)
        property int smooth:  Math.round(400 * root.scale)
        property int slow:    Math.round(600 * root.scale)
    }
    readonly property alias duration: _duration

    // === Easing types (Qt built-in — reliable, no custom BezierSpline issues) ===
    QtObject {
        id: _ease
        readonly property int standard:   Easing.OutCubic     // general transitions
        readonly property int expressive: Easing.OutBack      // panel enter (slight overshoot)
        readonly property int decel:      Easing.OutQuart     // fade-in, appear
        readonly property int accel:      Easing.InCubic      // panel exit, dismiss
        readonly property int bounce:     Easing.OutBack      // playful interactions
    }
    readonly property alias ease: _ease

    // Overshoot amount for OutBack curves (Qt default is 1.70158)
    readonly property real overshoot: 1.2
}
```

### 3. Panel Visibility (`core/Panels.qml`)

Replaces `State.qml`. Minimal scope: panel visibility only. Uses a keyed map
instead of per-panel boolean properties to prevent God Object growth.

```qml
pragma Singleton
Singleton {
    id: root

    // Keyed visibility: { "dashboard": false, "sidebar": false, ... }
    property var openPanels: ({})

    // OSD state (separate — auto-hide, not user-toggled)
    property bool osdVisible: false
    property string osdType: ""
    property real osdValue: 0

    function isOpen(name) {
        return openPanels[name] === true
    }

    function toggle(name) {
        var state = Object.assign({}, openPanels)
        // Mutual exclusion: close overlapping panels
        var exclusive = ["dashboard", "sidebar", "wallpapers", "collage"]
        if (!state[name] && exclusive.indexOf(name) >= 0) {
            exclusive.forEach(function(p) { state[p] = false })
        }
        state[name] = !state[name]
        openPanels = state
    }

    function close(name) {
        if (openPanels[name]) {
            var state = Object.assign({}, openPanels)
            state[name] = false
            openPanels = state
        }
    }

    function closeAll() {
        openPanels = ({})
    }

    // IPC: external control from rc.lua via qs ipc
    IpcHandler {
        target: "somewm-shell:panels"
        function toggle(name: string): void { root.toggle(name) }
        function close(name: string): void  { root.close(name) }
        function closeAll(): void            { root.closeAll() }
    }
}
```

### 4. IPC Bridge — Push, Not Poll (`services/Compositor.qml`)

The compositor **pushes** state changes to the shell. No polling timer.

**In rc.lua (somewm-one) — add Lua signals that push to shell:**
```lua
-- rc.lua: push client/tag state to shell on every change
local function push_state()
    -- Only push if shell is running (non-blocking, debounced on QML side)
    awful.spawn.easy_async(
        "qs ipc call somewm-shell:compositor invalidate",
        function() end  -- fire and forget
    )
end

-- Client lifecycle
client.connect_signal("manage", push_state)
client.connect_signal("unmanage", push_state)
client.connect_signal("focus", push_state)
-- Client property changes
client.connect_signal("property::name", push_state)
client.connect_signal("property::urgent", push_state)
client.connect_signal("property::minimized", push_state)
client.connect_signal("tagged", push_state)
client.connect_signal("untagged", push_state)
-- Tag changes
tag.connect_signal("property::selected", push_state)
tag.connect_signal("property::activated", push_state)
tag.connect_signal("property::name", push_state)

-- Focused screen tracking (for multi-monitor panel targeting)
-- NOTE: screen::focus is a global signal with NO arguments (somewm.c:1107)
-- Must get focused screen via awful.screen.focused()
awesome.connect_signal("screen::focus", function()
    local s = awful.screen.focused()
    if s then
        awful.spawn.easy_async(
            "qs ipc call somewm-shell:compositor setScreen " .. (s.name or tostring(s.index)),
            function() end
        )
    end
end)
```

**In Compositor.qml — react to push, not timer:**
```qml
pragma Singleton
Singleton {
    id: root

    property var clients: []
    property var tags: []
    property string focusedClient: ""
    property string focusedScreenName: ""  // pushed from rc.lua screen::focus signal

    // Debounce: coalesce rapid push events into a single refresh
    property bool _dirty: false
    Timer {
        id: debounceTimer
        interval: 50  // 50ms coalesce window
        onTriggered: root._doRefresh()
    }

    function _doRefresh() {
        if (stateProc.running) {
            // stateProc busy — set dirty flag, will re-run on finish
            root._dirty = true
        } else {
            root._dirty = false
            stateProc.running = true
        }
    }

    // === Typed commands (no raw eval exposed!) ===
    function _luaEscape(str) {
        // Escape backslashes first, then single quotes (order matters!)
        return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n")
    }

    function focusClient(className) {
        var safe = _luaEscape(className)
        _run("for _,c in ipairs(client.get()) do " +
             "if c.class=='" + safe + "' then c:activate{raise=true} return end end")
    }

    function viewTag(idx) {
        _run("awful.tag.viewidx(" + parseInt(idx) + ")")
    }

    function spawn(cmd) {
        var safe = _luaEscape(cmd)
        _run("awful.spawn('" + safe + "')")
    }

    // Private: fire-and-forget somewm-client call with command queue
    property var _cmdQueue: []
    function _run(lua) {
        _cmdQueue.push(lua)
        _drainQueue()
    }
    function _drainQueue() {
        if (runProc.running || _cmdQueue.length === 0) return
        var lua = _cmdQueue.shift()
        runProc.command = ["somewm-client", "eval", lua]
        runProc.running = true
    }
    Process {
        id: runProc
        onRunningChanged: if (!running) root._drainQueue()
    }

    // === State refresh (triggered by push IPC, debounced) ===
    function _refreshState() {
        // Coalesce: restart debounce timer on each push
        debounceTimer.restart()
    }

    Process {
        id: stateProc
        command: ["somewm-client", "eval",
            "local t={} for _,c in ipairs(client.get()) do " +
            "t[#t+1]=c.name..'\\t'..c.class..'\\t'..(c.first_tag and c.first_tag.name or '') " +
            "end return table.concat(t,'\\n')"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Parse tab-delimited format (tabs rare in window titles, safe delimiter)
                var lines = text.trim().split("\n")
                var result = []
                lines.forEach(function(line) {
                    var parts = line.split("\t")
                    if (parts.length >= 3)
                        result.push({name: parts[0], class: parts[1], tag: parts[2]})
                })
                root.clients = result
            }
        }
        // Re-run if dirty (invalidation arrived during refresh)
        onRunningChanged: {
            if (!running && root._dirty) root._doRefresh()
        }
    }

    // IPC: compositor pushes invalidate, shell refreshes
    IpcHandler {
        target: "somewm-shell:compositor"
        function invalidate(): void { root._refreshState() }
        // Focused screen tracking (pushed from rc.lua screen::focus signal)
        function setScreen(name: string): void { root.focusedScreenName = name }
        // No eval() exposed! Only typed commands.
        function focus(cls: string): void { root.focusClient(cls) }
        function spawn(cmd: string): void { root.spawn(cmd) }
    }

    // Initial fetch on startup (one-time, not recurring)
    // Also request initial focused screen name from compositor
    Component.onCompleted: {
        _refreshState()
        // Fetch initial focused screen (push may not have arrived yet)
        screenProc.running = true
    }
    Process {
        id: screenProc
        command: ["somewm-client", "eval",
            "local s = awful.screen.focused(); return s.name or tostring(s.index)"]
        stdout: StdioCollector {
            onStreamFinished: {
                var name = text.trim()
                if (name) root.focusedScreenName = name
            }
        }
    }
}
```

### 5. SlidePanel — GPU Transform, Not Margins

Uses `transform: Translate` for smooth 60/144fps animations without layout recalc.
Different easing for enter (expressive) vs exit (accelerate).

```qml
// components/SlidePanel.qml
PanelWindow {
    id: panel

    required property bool shown
    required property string edge  // "left" | "right"
    property int panelWidth: 460

    // Content slot: declared on root so consumers add children correctly
    default property alias content: contentContainer.data

    color: "transparent"
    focusable: shown

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "somewm-shell:" + edge

    anchors {
        top: true; bottom: true
        left:  edge === "left"
        right: edge === "right"
    }

    implicitWidth: panelWidth

    // Click-through for transparent area
    mask: Region { item: contentArea }

    // Content with GPU-accelerated slide via Translate
    Rectangle {
        id: contentArea
        width: panelWidth
        height: parent.height
        color: Theme.glass1
        radius: Theme.radius.lg

        // GPU transform — no layout recalc!
        transform: Translate {
            x: panel.shown ? 0 :
               (panel.edge === "left" ? -panelWidth : panelWidth)

            Behavior on x {
                NumberAnimation {
                    duration: panel.shown ? Anims.duration.smooth : Anims.duration.normal
                    easing.type: panel.shown ? Anims.ease.expressive : Anims.ease.accel
                    easing.overshoot: panel.shown ? Anims.overshoot : 0
                }
            }
        }

        opacity: panel.shown ? 1.0 : 0.0
        Behavior on opacity { Anim {} }

        // Border glow
        Rectangle {
            anchors.fill: parent; radius: parent.radius
            color: "transparent"
            border.color: Theme.glassBorder; border.width: 1
        }

        Item {
            id: contentContainer
            anchors.fill: parent
            anchors.margins: Theme.spacing.lg
        }
    }
}
```

### 6. GlassCard — Pure Visual (No MouseArea)

```qml
// components/GlassCard.qml — pure presentation, no interaction
Rectangle {
    property bool hovered: false  // set externally by ClickableCard or parent

    color: hovered ? Theme.glass2 : Theme.glass1
    radius: Theme.radius.md
    border.color: Theme.glassBorder
    border.width: 1

    Behavior on color { CAnim {} }
}
```

```qml
// components/ClickableCard.qml — adds interaction
GlassCard {
    id: card
    hovered: mouseArea.containsMouse

    signal clicked(var mouse)

    StateLayer {
        id: mouseArea
        anchors.fill: parent
        onClicked: (mouse) => card.clicked(mouse)
    }
}
```

### 7. Multi-Monitor Support

All modules use `Variants` over `Quickshell.screens` from Phase 1:

```qml
// In each module (e.g. Dashboard.qml)
Variants {
    model: Quickshell.screens

    PanelWindow {
        required property var modelData
        screen: modelData
        // ... module content
    }
}
```

Panels open on the **focused screen** only. The focused screen is tracked via
compositor push IPC (`Compositor.focusedScreenName`). Both `s.name` and `s.index`
are sent from rc.lua (with `s.name or tostring(s.index)` fallback). Modules filter via:
```qml
visible: Panels.isOpen("dashboard") &&
    (modelData.name === Compositor.focusedScreenName ||
     String(modelData.index) === Compositor.focusedScreenName)
```
This handles both named outputs (e.g. `DP-1`) and unnamed/indexed screens.

### 8. Theme Export — Atomic Writes, Complete Export

```bash
#!/bin/bash
# theme-export.sh — atomic write, no cjson dependency, full export
THEME_JSON="$HOME/.config/somewm/themes/default/theme.json"
THEME_TMP="${THEME_JSON}.tmp"
FALLBACK="/home/box/git/github/somewm/plans/somewm-shell/theme.default.json"

# Try live export from running compositor
if somewm-client eval '
    local b = require("beautiful")
    local parts = {}
    local function add(k,v) parts[#parts+1] = string.format("  %q: %q", k, tostring(v or "")) end
    add("bg_base", b.bg_normal)
    add("bg_surface", b.bg_focus)
    add("bg_overlay", b.bg_minimize)
    add("fg_main", b.fg_focus)
    add("fg_dim", b.fg_normal)
    add("fg_muted", b.fg_minimize)
    add("accent", b.border_color_active)
    add("accent_dim", b.border_color_marked)
    add("urgent", b.bg_urgent)
    add("green", "#98c379")
    add("font_ui", "Geist")
    add("font_mono", "Geist Mono")
    add("widget_cpu", b.widget_cpu_color)
    add("widget_gpu", b.widget_gpu_color)
    add("widget_memory", b.widget_memory_color)
    add("widget_disk", b.widget_disk_color)
    add("widget_network", b.widget_network_color)
    add("widget_volume", b.widget_volume_color)
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
' > "$THEME_TMP" 2>/dev/null; then
    mv "$THEME_TMP" "$THEME_JSON"  # atomic!
    echo "Exported theme to $THEME_JSON"
else
    echo "Compositor not running, using fallback theme"
    # Fallback: copy committed default theme.json
    cp "$FALLBACK" "$THEME_JSON" 2>/dev/null
fi
```

Key improvements:
- **Atomic write** (`mv` is POSIX-atomic, prevents partial read)
- **No cjson dependency** (builds JSON from string concatenation in Lua)
- **Fallback** when compositor not running (uses committed default)
- **Exports widget_* colors** (complete, not lossy)

## Keybinding Integration

```lua
-- rc.lua additions (somewm-one)
awful.key({ modkey }, "d", function()
    awful.spawn("qs ipc call somewm-shell:panels toggle dashboard")
end, { description = "toggle dashboard", group = "shell" }),

awful.key({ modkey }, "n", function()
    awful.spawn("qs ipc call somewm-shell:panels toggle sidebar")
end, { description = "toggle sidebar", group = "shell" }),

awful.key({ modkey }, "m", function()
    awful.spawn("qs ipc call somewm-shell:panels toggle media")
end, { description = "toggle media player", group = "shell" }),

awful.key({ modkey }, "w", function()
    awful.spawn("qs ipc call somewm-shell:panels toggle wallpapers")
end, { description = "toggle wallpaper picker", group = "shell" }),

awful.key({ modkey }, "p", function()
    awful.spawn("qs ipc call somewm-shell:panels toggle collage")
end, { description = "toggle collage viewer", group = "shell" }),

awful.key({ modkey }, "Escape", function()
    awful.spawn("qs ipc call somewm-shell:panels closeAll")
end, { description = "close all shell panels", group = "shell" }),
```

## Implementation Phases

### Phase 1: Core + Dashboard
- [ ] Directory structure + deploy.sh + theme-export.sh
- [ ] Theme.qml (with fallback JSON committed)
- [ ] Anims.qml (curves, durations, scale)
- [ ] Config.qml (config.json with defaults)
- [ ] Panels.qml (keyed visibility, mutual exclusion)
- [ ] GlassCard, ClickableCard, StyledText, StyledRect, MaterialIcon
- [ ] SlidePanel (Translate-based) + FadeLoader
- [ ] Compositor.qml (push IPC — add signals to rc.lua)
- [ ] SystemStats.qml (FileView /proc, no process spawn)
- [ ] Dashboard module (clock, stats, client list) with Variants per-screen
- [ ] rc.lua keybinding integration
- [ ] Multi-monitor from day one

### Phase 2: Sidebar + Media
- [ ] Audio.qml (PipeWire built-in)
- [ ] Media.qml (MPRIS built-in)
- [ ] Brightness.qml (brightnessctl)
- [ ] Sidebar module (notification history via IPC, quick settings, calendar)
- [ ] Media module (album art, controls, progress, volume)
- [ ] OSD module (volume/brightness popup)

### Phase 3: Weather + Wallpapers + Collage
- [ ] Weather.qml (XMLHttpRequest to wttr.in)
- [ ] Wallpapers.qml (directory scan)
- [ ] Weather module (current + forecast)
- [ ] Wallpaper picker module (grid, preview, set)
- [ ] Collage module (masonry grid, lightbox)

### Phase 4: AI Integration (exploratory, separate sub-project)
- [ ] Ollama HTTP from QML
- [ ] AI chat module (separate `plans/somewm-shell-ai/`)
- [ ] MCP server for somewm

## Dependencies

```bash
# Already installed:
pacman -S quickshell

# Recommended:
pacman -S ttf-material-symbols-variable-git  # AUR, for MaterialIcon.qml

# For AI (Phase 4):
pacman -S ollama
```

## Review History

### v1.0 Review (2026-04-04)
Reviewed by: Self, Claude Sonnet, GPT-5.4 (Codex), Gemini 3.1-pro-preview

**Critical findings fixed in v2.0:**
1. ~~2s polling timer~~ → push-based IPC from Lua signals
2. ~~`readonly` + mutable loadTheme()~~ → `property` (mutable) for base, `readonly` for derived
3. ~~Partial theme export~~ → full export including widget_* colors, atomic writes, fallback
4. ~~State.qml God Object~~ → Panels.qml with keyed map, minimal scope
5. ~~Lua string injection~~ → `replace(/'/g, "\\'")`  escape in typed commands
6. ~~GlassCard baked-in MouseArea~~ → separated into GlassCard (visual) + ClickableCard
7. ~~SlidePanel margins animation~~ → GPU Translate transform, different easing in/out
8. ~~No multi-monitor~~ → Variants per-screen from Phase 1
9. ~~Notifications.qml D-Bus server~~ → removed; naughty stays, shell reads history via IPC
10. ~~Time.qml singleton~~ → removed; modules use local Timer + Qt.formatTime()
11. ~~AI.qml in services~~ → moved to separate sub-project (exploratory)
12. ~~`eval()` in public IPC~~ → removed; only typed commands exposed
13. ~~WaveVisualizer~~ → renamed PulseWave (cosmetic, no audio data source)
14. ~~config.json in source~~ → config.default.json committed, runtime config in ~/.config/
15. ~~Missing Brightness service~~ → added Brightness.qml

### v2.0 → v2.1 Review (2026-04-04, Round 2)
Reviewed by: Claude Sonnet, GPT-5.4 (Codex)
(Gemini 3.1-pro-preview returned empty output)

**Medium issues fixed in v2.1:**
1. ~~Fallback file wrong~~ → `theme.default.json` (was `config.default.json`)
2. ~~StdioCollector API wrong~~ → `onStreamFinished` + `text` (was `onCompleted` + `stdoutContent`)
3. ~~`Quickshell.focusedScreen` nonexistent~~ → `Compositor.focusedScreenName` via push IPC from `screen::focus`
4. ~~Incomplete Lua escape~~ → `_luaEscape()` escapes `\`, `'`, and `\n` (was `'` only)
5. ~~Missing imports~~ → `import Quickshell.Io`, use `Quickshell.env("HOME")` (was `StandardPaths.configLocation`)
6. ~~No debounce for burst push~~ → 50ms `debounceTimer` in Compositor.qml coalesces rapid invalidations
7. ~~Incomplete push signal coverage~~ → added `property::name`, `property::urgent`, `property::minimized`, `tagged`, `untagged`, `property::name` (tag), `screen::focus`
8. ~~SlidePanel default alias wrong~~ → moved `default property alias content` to root `PanelWindow`

**Low issues fixed in v2.1:**
9. ~~BezierSpline 4-value arrays~~ → replaced with Qt built-in easing types (`OutCubic`, `OutBack`, etc.)
10. ~~Pipe delimiter lossy~~ → switched to tab (`\t`) delimiter in Lua state export

**Remaining (low/nit, acceptable for implementation):**
- `focusedClient` declared but never populated → will populate during Phase 1 implementation
- Backslash in class names → theoretical, handled by `_luaEscape`
- Hardcoded fallback path in theme-export.sh → acceptable for single-user dev setup

### v2.1 → v2.2 Review (2026-04-04, Round 3)
Reviewed by: GPT-5.4 (Codex), Gemini 3.1-pro-preview, Claude Sonnet

**Medium issues fixed in v2.2:**
1. ~~focusedScreenName empty at startup~~ → `screenProc` fetches initial screen on `Component.onCompleted`; match handles both `name` and `index` with fallback
2. ~~Debounce lost invalidations during in-flight refresh~~ → `_dirty` flag + `onRunningChanged` re-runs refresh after stateProc finishes
3. ~~Inline `QtObject { property ... }` invalid QML~~ → child `QtObject { id: _name }` + `readonly property alias name: _name` pattern
4. ~~Shared `runProc` drops concurrent commands~~ → `_cmdQueue` array + `_drainQueue()` executes sequentially

**Remaining (low/nit, acceptable for implementation):**
- Hardcoded fallback path → single-user dev setup
- `focusedClient` → Phase 1

### v2.2 → v2.3 Review (2026-04-04, Round 4)
Reviewed by: GPT-5.4 (Codex), Gemini 3.1-pro-preview, Claude Sonnet

**Results: Gemini PASS, GPT-5.4 1 medium, Sonnet 1 medium (same issue)**
1. ~~`screen::focus` signal has no args~~ → callback uses `awful.screen.focused()` instead of `function(s)`, added nil guard
2. ~~Wrong signal form~~ → uses `awesome.connect_signal("screen::focus", ...)` (global, matches `somewm.c:1107`)

**Final status: 0 critical, 0 medium. All reviewers satisfied on remaining items.**

## Security

- No raw `eval()` exposed via IPC — only typed commands (focus, spawn, invalidate, setScreen)
- `somewm-client` is Unix socket only, no network exposure
- `_luaEscape()` escapes `\`, `'`, `\n` to prevent Lua injection
- Config files are local JSON, no cloud sync
- Weather uses public wttr.in (no API key)
