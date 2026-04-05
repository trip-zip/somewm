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
    readonly property color glass0: Qt.rgba(bgBase.r, bgBase.g, bgBase.b, 0.92)
    readonly property color glass1: Qt.rgba(bgSurface.r, bgSurface.g, bgSurface.b, 0.94)
    readonly property color glass2: Qt.rgba(bgOverlay.r, bgOverlay.g, bgOverlay.b, 0.96)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.12)

    // === Accent shades (auto-derived from accent) ===
    readonly property color accentLight: Qt.lighter(accent, 1.3)
    readonly property color accentFaint: Qt.rgba(accent.r, accent.g, accent.b, 0.15)
    readonly property color accentBorder: Qt.rgba(accent.r, accent.g, accent.b, 0.25)
    readonly property color glassAccent: Qt.rgba(accent.r, accent.g, accent.b, 0.08)
    readonly property color glassAccentHover: Qt.rgba(accent.r, accent.g, accent.b, 0.14)

    // === Surface hierarchy (color layering for depth) ===
    // Matches wibar: bgBase (#181818) as the base panel background
    readonly property color surfaceBase: Qt.rgba(bgBase.r, bgBase.g, bgBase.b, 0.97)
    readonly property color surfaceContainer: Qt.rgba(bgSurface.r, bgSurface.g, bgSurface.b, 0.97)
    readonly property color surfaceContainerHigh: Qt.rgba(bgOverlay.r, bgOverlay.g, bgOverlay.b, 0.98)
    readonly property color surfaceContainerHighest: {
        var f = 1.15
        return Qt.rgba(
            Math.min(1, bgOverlay.r * f),
            Math.min(1, bgOverlay.g * f),
            Math.min(1, bgOverlay.b * f),
            0.97
        )
    }

    // === Slider dimensions ===
    QtObject {
        id: _slider
        property real trackHeight: 6 * root.dpiScale
        property real trackRadius: 3 * root.dpiScale
        property real thumbSize: 14 * root.dpiScale
        property real thumbRadius: 7 * root.dpiScale
        // Visible groove color — brighter than surface, clearly reads as a track
        property color trackColor: Qt.rgba(1, 1, 1, 0.12)
    }
    readonly property alias slider: _slider

    // === Helper functions ===
    function fade(color, alpha) {
        return Qt.rgba(color.r, color.g, color.b, alpha)
    }
    function tint(base, tintColor, amount) {
        return Qt.rgba(
            base.r * (1 - amount) + tintColor.r * amount,
            base.g * (1 - amount) + tintColor.g * amount,
            base.b * (1 - amount) + tintColor.b * amount,
            base.a * (1 - amount) + tintColor.a * amount
        )
    }

    // === Typography ===
    property string fontUI:   "Geist"
    property string fontMono: "Geist Mono"
    readonly property string fontIcon: "Material Symbols Rounded"

    // === DPI scale factor ===
    // Standard=96dpi (scale 1.0), 4K≈120-163dpi (scale 1.25-1.75)
    readonly property real dpiScale: {
        var screens = Quickshell.screens
        if (!screens || screens.length === 0) return 1.0
        var s = screens[0]
        if (!s) return 1.0
        var w = s.width
        if (w >= 3840) return 1.35    // 4K
        if (w >= 2560) return 1.15    // QHD
        return 1.0                     // FHD
    }

    // === Typography sizes (child QtObject + alias, valid QML) ===
    QtObject {
        id: _fontSize
        property int xs: Math.round(10 * root.dpiScale)
        property int sm: Math.round(12 * root.dpiScale)
        property int base: Math.round(14 * root.dpiScale)
        property int lg: Math.round(16 * root.dpiScale)
        property int xl: Math.round(20 * root.dpiScale)
        property int xxl: Math.round(28 * root.dpiScale)
        property int display: Math.round(52 * root.dpiScale)
    }
    readonly property alias fontSize: _fontSize

    // === Spacing & Layout ===
    QtObject {
        id: _spacing
        property int xs: Math.round(4 * root.dpiScale)
        property int sm: Math.round(8 * root.dpiScale)
        property int md: Math.round(12 * root.dpiScale)
        property int lg: Math.round(16 * root.dpiScale)
        property int xl: Math.round(24 * root.dpiScale)
        property int xxl: Math.round(32 * root.dpiScale)
    }
    readonly property alias spacing: _spacing

    QtObject {
        id: _radius
        property int none: 0
        property int sm: Math.round(6 * root.dpiScale)
        property int md: Math.round(10 * root.dpiScale)
        property int lg: Math.round(16 * root.dpiScale)
        property int xl: Math.round(24 * root.dpiScale)
        property int full: 9999
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
        var raw = themeFile.text()
        if (!raw || !raw.trim()) return  // FileView async load not complete yet
        try {
            var data = JSON.parse(raw)
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
