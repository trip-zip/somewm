pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    // Panel dimensions
    readonly property int sidebarWidth: 420
    readonly property int dashboardMaxWidth: 700
    readonly property int dashboardMaxHeight: 600
    readonly property int mediaMaxWidth: 600
    readonly property int mediaHeight: 280
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
    readonly property int weatherCache: 3600000  // Weather cache (1h in ms)
}
