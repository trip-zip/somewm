# somewm-one Component Architecture

## Vision

Modular, event-driven wibar component system for somewm-one.
Inspired by raven2cz's AwesomeWM multicolor theme (`fishlive` library)
but redesigned for cleaner architecture and somewm/Wayland specifics.

## Architecture: Signal Broker + Component Factory

### Core Principles

1. **MVC separation**: Data producers (signals) → Broker → View components (widgets)
2. **Theme independence**: Components are theme-agnostic; theme provides colors/fonts/icons
3. **Factory pattern**: Components created via factory based on theme + screen config
4. **Hot-swap**: New theme = new widget instances, same data pipeline
5. **Lazy evaluation**: Signal producers start only when a consumer connects

### Layer Diagram

```
┌─────────────────────────────────────────────────────┐
│                    rc.lua (orchestrator)             │
│  - Loads theme, creates wibar, binds keys           │
│  - Calls factory.create("cpu", screen, theme)       │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│              factory.lua (component factory)         │
│  - Resolves: theme_name/component → module          │
│  - Fallback chain: themed → standard → error        │
│  - create(name, screen, theme, config) → widget     │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│           components/cpu.lua (view component)       │
│  - Subscribes to broker signal "data::cpu"          │
│  - Renders wibox widget (textbox, graph, icon)      │
│  - Theme-aware: reads beautiful.* for styling       │
└────────────────────────┬────────────────────────────┘
                         │ broker.connect_signal("data::cpu", fn)
┌────────────────────────▼────────────────────────────┐
│              broker.lua (signal broker)              │
│  - Global pub/sub with value caching                │
│  - connect_signal(name, fn)                         │
│  - emit_signal(name, data)                          │
│  - get_value(name) → last cached data               │
│  - Lazy start: first connect triggers producer      │
└────────────────────────┬────────────────────────────┘
                         │ producer auto-started
┌────────────────────────▼────────────────────────────┐
│          services/cpu.lua (data producer/service)    │
│  - Timer-based: reads /proc/stat every N seconds    │
│  - Parses data → broker.emit_signal("data::cpu", {})│
│  - No UI dependency, pure data                      │
└─────────────────────────────────────────────────────┘
```

### File Structure

```
plans/somewm-one/
├── rc.lua                      # Main config (orchestrator)
├── themes/
│   └── default/
│       └── theme.lua           # Theme definition (colors, fonts, icons)
├── fishlive/                   # Core library
│   ├── init.lua                # Module registration
│   ├── broker.lua              # Signal broker (pub/sub + cache)
│   ├── service.lua             # Base service class (timer + async)
│   ├── services/               # Data producers (model layer)
│   │   ├── init.lua            # Auto-register all services
│   │   ├── cpu.lua             # CPU usage from /proc/stat
│   │   ├── gpu.lua             # GPU usage + temp (nvidia-smi)
│   │   ├── memory.lua          # RAM usage from /proc/meminfo
│   │   ├── disk.lua            # Disk space (btrfs-aware)
│   │   ├── network.lua         # Upload/download rates
│   │   ├── volume.lua          # PulseAudio/PipeWire volume
│   │   ├── updates.lua         # Arch + AUR update count
│   │   └── keyboard.lua        # Keyboard layout cz/en
│   ├── factory.lua             # Component factory
│   └── components/             # View components (widget layer)
│       ├── init.lua            # Component registry
│       ├── cpu.lua             # CPU widget
│       ├── gpu.lua             # GPU widget
│       ├── memory.lua          # RAM widget
│       ├── disk.lua            # Disk widget
│       ├── network.lua         # Network widget
│       ├── volume.lua          # Volume widget (click to mute, scroll)
│       ├── updates.lua         # Updates widget
│       ├── keyboard.lua        # Keyboard layout indicator
│       ├── clock.lua           # Clock + calendar popup
│       └── layoutbox.lua       # Layout indicator
```

## Broker (Enhanced from fishlive)

Improvements over original `fishlive.signal.broker`:
- **Lazy producers**: Service starts only when first consumer connects
- **Typed signals**: `data::` prefix for data, `action::` for user actions
- **Disconnect cleanup**: When last consumer disconnects, stop producer timer
- **Error isolation**: Consumer errors don't crash other consumers

