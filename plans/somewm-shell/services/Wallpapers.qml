pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../core" as Core

Singleton {
    id: root

    // Wallpaper directories to scan
    property var directories: [
        Quickshell.env("HOME") + "/Pictures/Wallpapers",
        Quickshell.env("HOME") + "/Pictures/wallpapers",
        Quickshell.env("HOME") + "/.config/somewm/themes/default/wallpapers"
    ]

    // Current wallpaper path (from compositor)
    property string currentWallpaper: ""

    // List of { path, name } objects
    property var wallpapers: []

    property bool loading: false

    // Apply theme toggle — persisted in config.json
    property bool applyTheme: {
        var cfg = Core.Config._data
        return cfg && cfg.wallpapers && cfg.wallpapers.applyTheme !== undefined
            ? cfg.wallpapers.applyTheme : true
    }

    // Per-tag override map from compositor { "1": "/path/...", ... }
    property var overrides: ({})

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

    // Get current wallpaper from the Lua wallpaper service
    function refreshCurrent() {
        currentProc.running = true
    }

    Process {
        id: currentProc
        command: ["somewm-client", "eval",
            "return require('fishlive.services.wallpaper').get_current()"]
        stdout: StdioCollector {
            onStreamFinished: {
                var raw = text.trim()
                // somewm-client returns "OK\n<value>"
                var nl = raw.indexOf("\n")
                var path = nl >= 0 ? raw.substring(nl + 1) : raw
                if (path && path !== "OK") root.currentWallpaper = path
            }
        }
    }

    // Fetch override map from compositor
    function refreshOverrides() {
        overridesProc.running = true
    }

    Process {
        id: overridesProc
        command: ["somewm-client", "eval",
            "return require('fishlive.services.wallpaper').get_overrides_json()"]
        stdout: StdioCollector {
            onStreamFinished: {
                var raw = text.trim()
                var nl = raw.indexOf("\n")
                var json = nl >= 0 ? raw.substring(nl + 1) : raw
                try {
                    root.overrides = JSON.parse(json)
                } catch (e) {
                    root.overrides = {}
                }
            }
        }
    }

    // Escape string for safe Lua interpolation (backslash, single quote, newline)
    function _luaEscape(str) {
        return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n")
    }

    // Set wallpaper via Lua wallpaper service (with override for current tag)
    function setWallpaper(path) {
        root.currentWallpaper = path
        var safe = _luaEscape(path)

        // Use the wallpaper service to set override for current tag
        setProc.command = ["somewm-client", "eval",
            "local wp = require('fishlive.services.wallpaper'); " +
            "local s = require('awful').screen.focused(); " +
            "local t = s and s.selected_tag; " +
            "local tag_name = t and t.name or '1'; " +
            "wp.set_override(tag_name, '" + safe + "'); " +
            "return tag_name"]
        setProc.running = true
    }

    Process {
        id: setProc
        stdout: StdioCollector {
            onStreamFinished: {
                // Verify wallpaper was actually set, refresh overrides
                root.refreshCurrent()
                root.refreshOverrides()
            }
        }
        onRunningChanged: {
            if (!running && root.applyTheme) {
                // Run theme-export.sh after wallpaper is set
                themeExportProc.running = true
            }
        }
    }

    // Theme export — regenerates theme.json from current wallpaper colors
    Process {
        id: themeExportProc
        command: [Quickshell.env("HOME") + "/git/github/somewm/plans/theme-export.sh"]
    }

    // Set wallpaper for a specific tag (e.g. from carousel with tag selector)
    function setWallpaperForTag(tagName, path) {
        root.currentWallpaper = path
        var safePath = _luaEscape(path)
        var safeTag = _luaEscape(tagName)
        tagSetProc.command = ["somewm-client", "eval",
            "require('fishlive.services.wallpaper').set_override('" +
            safeTag + "', '" + safePath + "')"]
        tagSetProc.running = true
    }

    Process {
        id: tagSetProc
        onRunningChanged: {
            if (!running && root.applyTheme) {
                themeExportProc.running = true
            }
        }
    }

    // Clear override for a tag (revert to theme default)
    function clearOverride(tagName) {
        var safe = _luaEscape(tagName)
        clearProc.command = ["somewm-client", "eval",
            "require('fishlive.services.wallpaper').clear_override('" + safe + "')"]
        clearProc.running = true
    }

    Process {
        id: clearProc
        onRunningChanged: {
            if (!running) {
                refreshCurrent()
                refreshOverrides()
            }
        }
    }

    // Toggle apply-theme setting (persisted via Config singleton)
    function setApplyTheme(enabled) {
        root.applyTheme = enabled
        Core.Config.set("wallpapers.applyTheme", enabled)
    }

    Component.onCompleted: {
        refresh()
        refreshCurrent()
        refreshOverrides()
    }
}
