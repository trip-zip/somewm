pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // === Output (speakers/headphones) ===
    property real volume: 0.0
    property bool muted: false
    readonly property int volumePercent: Math.round(volume * 100)

    readonly property string icon: {
        if (muted || volume === 0) return "\ue04f"       // volume_off
        if (volume < 0.33) return "\ue04e"               // volume_mute
        if (volume < 0.66) return "\ue04d"               // volume_down
        return "\ue050"                                    // volume_up
    }

    // === Input (microphone) ===
    property real inputVolume: 0.0
    property bool inputMuted: false
    readonly property int inputVolumePercent: Math.round(inputVolume * 100)

    readonly property string inputIcon: {
        if (inputMuted || inputVolume === 0) return "\ue02b"  // mic_off
        return "\ue029"                                        // mic
    }

    // === Output controls ===
    function setVolume(val) {
        var clamped = Math.max(0, Math.min(1, val))
        var pct = Math.round(clamped * 100)
        setVolumeProc.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", pct + "%"]
        setVolumeProc.running = true
        root.volume = clamped
    }

    function setVolumePercent(pct) { setVolume(pct / 100.0) }
    function toggleMute() { toggleMuteProc.running = true }
    function increaseVolume(step) { setVolume(volume + (step || 0.05)) }
    function decreaseVolume(step) { setVolume(volume - (step || 0.05)) }

    // === Input controls ===
    function setInputVolume(val) {
        var clamped = Math.max(0, Math.min(1, val))
        var pct = Math.round(clamped * 100)
        setInputVolumeProc.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@", pct + "%"]
        setInputVolumeProc.running = true
        root.inputVolume = clamped
    }

    function toggleInputMute() { toggleInputMuteProc.running = true }

    // Poll wpctl every 2s for output + input volume
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            pollProc.running = true
            pollInputProc.running = true
        }
    }

    // === Output processes ===
    Process {
        id: pollProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        stdout: StdioCollector {
            onStreamFinished: {
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

    // === Input processes ===
    Process {
        id: pollInputProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"]
        stdout: StdioCollector {
            onStreamFinished: {
                var match = text.match(/Volume:\s+([0-9.]+)/)
                if (match) root.inputVolume = parseFloat(match[1])
                root.inputMuted = text.indexOf("[MUTED]") >= 0
            }
        }
    }

    Process {
        id: setInputVolumeProc
        onRunningChanged: { if (!running) pollInputProc.running = true }
    }

    Process {
        id: toggleInputMuteProc
        command: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]
        onRunningChanged: { if (!running) pollInputProc.running = true }
    }

    // IPC for OSD integration
    IpcHandler {
        target: "somewm-shell:audio"
        function volumeUp(): void   { root.increaseVolume(0.05) }
        function volumeDown(): void { root.decreaseVolume(0.05) }
        function toggleMute(): void { root.toggleMute() }
    }
}