```lua
local broker = {
    _values = {},      -- cached last values
    _signals = {},     -- signal_name -> { consumers = {fn=true}, producer = service }
}

function broker.connect_signal(name, fn)
    -- Register consumer
    -- If first consumer and producer registered, start producer
end

function broker.disconnect_signal(name, fn)
    -- Unregister consumer
    -- If last consumer, stop producer timer
end

function broker.emit_signal(name, data)
    -- Cache value, notify all consumers
    -- Error isolation: pcall each consumer
end

function broker.register_producer(name, service)
    -- Associate a service with a signal name
    -- Service auto-starts when first consumer connects
end

function broker.get_value(name)
    return broker._values[name]
end
```

## Service Base Class

```lua
-- fishlive/service.lua
local service = {}
service.__index = service

function service.new(opts)
    return setmetatable({
        signal_name = opts.signal,          -- "data::cpu"
        interval = opts.interval or 5,      -- seconds
        command = opts.command,              -- shell command (optional)
        parser = opts.parser,               -- function(stdout) -> data table
        poll_fn = opts.poll_fn,             -- function() -> data (for /proc reads)
        timer = nil,
        running = false,
    }, service)
end

function service:start()
    if self.running then return end
    self.running = true
    -- Create gears.timer, call poll_fn or spawn command
end

function service:stop()
    if not self.running then return end
    self.running = false
    -- Stop timer
end

function service:poll()
    -- If command: awful.spawn.easy_async
    -- If poll_fn: direct call
    -- Parse result, emit via broker
end
```

## Services (Data Producers)

### CPU (`services/cpu.lua`)
- **Source**: `/proc/stat` (direct file read, no shell spawn)
- **Interval**: 2s
- **Signal**: `data::cpu`
- **Data**: `{ usage = 45.2, cores = {23, 67, 34, 55} }`

### GPU (`services/gpu.lua`)
- **Source**: `nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits`
- **Interval**: 3s
- **Signal**: `data::gpu`
- **Data**: `{ usage = 30, temp = 65, name = "RTX 4070 S" }`

### Memory (`services/memory.lua`)
- **Source**: `/proc/meminfo` (direct read)
- **Interval**: 3s
- **Signal**: `data::memory`
- **Data**: `{ used = 8192, total = 32768, percent = 25.0, swap_used = 0, swap_total = 8192 }`

### Disk (`services/disk.lua`)
- **Source**: `btrfs filesystem usage -b /` (btrfs-aware!)
- **Interval**: 60s
- **Signal**: `data::disk`
- **Data**: `{ mounts = { ["/"] = { used = "50G", total = "500G", percent = 10 } } }`
- **Note**: Falls back to `df` for non-btrfs filesystems

### Network (`services/network.lua`)
- **Source**: `/proc/net/dev` (direct read, compute delta)
- **Interval**: 2s
- **Signal**: `data::network`
- **Data**: `{ interface = "enp5s0", rx_rate = 1024000, tx_rate = 512000 }`
- **Note**: Stores previous values to compute rate/sec

### Volume (`services/volume.lua`)
- **Source**: `wpctl get-volume @DEFAULT_AUDIO_SINK@` (PipeWire via WirePlumber)
- **Interval**: 1s (or event-driven via `pactl subscribe`)
- **Signal**: `data::volume`
- **Data**: `{ volume = 75, muted = false, icon = "󰕾" }`
- **Actions**: `action::volume_up`, `action::volume_down`, `action::volume_toggle`

### Updates (`services/updates.lua`)
- **Source**: `checkupdates 2>/dev/null | wc -l` + `paru -Qua 2>/dev/null | wc -l`
- **Interval**: 600s (10 min)
- **Signal**: `data::updates`
- **Data**: `{ official = 12, aur = 3, total = 15 }`

### Keyboard (`services/keyboard.lua`)
- **Source**: `awesome.xkb_get_layout_group()` + signal `xkb::map_changed`
- **Interval**: event-driven (no polling)
- **Signal**: `data::keyboard`
- **Data**: `{ layout = "cz", layouts = {"us", "cz"} }`

## Components (View Widgets)

Each component:
1. Connects to broker signal in `create()`
2. Returns a wibox widget
3. Reads `beautiful.*` for theme styling
4. Supports click/scroll interactions

### Standard Component Pattern

```lua
-- fishlive/components/cpu.lua
local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, theme_config)
    local icon = wibox.widget.textbox()
    local text = wibox.widget.textbox()

    local widget = wibox.widget {
        icon, text,
        layout = wibox.layout.fixed.horizontal,
        spacing = beautiful.widget_spacing or 4,
    }

    broker.connect_signal("data::cpu", function(data)
        icon.markup = string.format(
            '<span color="%s">󰻠</span>',
            beautiful.widget_cpu_color or beautiful.fg_normal)
        text.markup = string.format(
            '<span color="%s">%d%%</span>',
            beautiful.widget_cpu_color or beautiful.fg_normal,
            data.usage)
    end)

    -- Optional: click to open htop
    widget:buttons(gears.table.join(
        awful.button({}, 1, function()
            awful.spawn(beautiful.terminal .. " -e htop")
        end)
    ))

    return widget
end

return M
```

