pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Core

Singleton {
    id: root

    // Parsed config data
    property var _data: ({})
    property bool ready: false  // true after first config load

    // Animation scale (read from config, pushed to Anims to avoid circular singleton dep)
    // Use !== undefined check so scale=0 (reduced motion) can be set in config
    readonly property real animationScale: _data.animations && _data.animations.scale !== undefined
        ? _data.animations.scale : 1.0
    onAnimationScaleChanged: Core.Anims.scale = animationScale

    function isModuleEnabled(name) {
        if (!ready) return false  // don't instantiate until config loads
        if (!_data.modules) return true  // default: enabled
        var mod = _data.modules[name]
        if (!mod) return true
        return mod.enabled !== false
    }

    FileView {
        id: configFile
        path: Quickshell.env("HOME") + "/.config/quickshell/somewm/config.json"
        watchChanges: true
        onFileChanged: root._loadConfig()
    }

    function _loadConfig() {
        var raw = configFile.text()
        if (raw && raw.trim()) {
            try {
                var data = JSON.parse(raw)
                if (data) root._data = data
            } catch (e) {
                console.error("Config parse error:", e)
            }
        }
        // Always set ready — modules load with defaults if config text isn't available yet.
        // When FileView finishes async load, onFileChanged re-triggers _loadConfig().
        root.ready = true
    }

    // Set a nested config value and persist to file
    // key: dot-separated path (e.g. "wallpapers.applyTheme")
    // value: the value to set
    function set(key, value) {
        var parts = key.split(".")
        var obj = Object.assign({}, _data)
        var current = obj
        for (var i = 0; i < parts.length - 1; i++) {
            if (!current[parts[i]] || typeof current[parts[i]] !== "object") {
                current[parts[i]] = {}
            } else {
                current[parts[i]] = Object.assign({}, current[parts[i]])
            }
            current = current[parts[i]]
        }
        current[parts[parts.length - 1]] = value
        _data = obj
        // Persist to file
        _saveConfig()
    }

    function _saveConfig() {
        saveProc.command = ["bash", "-c",
            "cat > '" + configFile.path + "' << 'CONFIGEOF'\n" +
            JSON.stringify(_data, null, 2) + "\nCONFIGEOF"]
        saveProc.running = true
    }

    Process { id: saveProc }

    Component.onCompleted: {
        _loadConfig()
        Core.Anims.scale = animationScale
    }
}
