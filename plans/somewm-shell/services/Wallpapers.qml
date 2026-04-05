pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Wallpaper directories to scan
    property var directories: [
        Quickshell.env("HOME") + "/Pictures/Wallpapers",
        Quickshell.env("HOME") + "/Pictures/wallpapers",
        Quickshell.env("HOME") + "/.config/somewm/themes/default/wallpapers"
    ]

    // Current wallpaper path
    property string currentWallpaper: ""

    // List of { path, name } objects
    property var wallpapers: []

    property bool loading: false

    function refresh() {
        root.loading = true
        // Build find command across all directories
        var dirs = root.directories.filter(function(d) { return d !== "" })
        scanProc.command = ["find"].concat(dirs).concat([
            "-maxdepth", "2", "-type", "f",
            "(", "-name", "*.jpg", "-o", "-name", "*.jpeg",
            "-o", "-name", "*.png", "-o", "-name", "*.webp", ")"
        ])
        scanProc.running = true
    }

    Process {
        id: scanProc
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                var result = []
                lines.forEach(function(line) {
                    if (!line) return
                    var name = line.split("/").pop()
                    result.push({ path: line, name: name })
                })
                // Sort alphabetically by name
                result.sort(function(a, b) { return a.name.localeCompare(b.name) })
                root.wallpapers = result
                root.loading = false
            }
        }
    }

    // Get current wallpaper via compositor
    function refreshCurrent() {
        currentProc.running = true
    }

    Process {
        id: currentProc
        command: ["somewm-client", "eval",
            "local b = require('beautiful'); return b.wallpaper or ''"]
        stdout: StdioCollector {
            onStreamFinished: {
                var path = text.trim()
                if (path) root.currentWallpaper = path
            }
        }
    }

    // Escape string for safe Lua interpolation (backslash, single quote, newline)
    function _luaEscape(str) {
        return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n")
    }

    // Set wallpaper via compositor
    function setWallpaper(path) {
        root.currentWallpaper = path
        var safe = _luaEscape(path)
        setProc.command = ["somewm-client", "eval",
            "for s in screen do require('gears').wallpaper.maximized('" +
            safe + "', s) end"]
        setProc.running = true
    }

    Process {
        id: setProc
    }

    Component.onCompleted: {
        refresh()
        refreshCurrent()
    }
}
