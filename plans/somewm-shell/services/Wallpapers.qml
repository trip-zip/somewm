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

    // Thumbnail cache directory
    readonly property string thumbDir: Quickshell.env("HOME") + "/.cache/somewm-shell/wallpaper_thumbs"
    readonly property string thumbDirUrl: "file://" + thumbDir

    // Color marker cache
    readonly property string colorMarkerDir: Quickshell.env("HOME") + "/.cache/somewm-shell/wallpaper_colors"
    property var colorMap: ({})

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
                result.sort(function(a, b) { return a.name.localeCompare(b.name) })
                root.wallpapers = result
                root.loading = false
                // Generate thumbnails for new wallpapers
                root._generateThumbnails()
            }
        }
    }

    // Generate thumbnails (only for files without existing thumbs)
    function _generateThumbnails() {
        var thumbDirPath = root.thumbDir
        thumbGenProc.command = ["bash", "-c",
            "mkdir -p '" + thumbDirPath + "'\n" +
            "CMD=magick; command -v magick &>/dev/null || CMD=convert\n" +
            "for f in " + root.directories.map(function(d) {
                return "'" + d + "'/*.{jpg,jpeg,png,webp}"
            }).join(" ") + "; do\n" +
            "  [ -f \"$f\" ] || continue\n" +
            "  name=$(basename \"$f\")\n" +
            "  thumb='" + thumbDirPath + "/$name'\n" +
            "  [ -f \"$thumb\" ] && continue\n" +
            "  $CMD \"$f\" -resize x420 -quality 70 \"$thumb\" 2>/dev/null &\n" +
            "  # Limit parallel jobs\n" +
            "  [ $(jobs -r | wc -l) -ge 4 ] && wait -n\n" +
            "done\n" +
            "wait"]
        thumbGenProc.running = true
    }

    Process {
        id: thumbGenProc
        onRunningChanged: {
            if (!running) root._extractColors()
        }
    }

    // Extract dominant colors for each thumbnail
    function _extractColors() {
        var thumbDirPath = root.thumbDir
        var colorDirPath = root.colorMarkerDir
        colorExtractProc.command = ["bash", "-c",
            "mkdir -p '" + colorDirPath + "'\n" +
            "CMD=magick; command -v magick &>/dev/null || CMD=convert\n" +
            "for f in '" + thumbDirPath + "'/*; do\n" +
            "  [ -f \"$f\" ] || continue\n" +
            "  name=$(basename \"$f\")\n" +
            "  # Skip if marker already exists\n" +
            "  ls '" + colorDirPath + "/'\"$name\"'_HEX_'* &>/dev/null && continue\n" +
            "  hex=$($CMD \"$f\" -modulate 100,200 -resize '1x1^' -gravity center -extent 1x1 -depth 8 -format '%[hex:p{0,0}]' info:- 2>/dev/null | grep -oE '[0-9A-Fa-f]{6}' | head -n 1)\n" +
            "  [ -n \"$hex\" ] && touch '" + colorDirPath + "/'\"$name\"'_HEX_'\"$hex\"\n" +
            "done"]
        colorExtractProc.running = true
    }

    Process {
        id: colorExtractProc
        onRunningChanged: {
            if (!running) root._loadColorMarkers()
        }
    }

    // Load color markers into colorMap
    function _loadColorMarkers() {
        colorLoadProc.command = ["bash", "-c",
            "ls '" + root.colorMarkerDir + "/' 2>/dev/null | grep _HEX_ || true"]
        colorLoadProc.running = true
    }

    Process {
        id: colorLoadProc
        stdout: StdioCollector {
            onStreamFinished: {
                var newMap = {}
                var lines = text.trim().split("\n")
                lines.forEach(function(line) {
                    if (!line) return
                    var idx = line.lastIndexOf("_HEX_")
                    if (idx !== -1) {
                        var fname = line.substring(0, idx)
                        var hex = line.substring(idx + 5)
                        newMap[fname] = "#" + hex
                    }
                })
                root.colorMap = newMap
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
