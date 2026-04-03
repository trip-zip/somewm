# somewm-web-widgets — Web-based Widget System for somewm

Branch: `feat/somewm-web-widgets`
Date: 2026-04-03
Authors: raven2cz, Claude Opus 4.6
Status: PLANNING

## Vision

Replace complex Lua-only dashboards with GPU-accelerated web widgets rendered
directly on the compositor. Modern HTML/CSS/JS with full framework support
(React, Vue, Svelte), real-time data from somewm via WebSocket, and optional
AI integration (local Gemma 4, MCP protocol).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    somewm (compositor)                       │
│  ┌──────────┐  ┌───────────┐  ┌──────────────────────────┐  │
│  │ Lua API  │  │ IPC       │  │ wlr-layer-shell          │  │
│  │ (tags,   │  │ (somewm-  │  │ (panels, overlays)       │  │
│  │ clients, │  │  client)  │  │                          │  │
│  │ screens) │  │           │  │ + floating windows       │  │
│  └────┬─────┘  └─────┬─────┘  └────────────┬─────────────┘  │
│       │              │                      │                │
└───────┼──────────────┼──────────────────────┼────────────────┘
        │              │                      │
        ▼              ▼                      ▼
┌──────────────────────────────┐    ┌──────────────────────┐
│  somewm-widgets-server       │    │  WebView Launcher    │
│  (Go or Rust)                │    │  (Python/GTK)        │
│                              │    │                      │
│  ┌────────────┐              │    │  - WebKitGTK engine  │
│  │ HTTP API   │ :9876/api/*  │    │  - Transparent bg    │
│  ├────────────┤              │    │  - Layer-shell mode  │
│  │ WebSocket  │ :9876/ws     │    │    (overlay/panel)   │
│  ├────────────┤              │    │  - Floating mode     │
│  │ Static     │ :9876/*      │    │    (draggable)       │
│  │ (HTML/JS)  │              │    │  - Hotkey triggered   │
│  ├────────────┤              │    │                      │
│  │ AI Proxy   │ :9876/ai/*   │    │  somewm-widget open  │
│  │ (Gemma,MCP)│              │    │    --name=music      │
│  └────────────┘              │    │    --mode=floating   │
│                              │    │    --pos=right       │
│  Bridges:                    │    │    --size=400x600    │
│  - somewm-client eval        │    │                      │
│  - D-Bus (playerctl, NM)     │    └──────────────────────┘
│  - /sys, /proc (hw sensors)  │
│  - Ollama API (local LLM)    │
│  - MCP protocol              │
└──────────────────────────────┘
```

## Components

### 1. somewm-widgets-server (backend)

Lightweight server that bridges compositor state + system data to web clients.

#### Tech stack
- **Go** (single binary, fast, easy WebSocket, easy cross-compile)
- Or **Rust** (if we want tighter integration later)

#### API Endpoints

```
GET  /api/compositor     # tags, clients, screens, focused client
GET  /api/system         # CPU, RAM, disk, temps, battery
GET  /api/audio          # PipeWire/PulseAudio volumes, sinks, sources
GET  /api/network        # WiFi SSID, IP, signal, VPN status
GET  /api/bluetooth      # paired devices, connected
GET  /api/media          # MPRIS: current track, artist, album art, position
GET  /api/weather        # cached weather data (OpenWeatherMap / wttr.in)
GET  /api/notifications  # notification history
GET  /api/wallpapers     # wallpaper collection, current, tags
GET  /api/pins           # local pinterest pins / collage images

POST /api/compositor/eval    # execute Lua in somewm (via somewm-client)
POST /api/audio/volume       # set volume
POST /api/media/playpause    # MPRIS control
POST /api/wallpapers/set     # change wallpaper
POST /api/notifications/dismiss  # dismiss notification

WS   /ws                 # real-time events (tag change, client focus,
                         #   media track change, volume change, notification)
```

#### WebSocket Protocol

```json
// Server -> Client (events)
{ "type": "tag_changed", "data": { "screen": 1, "tag": "3", "clients": [...] } }
{ "type": "client_focus", "data": { "name": "Firefox", "class": "firefox", "tag": "2" } }
{ "type": "media_changed", "data": { "title": "Song", "artist": "Band", "art_url": "..." } }
{ "type": "volume_changed", "data": { "volume": 65, "muted": false } }
{ "type": "notification", "data": { "title": "...", "body": "...", "icon": "..." } }
{ "type": "system_stats", "data": { "cpu": 23, "ram": 45, "temp": 62 } }

// Client -> Server (commands)
{ "type": "eval", "lua": "return client.focus.name" }
{ "type": "media_cmd", "cmd": "PlayPause" }
{ "type": "volume_set", "value": 70 }
{ "type": "wallpaper_set", "path": "/path/to/wallpaper.jpg" }
```

#### AI Integration

```
POST /api/ai/chat        # chat with local LLM
  { "model": "gemma4", "messages": [...], "stream": true }

POST /api/ai/mcp         # MCP tool call
  { "tool": "somewm.list_clients", "params": {} }

WS   /ws/ai              # streaming AI responses

GET  /api/ai/models      # available models (from Ollama)
```

**AI backends:**
- **Ollama** — local Gemma 4, Llama, etc. (HTTP API at localhost:11434)
- **MCP** — Model Context Protocol server for somewm-specific tools:
  - `somewm.list_clients` — list all windows
  - `somewm.focus_client` — focus a specific window
  - `somewm.move_to_tag` — move client to tag
  - `somewm.set_layout` — change layout
  - `somewm.screenshot` — take screenshot
  - `somewm.set_wallpaper` — change wallpaper
  - `somewm.system_info` — CPU, RAM, temps
  - `somewm.run_command` — spawn app

### 2. somewm-widget (launcher)

CLI tool + Python GTK app that opens WebView windows.

```bash
# Floating widget (draggable, closeable)
somewm-widget open music --mode=floating --size=400x300 --pos=center

# Layer-shell overlay (slide from right)
somewm-widget open dashboard --mode=overlay --anchor=right --size=500x100%

# Layer-shell panel (always visible)
somewm-widget open statusbar --mode=panel --anchor=top --size=100%x40

# Close widget
somewm-widget close music

# Toggle (open if closed, close if open)
somewm-widget toggle dashboard

# List running widgets
somewm-widget list
```

**Implementation:**
- Python + WebKitGTK + GtkLayerShell (for overlay/panel mode)
- Plain WebKitGTK window (for floating mode — somewm manages it)
- D-Bus interface for toggle/close commands
- Transparent background support
- CSS `backdrop-filter: blur()` for glassmorphism (if compositor supports)

### 3. Web Widgets (frontend)

Each widget is a standalone HTML/CSS/JS app served by the server.

#### Widget: Dashboard (`/dashboard`)
- System stats (CPU, RAM, disk, temps) — animated gauges/charts
- Active clients per tag — clickable to focus
- Quick launchers — favorite apps
- Calendar + upcoming events
- Weather summary
- Media player mini
- AI quick prompt

#### Widget: Music Player (`/music`)
- Album art (large, blurred background)
- Track info, progress bar
- Play/pause, next/prev, shuffle, repeat
- Volume slider
- Playlist / queue
- Spotify/local music via MPRIS

#### Widget: Weather (`/weather`)
- Current conditions + icon
- 5-day forecast
- Sunrise/sunset
- Animated weather backgrounds

#### Widget: AI Chat (`/ai`)
- Chat interface with local Gemma 4
- Streaming responses
- System context (can ask "what windows are open?", "move Firefox to tag 3")
- MCP tool calling (AI can control compositor)
- Code highlighting, markdown rendering

#### Widget: Wallpaper Changer (`/wallpapers`)
- Grid of available wallpapers (thumbnails)
- Categories / tags
- Click to set, preview on hover
- Random / scheduled rotation
- Portrait collection for notifications

#### Widget: Notification Center (`/notifications`)
- Notification history (scrollable)
- Group by app
- Dismiss individual / all
- Do Not Disturb toggle
- Actions (reply, open, etc.)

#### Widget: Collage Viewer (`/collage`)
- Pinterest-style masonry grid
- Local image collection
- Lightbox zoom
- Tags / folders
- Drag & drop to organize

### 4. somewm-mcp-server (MCP Protocol)

Standalone MCP server that exposes somewm capabilities to AI models.

```json
{
  "name": "somewm",
  "version": "1.0",
  "tools": [
    {
      "name": "list_clients",
      "description": "List all open windows with their class, title, tag, and geometry",
      "parameters": {}
    },
    {
      "name": "focus_client",
      "description": "Focus a window by class or title pattern",
      "parameters": { "pattern": "string" }
    },
    {
      "name": "eval_lua",
      "description": "Execute arbitrary Lua code in the compositor",
      "parameters": { "code": "string" }
    },
    {
      "name": "screenshot",
      "description": "Take a screenshot, optionally of a specific region",
      "parameters": { "region": "string?" }
    },
    {
      "name": "set_wallpaper",
      "description": "Set the desktop wallpaper",
      "parameters": { "path": "string" }
    }
  ]
}
```

Can be used by:
- Our AI widget (local Gemma 4)
- Claude Code (via MCP config)
- Any MCP-compatible client

## Directory Structure

```
plans/somewm-web-widgets/
  server/                    # Go backend
    main.go
    api/
      compositor.go          # somewm-client bridge
      system.go              # /proc, /sys, sensors
      media.go               # MPRIS / playerctl
      audio.go               # PipeWire / PulseAudio
      network.go             # NetworkManager D-Bus
      weather.go             # weather API cache
      ai.go                  # Ollama proxy + MCP
    ws/
      hub.go                 # WebSocket hub
      events.go              # event types
    go.mod
  launcher/                  # Python WebView launcher
    somewm-widget            # CLI entry point
    launcher.py              # GTK + WebKitGTK + layer-shell
    widget_manager.py        # D-Bus service for toggle/close
  web/                       # Frontend widgets
    shared/
      ws-client.js           # WebSocket client library
      theme.css              # shared theme (matches somewm-one theme)
      components/            # shared web components
    dashboard/
      index.html
      app.js
      style.css
    music/
      index.html
      app.js
      style.css
    weather/
    ai/
    wallpapers/
    notifications/
    collage/
  mcp/                       # MCP server
    server.py                # or Go
    tools.py
```

## Theming

Web widgets read theme from server API:

```json
GET /api/theme
{
  "bg_base": "#1e1e2e",
  "fg_main": "#d4d4d4",
  "accent": "#e2b55a",
  "accent_dim": "#c49a3a",
  "font_ui": "Geist",
  "font_mono": "CommitMono Nerd Font Propo",
  "border_radius": 14,
  "shadow": { "radius": 30, "offset_y": 6, "opacity": 0.5 }
}
```

CSS custom properties auto-generated from somewm theme:
```css
:root {
  --bg-base: #1e1e2e;
  --fg-main: #d4d4d4;
  --accent: #e2b55a;
  --font-ui: 'Geist', sans-serif;
  --font-mono: 'CommitMono Nerd Font Propo', monospace;
  --radius: 14px;
}
```

## Keybindings (in rc.lua)

```lua
awful.key({ modkey }, "d", function()
    awful.spawn("somewm-widget toggle dashboard")
end, { description = "toggle dashboard", group = "widgets" }),

awful.key({ modkey }, "m", function()
    awful.spawn("somewm-widget toggle music")
end, { description = "toggle music player", group = "widgets" }),

awful.key({ modkey, "Shift" }, "a", function()
    awful.spawn("somewm-widget toggle ai")
end, { description = "toggle AI chat", group = "widgets" }),
```

## Implementation Phases

### Phase 1: Foundation
- [ ] Go server skeleton (HTTP + WebSocket + static files)
- [ ] Compositor bridge (somewm-client eval wrapper)
- [ ] Python WebView launcher (floating mode only)
- [ ] Shared JS WebSocket client library
- [ ] Theme API endpoint

### Phase 2: First Widgets
- [ ] Dashboard (system stats + client list + media mini)
- [ ] Music player (MPRIS via D-Bus)
- [ ] rc.lua keybindings

### Phase 3: Layer-shell + Polish
- [ ] GtkLayerShell support in launcher (overlay/panel modes)
- [ ] Slide-in/out animations (CSS)
- [ ] Notification center widget
- [ ] Weather widget

### Phase 4: Content Widgets
- [ ] Wallpaper changer (grid, categories, click to set)
- [ ] Collage viewer (local pinterest — masonry grid, lightbox, tags)

### Phase 5: AI Integration
- [ ] Ollama proxy in server (local Gemma 4, streaming)
- [ ] AI chat widget (markdown rendering, code highlight)
- [ ] MCP server for somewm (compositor tools for AI)
- [ ] AI can control compositor via MCP tools
- [ ] Widget marketplace / user-contributed widgets

## Dependencies

### System packages (Arch)
```bash
pacman -S webkit2gtk-4.1 gtk-layer-shell python-gobject
# For Go server:
pacman -S go
# For AI:
pacman -S ollama
```

### Key libraries
- **WebKitGTK 4.1** — web rendering engine
- **gtk-layer-shell** — Wayland layer-shell protocol for GTK
- **PyGObject** — Python GTK bindings
- **gorilla/websocket** — Go WebSocket library
- **godbus** — Go D-Bus library (for MPRIS, NetworkManager, PipeWire)

## Security Considerations

- Server binds to `127.0.0.1:9876` only (no external access)
- `eval` endpoint requires authentication token (env var or file)
- MCP tools have allowlist (no arbitrary command execution by default)
- WebView has no access to local filesystem (sandboxed)
- AI chat is local-only (Ollama), no data leaves machine
