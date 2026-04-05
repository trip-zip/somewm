pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Public properties
    property int cpuPercent: 0
    property int memPercent: 0
    property real memUsedGB: 0.0
    property real memTotalGB: 0.0

    // Previous CPU readings for delta calculation
    property var _prevCpu: null

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            cpuProc.running = true
            memProc.running = true
        }
    }

    // CPU: read /proc/stat via Process (FileView inotify doesn't work on procfs)
    Process {
        id: cpuProc
        command: ["cat", "/proc/stat"]
        stdout: StdioCollector {
            onStreamFinished: root._parseCpu(text)
        }
    }

    // Memory: read /proc/meminfo via Process
    Process {
        id: memProc
        command: ["cat", "/proc/meminfo"]
        stdout: StdioCollector {
            onStreamFinished: root._parseMem(text)
        }
    }

    function _parseCpu(text) {
        try {
            if (!text) return
            // First line: cpu  user nice system idle iowait irq softirq steal
            var firstLine = text.split("\n")[0]
            var parts = firstLine.trim().split(/\s+/)
            if (parts.length < 5 || parts[0] !== "cpu") return

            var user   = parseInt(parts[1]) || 0
            var nice   = parseInt(parts[2]) || 0
            var system = parseInt(parts[3]) || 0
            var idle   = parseInt(parts[4]) || 0
            var iowait = parseInt(parts[5]) || 0
            var irq    = parseInt(parts[6]) || 0
            var softirq = parseInt(parts[7]) || 0
            var steal  = parseInt(parts[8]) || 0

            var active = user + nice + system + irq + softirq + steal
            var total = active + idle + iowait

            if (_prevCpu) {
                var dActive = active - _prevCpu.active
                var dTotal = total - _prevCpu.total
                if (dTotal > 0) {
                    root.cpuPercent = Math.round(100.0 * dActive / dTotal)
                }
            }
            _prevCpu = { active: active, total: total }
        } catch (e) {
            console.error("CPU stats error:", e)
        }
    }

    function _parseMem(text) {
        try {
            if (!text) return
            var lines = text.split("\n")
            var memTotal = 0
            var memAvailable = 0
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i]
                if (line.indexOf("MemTotal:") === 0) {
                    memTotal = parseInt(line.split(/\s+/)[1]) || 0
                } else if (line.indexOf("MemAvailable:") === 0) {
                    memAvailable = parseInt(line.split(/\s+/)[1]) || 0
                }
                if (memTotal > 0 && memAvailable > 0) break
            }
            if (memTotal > 0) {
                var usedKB = memTotal - memAvailable
                root.memTotalGB = Math.round(memTotal / 1048576.0 * 10) / 10
                root.memUsedGB = Math.round(usedKB / 1048576.0 * 10) / 10
                root.memPercent = Math.round(100.0 * usedKB / memTotal)
            }
        } catch (e) {
            console.error("Memory stats error:", e)
        }
    }
}
