pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property int percent: 100
    property int maxBrightness: 100

    // Refresh brightness value
    function refresh() {
        getProc.running = true
    }

    function setPercent(val) {
        val = Math.max(1, Math.min(100, Math.round(val)))
        if (setProc.running) return  // debounce concurrent calls
        setProc.command = ["brightnessctl", "set", val + "%"]
        setProc.running = true
    }

    function increase(step) {
        if (!step) step = 5
        setPercent(percent + step)
    }

    function decrease(step) {
        if (!step) step = 5
        setPercent(percent - step)
    }

    // Get current brightness (use -m info for primary device only, parse first line)
    Process {
        id: getProc
        command: ["brightnessctl", "-m", "info"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Format per line: device,class,current,max,percent%
                var firstLine = text.trim().split("\n")[0]
                var parts = firstLine ? firstLine.split(",") : []
                if (parts.length >= 5) {
                    var maxB = parseInt(parts[3])
                    root.maxBrightness = isNaN(maxB) ? 100 : maxB
                    var pct = parseInt(parts[4].replace("%", ""))
                    root.percent = isNaN(pct) ? 100 : pct
                }
            }
        }
    }

    // Set brightness
    Process {
        id: setProc
        onRunningChanged: {
            if (!running) root.refresh()
        }
    }

    // IPC for OSD integration
    IpcHandler {
        target: "somewm-shell:brightness"
        function up(): void   { root.increase(5) }
        function down(): void { root.decrease(5) }
    }

    Component.onCompleted: refresh()
}
