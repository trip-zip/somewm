pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property int barCount: 24
    property var values: []
    property bool active: false
    property bool available: false

    // CRITICAL: Lazy lifecycle — set by MediaTab when visible
    property bool mediaTabActive: false

    onMediaTabActiveChanged: {
        if (mediaTabActive) _startCava()
        else _stopCava()
    }

    onAvailableChanged: {
        if (available && mediaTabActive) _startCava()
    }

    // Check if cava is installed (one-time on startup)
    Process {
        id: checkProc
        command: ["which", "cava"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.available = text.trim() !== ""
            }
        }
    }
    Component.onCompleted: checkProc.running = true

    // Cava config file path
    readonly property string _configPath: Quickshell.env("XDG_RUNTIME_DIR") + "/somewm-shell-cava.conf"

    function _startCava() {
        if (!available) return
        if (cavaProc.running) return

        // Write cava config for raw output
        configWriter.command = ["bash", "-c",
            "cat > " + _configPath + " << 'CAVAEOF'\n" +
            "[general]\n" +
            "bars = " + barCount + "\n" +
            "framerate = 30\n" +
            "[output]\n" +
            "method = raw\n" +
            "raw_target = /dev/stdout\n" +
            "data_format = ascii\n" +
            "ascii_max_range = 1000\n" +
            "CAVAEOF"]
        configWriter.running = true
    }

    Process {
        id: configWriter
        onRunningChanged: {
            if (!running && root.mediaTabActive) {
                // Config written, start cava (guard against stale callback after stop)
                cavaProc.command = ["cava", "-p", root._configPath]
                cavaProc.running = true
                root.active = true
            }
        }
    }

    function _stopCava() {
        root.active = false
        if (cavaProc.running) {
            killProc.running = true
        }
        root.values = []
    }

    Process {
        id: killProc
        command: ["pkill", "-f", "cava.*somewm-shell-cava"]
    }

    // Cava process with line-by-line output parsing (long-running, never exits normally)
    Process {
        id: cavaProc
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: (line) => root._parseLine(line)
        }
        onRunningChanged: {
            if (!running && root.mediaTabActive) {
                // Cava crashed, retry after 2s
                retryTimer.start()
            }
        }
    }

    Timer {
        id: retryTimer
        interval: 2000
        repeat: false
        onTriggered: {
            if (root.mediaTabActive && root.available) root._startCava()
        }
    }

    function _parseLine(line) {
        if (!line) return
        try {
            // ASCII output: values separated by semicolons, e.g. "123;456;789;..."
            var parts = line.split(";")
            var normalized = []
            for (var i = 0; i < parts.length; i++) {
                var val = parseInt(parts[i])
                if (!isNaN(val)) {
                    normalized.push(Math.min(1.0, val / 1000.0))
                }
            }
            if (normalized.length > 0) {
                root.values = normalized
            }
        } catch (e) {
            // Silently skip malformed lines
        }
    }

    // Cleanup on destruction
    Component.onDestruction: _stopCava()
}
