pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Dock application model — manages pinned favorites, running app tracking,
// icon resolution, and window activation/cycling. Persists pin state to disk.
Singleton {
    id: root

    // ── Pinned / favorite apps ──
    property var pinnedApps: ["alacritty", "firefox-developer-edition", "thunar", "code", "spotify"]

    // Persistence file for pinned apps
    readonly property string _pinFile: Quickshell.shellDir + "/dock-pins.json"

    Component.onCompleted: _loadPins()

    function _loadPins() {
        pinReader.command = ["cat", root._pinFile]
        pinReader.running = true
    }

    function _savePins() {
        var escaped = JSON.stringify(root.pinnedApps).replace(/'/g, "'\\''")
        var escapedPath = root._pinFile.replace(/'/g, "'\\''")
        pinWriter.command = ["sh", "-c", "printf '%s\\n' '" + escaped + "' > '" + escapedPath + "'"]
        pinWriter.running = true
    }

    Process {
        id: pinReader
        stdout: SplitParser {
            onRead: (line) => {
                try {
                    var parsed = JSON.parse(line)
                    if (Array.isArray(parsed) && parsed.length > 0)
                        root.pinnedApps = parsed
                } catch (e) {}
            }
        }
    }

    Process {
        id: pinWriter
    }

    function isPinned(appId) {
        var key = appId.toLowerCase()
        for (var i = 0; i < pinnedApps.length; i++) {
            if (pinnedApps[i].toLowerCase() === key) return true
        }
        return false
    }

    function togglePin(appId) {
        var key = appId.toLowerCase()
        var current = pinnedApps.slice()
        var idx = -1
        for (var i = 0; i < current.length; i++) {
            if (current[i].toLowerCase() === key) { idx = i; break }
        }
        if (idx >= 0) {
            current.splice(idx, 1)
        } else {
            current.push(appId)
        }
        pinnedApps = current
        _savePins()
    }

    // ── Stable dock model (ListModel, updated in-place) ──
    // This prevents the Repeater from destroying/recreating all delegates on every change
    ListModel { id: dockModel }
    readonly property alias dockItems: dockModel
    readonly property int itemCount: dockModel.count

    // Incremented on every model rebuild — lets external bindings react to toplevel changes
    property int modelVersion: 0

    // Internal: tracks raw toplevel data for each appId
    property var _appMap: ({})

    // Rebuild the model when inputs change
    property var _rebuild: {
        void root.pinnedApps
        void root._iconVersion
        void ToplevelManager.toplevels.values.length
        Qt.callLater(root._updateModel)
    }

    // Also re-trigger on activated changes (need to track individual toplevels)
    Connections {
        target: ToplevelManager.toplevels
        function onObjectInsertedPost() { Qt.callLater(root._updateModel) }
        function onObjectRemovedPost() { Qt.callLater(root._updateModel) }
    }

    function _updateModel() {
        var map = new Map()
        var newAppMap = {}

        // 1. Pinned apps first (preserve order)
        for (var p = 0; p < pinnedApps.length; p++) {
            var pid = pinnedApps[p]
            var pkey = pid.toLowerCase()
            if (!map.has(pkey)) {
                map.set(pkey, {
                    appId: pid,
                    toplevels: [],
                    isActive: false,
                    isPinned: true,
                    isRunning: false,
                    icon: "",
                    isSeparator: false
                })
            }
        }

        // 2. Running apps (merge into pinned or add after)
        for (var i = 0; i < ToplevelManager.toplevels.values.length; i++) {
            var tl = ToplevelManager.toplevels.values[i]
            var key = (tl.appId || "unknown").toLowerCase()
            if (!map.has(key)) {
                map.set(key, {
                    appId: tl.appId || "unknown",
                    toplevels: [],
                    isActive: false,
                    isPinned: false,
                    isRunning: false,
                    icon: "",
                    isSeparator: false
                })
            }
            var entry = map.get(key)
            entry.toplevels.push(tl)
            entry.isRunning = true
            if (tl.activated) entry.isActive = true
        }

        // 3. Build ordered result
        var pinned = []
        var running = []
        for (var [k, v] of map) {
            v.icon = resolveIcon(v.appId)
            newAppMap[v.appId.toLowerCase()] = v
            if (v.isPinned) pinned.push(v)
            else running.push(v)
        }

        var items = pinned.slice()
        if (pinned.length > 0 && running.length > 0) {
            items.push({ appId: "__separator__", toplevels: [],
                         isActive: false, isPinned: false, isRunning: false,
                         icon: "", isSeparator: true, toplevelCount: 0 })
        }
        items = items.concat(running)

        // 4. Update ListModel in-place (add/remove/update)
        // For simplicity, sync by index — keeps delegates alive when count matches
        var modelCount = dockModel.count
        for (var idx = 0; idx < items.length; idx++) {
            var item = items[idx]
            var flat = {
                appId: item.appId,
                icon: item.icon,
                isPinned: item.isPinned,
                isRunning: item.isRunning,
                isActive: item.isActive,
                isSeparator: item.isSeparator,
                toplevelCount: item.toplevels.length
            }
            if (idx < modelCount) {
                // Update existing entry
                dockModel.set(idx, flat)
            } else {
                // Append new entry
                dockModel.append(flat)
            }
        }
        // Remove excess entries
        while (dockModel.count > items.length) {
            dockModel.remove(dockModel.count - 1)
        }

        // Store raw data (with toplevels) for lookup
        root._appMap = newAppMap
        root.modelVersion++
    }

    // ── Toplevel access (since ListModel can't store object arrays) ──
    function getToplevels(appId) {
        var data = root._appMap[appId.toLowerCase()]
        return data ? data.toplevels : []
    }

    function getAppData(appId) {
        return root._appMap[appId.toLowerCase()] || null
    }

    // ── Launch app via DesktopEntries ──
    function launchApp(appId) {
        var entry = DesktopEntries.byId(appId)
        if (!entry) entry = DesktopEntries.heuristicLookup(appId)
        if (entry) {
            entry.execute()
            return
        }
        var proc = launcherComp.createObject(root, { command: [appId] })
        proc.running = true
    }

    Component {
        id: launcherComp
        Process {
            onRunningChanged: if (!running) destroy()
        }
    }

    // ── Activate / cycle windows ──
    property var _lastFocused: ({})

    function activateApp(appId) {
        var toplevels = getToplevels(appId)
        if (toplevels.length === 0) {
            launchApp(appId)
            return
        }
        if (toplevels.length === 1) {
            toplevels[0].activate()
            return
        }
        var key = appId.toLowerCase()
        var last = _lastFocused[key] !== undefined ? _lastFocused[key] : -1
        var next = (last + 1) % toplevels.length
        var state = Object.assign({}, _lastFocused)
        state[key] = next
        _lastFocused = state
        toplevels[next].activate()
    }

    function activateWindow(toplevel) {
        if (toplevel) toplevel.activate()
    }

    // ── Icon resolution cascade ──
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() { root._iconVersion++ }
    }
    property int _iconVersion: 0

    function resolveIcon(appId) {
        void root._iconVersion

        if (!appId || appId.length === 0 || appId === "__separator__")
            return "application-x-executable"

        // 0. Hardcoded overrides first (fix case-sensitivity)
        var overrides = {
            "alacritty": "Alacritty",
            "code-url-handler": "visual-studio-code",
            "code": "visual-studio-code",
            "jetbrains-idea-ce": "idea",
            "spotify": "spotify-client",
            "footclient": "foot",
            "pavucontrol-qt": "pavucontrol",
            "wpsoffice": "wps-office2019-kprometheus"
        }
        var override = overrides[appId.toLowerCase()]
        if (override) {
            var opath = Quickshell.iconPath(override)
            if (opath && opath.length > 0) return override
        }

        // 1. Exact desktop entry match
        var entry = DesktopEntries.byId(appId)
        if (entry && entry.icon) return entry.icon

        // 2. Heuristic lookup (fuzzy)
        entry = DesktopEntries.heuristicLookup(appId)
        if (entry && entry.icon) return entry.icon

        // 3. Direct icon name lookup
        var path = Quickshell.iconPath(appId)
        if (path && path.length > 0) return appId

        // 4. Normalize: strip reverse-domain, lowercase, dots-to-hyphens
        var normalized = appId.replace(/^(org|com|io|net|dev)\./i, "")
                              .replace(/\./g, "-")
                              .toLowerCase()
        path = Quickshell.iconPath(normalized)
        if (path && path.length > 0) return normalized

        // 5. Regex: steam_app_NNN → steam_icon_NNN
        var steamMatch = appId.match(/^steam_app_(\d+)$/)
        if (steamMatch) return "steam_icon_" + steamMatch[1]

        // 6. Fallback
        return "application-x-executable"
    }
}
