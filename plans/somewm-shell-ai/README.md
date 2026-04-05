# somewm-shell-ai — AI Chat Module (Phase 4, Exploratory)

Separate sub-project for AI integration in somewm-shell.
Uses local Ollama for inference — no cloud API keys needed.

## Architecture

```
somewm-shell-ai/
├── services/
│   └── Ollama.qml          # HTTP client for Ollama REST API
├── modules/chat/
│   ├── ChatPanel.qml        # PanelWindow overlay
│   ├── MessageList.qml      # Chat history with markdown rendering
│   ├── InputBar.qml         # Text input + send button
│   └── ModelSelector.qml    # Model picker dropdown
├── config.default.json      # Default settings (model, endpoint)
└── shell-ai.qml             # Entry point (loads into main shell.qml)
```

## Prerequisites

```bash
pacman -S ollama
systemctl start ollama
ollama pull llama3.2    # or any preferred model
```

## Integration

Add to `plans/somewm-shell/shell.qml`:
```qml
import "../somewm-shell-ai/modules/chat" as AiChat
// Inside ShellRoot:
AiChat.ChatPanel {}
```

Add keybinding to `plans/somewm-one/rc.lua`:
```lua
awful.key({ modkey, "Shift" }, "a", function()
    awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle ai-chat")
end, { description = "toggle AI chat", group = "shell" })
```

## Status

Exploratory — API surface may change. Not auto-loaded in main shell.
