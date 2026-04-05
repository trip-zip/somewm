pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Keyed visibility: { "dashboard": false, "sidebar": false, ... }
    property var openPanels: ({})

    // OSD state (separate — auto-hide, not user-toggled)
    property bool osdVisible: false
    property string osdType: ""
    property real osdValue: 0

    // Auto-hide timer for OSD (1.5s after last trigger)
    Timer {
        id: osdTimer
        interval: 1500
        repeat: false
        onTriggered: root.osdVisible = false
    }

    function showOsd(type, value) {
        root.osdType = type
        root.osdValue = parseFloat(value) || 0
        root.osdVisible = true
        osdTimer.restart()
    }

    // Track whether any overlay panel is open (for compositor scroll-guard)
    readonly property bool anyOverlayOpen: {
        var panels = openPanels
        var exclusive = ["dashboard", "sidebar", "wallpapers", "collage", "media", "weather", "ai-chat"]
        for (var i = 0; i < exclusive.length; i++) {
            if (panels[exclusive[i]] === true) return true
        }
        return false
    }

    onAnyOverlayOpenChanged: _pushOverlayState()

    function _pushOverlayState() {
        overlayStateProc.command = ["somewm-client", "eval",
            "_somewm_shell_overlay = " + (anyOverlayOpen ? "true" : "false")]
        overlayStateProc.running = true
    }

    Process { id: overlayStateProc }

    function isOpen(name) {
        return openPanels[name] === true
    }

    function toggle(name) {
        var state = Object.assign({}, openPanels)
        // Mutual exclusion: close overlapping panels
        var exclusive = ["dashboard", "sidebar", "wallpapers", "collage", "media", "weather", "ai-chat"]
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
        function toggle(name: string): void   { root.toggle(name) }
        function close(name: string): void    { root.close(name) }
        function closeAll(): void             { root.closeAll() }
        function showOsd(type: string, value: string): void { root.showOsd(type, value) }
    }
}
