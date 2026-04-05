pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Configuration
    property string endpoint: "http://localhost:11434"
    property string model: "llama3.2"
    property real temperature: 0.7
    property int maxTokens: 2048
    property string systemPrompt: "You are a helpful assistant integrated into the somewm desktop shell. Be concise."

    // State
    property bool generating: false
    property string error: ""
    property var availableModels: []
    property var _xhr: null

    // Chat history: [{ role: "user"|"assistant", content: "..." }, ...]
    property var messages: []

    // Signal emitted when a response chunk arrives (for streaming)
    signal responseChunk(string text)
    signal responseComplete(string fullText)

    // Load config
    FileView {
        id: configFile
        path: Qt.resolvedUrl("../config.default.json").toString().replace("file://", "")
        watchChanges: true
        onFileChanged: root._loadConfig()
    }

    function _loadConfig() {
        try {
            var data = JSON.parse(configFile.text())
            if (data.ollama) {
                if (data.ollama.endpoint) root.endpoint = data.ollama.endpoint
                if (data.ollama.model) root.model = data.ollama.model
                if (data.ollama.temperature !== undefined) root.temperature = data.ollama.temperature
                if (data.ollama.max_tokens !== undefined) root.maxTokens = data.ollama.max_tokens
            }
            if (data.system_prompt) root.systemPrompt = data.system_prompt
        } catch (e) {
            console.error("AI config parse error:", e)
        }
    }

    // Cancel in-flight request
    function cancel() {
        if (_xhr) { _xhr.abort(); _xhr = null }
        root.generating = false
        root.error = ""
    }

    // Send a message and get a response
    function send(userMessage) {
        if (generating || !userMessage) return

        // Add user message to history
        var msgs = messages.slice()
        msgs.push({ role: "user", content: userMessage })
        messages = msgs

        root.generating = true
        root.error = ""

        // Build the API request
        var body = JSON.stringify({
            model: root.model,
            messages: _buildMessages(),
            stream: false,
            options: {
                temperature: root.temperature,
                num_predict: root.maxTokens
            }
        })

        var xhr = new XMLHttpRequest()
        root._xhr = xhr
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            root._xhr = null
            root.generating = false

            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    var content = data.message ? data.message.content : ""
                    if (content) {
                        var updatedMsgs = root.messages.slice()
                        updatedMsgs.push({ role: "assistant", content: content })
                        root.messages = updatedMsgs
                        root.responseComplete(content)
                    }
                } catch (e) {
                    root.error = "Parse error: " + e
                }
            } else if (xhr.status === 0) {
                root.error = "Connection refused — is Ollama running?"
            } else {
                root.error = "HTTP " + xhr.status + ": " + xhr.statusText
            }
        }

        xhr.open("POST", root.endpoint + "/api/chat")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(body)
    }

    function _buildMessages() {
        var result = []
        // System prompt
        result.push({ role: "system", content: root.systemPrompt })
        // Chat history (limit to last 20 exchanges for context window)
        var history = root.messages
        var start = Math.max(0, history.length - 40)
        for (var i = start; i < history.length; i++) {
            result.push(history[i])
        }
        return result
    }

    // Clear conversation
    function clearHistory() {
        messages = []
        error = ""
    }

    // Fetch available models
    function refreshModels() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    var models = []
                    if (data.models) {
                        data.models.forEach(function(m) {
                            models.push({ name: m.name, size: m.size })
                        })
                    }
                    root.availableModels = models
                } catch (e) {
                    console.error("Model list parse error:", e)
                }
            }
        }
        xhr.open("GET", root.endpoint + "/api/tags")
        xhr.send()
    }

    Component.onCompleted: {
        _loadConfig()
        refreshModels()
    }
}
