pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Public properties — driven entirely by wpctl polling
    property real volume: 0.0
    property bool muted: false
    readonly property int volumePercent: Math.round(volume * 100)

    // Volume icon based on level
    readonly property string icon: {
        if (muted || volume === 0) return "\ue04f"       // volume_off
        if (volume < 0.33) return "\ue04e"               // volume_mute
        if (volume < 0.66) return "\ue04d"               // volume_down
        return "\ue050"                                    // volume_up
    }

    function setVolume(val) {
        var clamped = Math.max(0, Math.min(1, val))
        var pct = Math.round(clamped * 100)
        setVolumeProc.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", pct + "%"]
        setVolumeProc.running = true
        root.volume = clamped  // optimistic update
    }

    function setVolumePercent(pct) {
        setVolume(pct / 100.0)
    }

    function toggleMute() {
        toggleMuteProc.running = true
    }

    function increaseVolume(step) {
        if (!step) step = 0.05
        setVolume(volume + step)
    }

    function decreaseVolume(step) {
        if (!step) step = 0.05
        setVolume(volume - step)
    }

    // Poll wpctl every 2s for current volume state
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: pollProc.running = true
    }

    Process {
        id: pollProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Format: "Volume: 0.37" or "Volume: 0.37 [MUTED]"
                var match = text.match(/Volume:\s+([0-9.]+)/)
                if (match) root.volume = parseFloat(match[1])
                root.muted = text.indexOf("[MUTED]") >= 0
            }
        }
    }

    Process {
        id: setVolumeProc
        onRunningChanged: { if (!running) pollProc.running = true }
    }

    Process {
        id: toggleMuteProc
        command: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]
        onRunningChanged: { if (!running) pollProc.running = true }
    }

    // IPC for OSD integration
    IpcHandler {
        target: "somewm-shell:audio"
        function volumeUp(): void   { root.increaseVolume(0.05) }
        function volumeDown(): void { root.decreaseVolume(0.05) }
        function toggleMute(): void { root.toggleMute() }
    }
}
