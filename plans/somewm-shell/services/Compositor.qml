pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var clients: []
    property var tags: []
    property string focusedClient: ""
    property string focusedScreenName: ""  // pushed from rc.lua screen::focus signal

    // Debounce: coalesce rapid push events into a single refresh
    property bool _dirty: false
    Timer {
        id: debounceTimer
        interval: 50  // 50ms coalesce window
        onTriggered: root._doRefresh()
    }

    function _doRefresh() {
        if (stateProc.running) {
            // stateProc busy — set dirty flag, will re-run on finish
            root._dirty = true
        } else {
            root._dirty = false
            stateProc.running = true
        }
    }

    // somewm-client eval returns "OK\n<value>" — strip prefix
    function _ipcValue(raw) {
        var s = raw.trim()
        var nl = s.indexOf("\n")
        return nl >= 0 ? s.substring(nl + 1) : s
    }

    // === Typed commands (no raw eval exposed!) ===
    function _luaEscape(str) {
        // Escape backslashes first, then single quotes (order matters!)
        return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n")
    }

    function focusClient(windowId) {
        var wid = parseInt(windowId)
        if (isNaN(wid) || wid === 0) return
        _run("for _,c in ipairs(client.get()) do " +
             "if c.window==" + wid + " then " +
             "if c.first_tag then c.first_tag:view_only() end; " +
             "c:activate{raise=true} return end end")
    }

    // Legacy: focus by class (first match)
    function focusClientByClass(className) {
        var safe = _luaEscape(className)
        _run("for _,c in ipairs(client.get()) do " +
             "if c.class=='" + safe + "' then c:activate{raise=true} return end end")
    }

    function viewTag(idx) {
        _run("require('awful').tag.viewidx(" + parseInt(idx) + ")")
    }

    function spawn(cmd) {
        var safe = _luaEscape(cmd)
        _run("require('awful').spawn('" + safe + "')")
    }

    // Private: fire-and-forget somewm-client call with command queue
    property var _cmdQueue: []
    function _run(lua) {
        _cmdQueue.push(lua)
        _drainQueue()
    }
    function _drainQueue() {
        if (runProc.running || _cmdQueue.length === 0) return
        var lua = _cmdQueue.shift()
        runProc.command = ["somewm-client", "eval", lua]
        runProc.running = true
    }
    Process {
        id: runProc
        onRunningChanged: if (!running) root._drainQueue()
    }

    // === State refresh (triggered by push IPC, debounced) ===
    function _refreshState() {
        // Coalesce: restart debounce timer on each push
        debounceTimer.restart()
    }

    Process {
        id: stateProc
        command: ["somewm-client", "eval",
            "local json='{\"clients\":[' local sep='' " +
            "for _,c in ipairs(client.get()) do " +
            "local function esc(s) return s:gsub('\\\\','\\\\\\\\'):gsub('\"','\\\\\"'):gsub('\\n','\\\\n'):gsub('\\t','\\\\t'):gsub('\\r','') end " +
            "json=json..sep..'{\"name\":\"'..esc(c.name or '')..'\",\"class\":\"'..esc(c.class or '')" +
            "..'\",\"tag\":\"'..esc(c.first_tag and c.first_tag.name or '')..'\",\"wid\":'..tostring(c.window or 0)..'}' " +
            "sep=',' end return json..']}'"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(root._ipcValue(text))
                    root.clients = data.clients || []
                } catch (e) {
                    console.error("Client state parse error:", e)
                    root.clients = []
                }
            }
        }
        // Re-run if dirty (invalidation arrived during refresh)
        onRunningChanged: {
            if (!running && root._dirty) root._doRefresh()
        }
    }

    // IPC: compositor pushes invalidate, shell refreshes
    IpcHandler {
        target: "somewm-shell:compositor"
        function invalidate(): void { root._refreshState() }
        // Focused screen tracking (pushed from rc.lua screen::focus signal)
        function setScreen(name: string): void { root.focusedScreenName = name }
        // No eval() exposed! Only typed commands.
        function focus(cls: string): void { root.focusClientByClass(cls) }
        function spawn(cmd: string): void { root.spawn(cmd) }
    }

    // Initial fetch on startup (one-time, not recurring)
    // Also request initial focused screen name from compositor
    Component.onCompleted: {
        _refreshState()
        // Fetch initial focused screen (push may not have arrived yet)
        screenProc.running = true
    }
    Process {
        id: screenProc
        command: ["somewm-client", "eval",
            "local s = require('awful').screen.focused(); return s.name or tostring(s.index)"]
        stdout: StdioCollector {
            onStreamFinished: {
                var name = root._ipcValue(text)
                if (name) root.focusedScreenName = name
            }
        }
    }
}
