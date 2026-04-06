pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // ===== Always-on properties (wibar uses these) =====
    property int cpuPercent: 0
    property int memPercent: 0
    property real memUsedGB: 0.0
    property real memTotalGB: 0.0
    property string uptime: ""

    // ===== Always-on properties (dashboard Home tab uses these) =====
    property int diskPercent: 0
    property string diskUsedGB: "0"
    property string diskTotalGB: "0"

    // ===== Lazy properties (only polled when Performance tab active) =====
    property int cpuTemp: 0
    property int gpuPercent: 0
    property int gpuTemp: 0
    property string gpuName: ""

    // CRITICAL: Visibility gate — set by PerformanceTab when active
    property bool perfTabActive: false

    // Previous CPU readings for delta calculation
    property var _prevCpu: null

    // ===== Always-on timers (CPU + Memory, 2s) =====
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

    // Uptime (every 60s — lightweight)
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: uptimeProc.running = true
    }

    Process {
        id: uptimeProc
        command: ["cat", "/proc/uptime"]
        stdout: StdioCollector {
            onStreamFinished: {
                var secs = Math.floor(parseFloat(text.trim().split(" ")[0]) || 0)
                var h = Math.floor(secs / 3600)
                var m = Math.floor((secs % 3600) / 60)
                root.uptime = h > 0 ? h + " hour" + (h !== 1 ? "s" : "") + ", " + m + " min" : m + " min"
            }
        }
    }

    Process {
        id: cpuProc
        command: ["cat", "/proc/stat"]
        stdout: StdioCollector {
            onStreamFinished: root._parseCpu(text)
        }
    }

    Process {
        id: memProc
        command: ["cat", "/proc/meminfo"]
        stdout: StdioCollector {
            onStreamFinished: root._parseMem(text)
        }
    }

    // ===== Lazy timers (GPU, CPU temp, Disk — gated by perfTabActive) =====

    // GPU polling (nvidia-smi, every 3s)
    Timer {
        interval: 3000
        running: root.perfTabActive
        repeat: true
        triggeredOnStart: true
        onTriggered: gpuProc.running = true
    }

    Process {
        id: gpuProc
        command: ["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu,name",
                  "--format=csv,noheader,nounits"]
        stdout: StdioCollector {
            onStreamFinished: root._parseGpu(text)
        }
    }

    // CPU temperature (hwmon sysfs, every 3s)
    Timer {
        interval: 3000
        running: root.perfTabActive
        repeat: true
        triggeredOnStart: true
        onTriggered: cpuTempProc.running = true
    }

    Process {
        id: cpuTempProc
        command: ["bash", "-c",
            "for h in /sys/class/hwmon/hwmon*; do " +
            "name=$(cat \"$h/name\" 2>/dev/null); " +
            "case \"$name\" in k10temp|coretemp|cpu_thermal) " +
            "cat \"$h/temp1_input\" 2>/dev/null; exit;; esac; done; " +
            "for z in /sys/class/thermal/thermal_zone*; do " +
            "t=$(cat \"$z/type\" 2>/dev/null); " +
            "case \"$t\" in x86_pkg*|coretemp|k10temp|cpu*) " +
            "cat \"$z/temp\" 2>/dev/null; exit;; esac; done"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                var raw = text.trim()
                if (raw && !isNaN(raw)) {
                    root.cpuTemp = Math.round(parseInt(raw) / 1000)
                }
            }
        }
    }

    // Disk usage (every 60s — always-on, used by Home tab ResourceBars)
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: diskProc.running = true
    }

    Process {
        id: diskProc
        command: ["df", "-B1", "/"]
        stdout: StdioCollector {
            onStreamFinished: root._parseDisk(text)
        }
    }

    // Reset lazy data when tab deactivates (clean state)
    onPerfTabActiveChanged: {
        if (!perfTabActive) {
            root.cpuTemp = 0
            root.gpuPercent = 0
            root.gpuTemp = 0
        }
    }

    // ===== Parsers =====

    function _parseCpu(text) {
        try {
            if (!text) return
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

    function _parseGpu(text) {
        try {
            if (!text || text.trim() === "") return
            var line = text.trim().split("\n")[0]
            var match = line.match(/(\d+),\s*(\d+),\s*(.+)/)
            if (match) {
                root.gpuPercent = parseInt(match[1])
                root.gpuTemp = parseInt(match[2])
                root.gpuName = match[3].trim()
            }
        } catch (e) {
            console.error("GPU stats error:", e)
        }
    }

    function _parseDisk(text) {
        try {
            if (!text) return
            var lines = text.trim().split("\n")
            if (lines.length < 2) return
            // Second line: Filesystem 1B-blocks Used Available Use% Mounted
            var parts = lines[1].trim().split(/\s+/)
            if (parts.length >= 4) {
                var total = parseInt(parts[1]) || 0
                var used = parseInt(parts[2]) || 0
                if (total > 0) {
                    root.diskTotalGB = Math.round(total / 1073741824).toString()
                    root.diskUsedGB = Math.round(used / 1073741824).toString()
                    root.diskPercent = Math.round(100.0 * used / total)
                }
            }
        } catch (e) {
            console.error("Disk stats error:", e)
        }
    }
}