## Wibar Assembly (in rc.lua)

```lua
local factory = require("fishlive.factory")

screen.connect_signal("request::desktop_decoration", function(s)
    s.mywibox = awful.wibar {
        position = "top",
        screen = s,
        height = dpi(28),
        widget = {
            layout = wibox.layout.align.horizontal,
            -- Left
            { layout = wibox.layout.fixed.horizontal,
                factory.create("layoutbox", s),
                s.mytaglist,
            },
            -- Center
            factory.create("clock", s),
            -- Right
            { layout = wibox.layout.fixed.horizontal,
                factory.create("keyboard", s),
                factory.create("updates", s),
                factory.create("network", s),
                factory.create("cpu", s),
                factory.create("gpu", s),
                factory.create("memory", s),
                factory.create("disk", s),
                factory.create("volume", s),
                wibox.widget.systray(),
            },
        },
    }
end)
```

## Theme Integration

Theme defines widget-specific colors and icons:

```lua
-- theme.lua (additions)
theme.widget_spacing        = dpi(6)
theme.widget_separator      = " "

-- Per-widget colors (Catppuccin Mocha palette)
theme.widget_cpu_color      = "#89b4fa"  -- blue
theme.widget_gpu_color      = "#a6e3a1"  -- green
theme.widget_memory_color   = "#cba6f7"  -- mauve
theme.widget_disk_color     = "#f9e2af"  -- yellow
theme.widget_network_color  = "#94e2d5"  -- teal
theme.widget_volume_color   = "#f38ba8"  -- red
theme.widget_updates_color  = "#fab387"  -- peach
theme.widget_keyboard_color = "#74c7ec"  -- sapphire
theme.widget_clock_color    = "#f5e0dc"  -- rosewater
```

## Implementation Order

1. **Phase 1: Core** — broker.lua, service.lua, factory.lua
2. **Phase 2: Essential services** — cpu, memory, volume, clock
3. **Phase 3: System services** — disk (btrfs), network, updates, keyboard
4. **Phase 4: GPU + polish** — gpu (nvidia-smi), calendar popup, click actions
5. **Phase 5: Theme** — Catppuccin Mocha defaults, theme.lua updates

## Improvements Over Original fishlive

| Aspect | fishlive (AwesomeWM) | somewm-one |
|--------|---------------------|------------|
| Broker | Global `_DEVIL_VALS` | Module-scoped, error-isolated |
| Producers | Mix of `awful.widget.watch` and custom | Unified `service.lua` base class |
| Factory | Theme+monitor prefix chain | Simpler: theme override or standard |
| Storage | `df` only | btrfs-aware (`btrfs filesystem usage`) |
| Volume | `amixer -D pulse` | `wpctl` (PipeWire native) |
| GPU | Not present | nvidia-smi integration |
| Keyboard | Not present | xkb native integration |
| Services | Always running | Lazy start/stop on consumer connect |

## Review Results (Sonnet + GPT-5.4)

### Accepted Changes

1. **Service registration order**: Enforce `services/init.lua` required BEFORE any `factory.create()` call. If consumer connects before producer registered, `register_producer()` auto-starts when consumers already exist.

2. **Volume: event-driven**: Replace 1s `wpctl` poll with `pactl subscribe` via `awful.spawn.with_line_callback` for instant updates. Use `wpctl get-volume` only on relevant events.

3. **Network state**: Previous rx/tx counters stored on service instance (`last_rx`, `last_tx`, `last_ts`). Reset on start and interface change.

4. **Disk: configurable mounts**: Don't assume `/` only. Config-driven mount list with per-mount btrfs/df detection.

5. **Service error handling**: Parsers return `nil` on error → broker skips emit. No corrupt data propagation.

6. **Async race guard**: Services check `self.running` + generation token before emitting after async callback.

7. **Keyboard**: Verified — `awesome.xkb_get_layout_group()` wired in `luaa.c:886`, `xkb::group_changed` signal in `somewm.c:3391`. Event-driven, no polling needed.

### Not Needed

- Circuit breaker: pcall + throttled logging sufficient
- Battery/backlight: desktop-only (RTX 4070 S), skip for now
- MPRIS: later phase, not wibar priority
