pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    // Dashboard — bottom-slide panel (compact Caelestia-style)
    readonly property real dashboardScale: 1.0         // dashboard content scale
    readonly property int dashboardMarginH: 40         // horizontal margin from screen edge (min)
    readonly property int dashboardMarginBottom: 20    // bottom margin
    readonly property int dashboardMaxHeight: 600      // max height before capping (pre-scale)
    readonly property int dashboardTopCurveHeight: 32  // concave curve height (pre-scale)
    readonly property int tabBarHeight: 36             // tab bar height (pre-scale, text-only)
    readonly property int tabIndicatorHeight: 3        // tab indicator thickness

    // Arc gauges (Performance tab)
    readonly property int arcGaugeSize: 180            // ring gauge diameter (pre-scale)
    readonly property int arcGaugeLineWidth: 10        // ring stroke width (pre-scale)

    // Performance HeroCard
    readonly property int heroCardHeight: 150          // HeroCard height (pre-scale)
    readonly property int gaugeCardHeight: 200         // GaugeCard height (pre-scale)

    // Dashboard Home tab
    readonly property int dashWeatherWidth: 250        // weather card width
    readonly property int dashDateTimeWidth: 80        // datetime column width
    readonly property int dashMediaWidth: 200          // mini media card width
    readonly property int dashInfoWidth: 200           // system info text width
    readonly property int dashResourceBarThickness: 8  // vertical resource bar width

    // Media tab (Caelestia-style)
    readonly property int dashMediaCoverSize: 150      // album art circle diameter
    readonly property int dashMediaVisualiserSize: 80  // radial bars extra radius
    readonly property int dashMediaProgressSweep: 180  // arc progress sweep degrees
    readonly property int dashMediaProgressThickness: 6 // arc progress stroke width
    readonly property int mediaBarCount: 24            // frequency bars count

    // Wallpaper picker (ilyamiro-faithful)
    readonly property int wpItemWidth: 400
    readonly property int wpItemHeight: 420
    readonly property real wpSkewFactor: -0.35
    readonly property int wpPickerHeight: 650

    // Legacy (keep for OSD, weather, collage — unchanged)
    readonly property int osdWidth: 280
    readonly property int osdHeight: 60
    readonly property int weatherWidth: 360
    readonly property int weatherHeight: 400

    // Breakpoints
    readonly property int screenSmall: 1280
    readonly property int screenMedium: 1920
    readonly property int screenLarge: 2560

    // Z-ordering (layer priorities)
    readonly property int zPanel: 10
    readonly property int zOverlay: 20
    readonly property int zOsd: 30

    // Timing
    readonly property int osdTimeout: 2000       // OSD auto-hide (ms)
    readonly property int debounceInterval: 50   // IPC debounce (ms)
    readonly property int statsInterval: 2000    // SystemStats refresh (ms)
    readonly property int gpuInterval: 3000      // GPU polling (ms)
    readonly property int diskInterval: 60000    // Disk polling (ms)
    readonly property int weatherCache: 3600000  // Weather cache (1h in ms)
}
