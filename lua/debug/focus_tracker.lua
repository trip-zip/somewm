--[[
  Focus Tracker Debug Widget

  Displays real-time compositor state:
  - Current monitor name and resolution
  - Visible tags on current monitor
  - Focused client info (title, app_id, mode)
  - Cursor position and monitor

  Usage in rc.lua:
    local focus_tracker = require("debug.focus_tracker")
    focus_tracker.init()

  Keybinding to toggle:
    Mod4+Shift+D
]]
--

local wibox_module = require("wibox")
local textbox = require("wibox.widget.textbox")
local client_focus = require("awful.client.focus")
local awful_client = require("awful.client")
local awful_screen = require("awful.screen")
-- _client, _screen, awesome are globals, not modules
-- Use awesome.connect_signal() for global signals (AwesomeWM pattern)
local gtimer = require("gears.timer")
local bitwise = require("gears.bitwise")

local focus_tracker = {}
local focus_widget = nil
local focus_wibox = nil
local update_timer = nil
local is_initialized = false

-- Create the widget (called lazily on first show)
local function create_widget()
  if focus_wibox then
    return focus_wibox
  end

  -- Create textbox widget with monospace font and green text
  focus_widget = textbox.new("Initializing...")
  focus_widget:set_color({ 0.2, 0.9, 0.2, 1.0 }) -- Bright green
  focus_widget:set_font("Monospace 10")

  -- Create wibox container in top-right corner
  -- Position will be adjusted based on monitor width
  local focused_mon = awful_screen.focused()
  local geom = focused_mon and awful_screen.geometry(focused_mon) or { x = 0, y = 0, width = 1920, height = 1080 }

  focus_wibox = wibox_module({
    x = geom.width - 420, -- 420px from left = 10px from right with 410px width
    y = 10,
    width = 410,
    height = 110,
    visible = false,
  })

  focus_wibox.widget = focus_widget

  return focus_wibox
end

-- Format a tag bitmask as a string like "[1] 2 [3]"
local function format_tags(tagmask)
  if not tagmask or tagmask == 0 then
    return "none"
  end

  local parts = {}
  for i = 1, 9 do
    local bit = bitwise.lshift(1, i - 1)
    if bitwise.band(tagmask, bit) ~= 0 then
      table.insert(parts, string.format("[%d]", i))
    else
      table.insert(parts, tostring(i))
    end
  end
  return table.concat(parts, " ")
end

-- Update the widget display with current state
local function update_display()
  if not focus_wibox or not focus_widget then
    return
  end

  local lines = {}

  -- Line 1: Monitor info
  local focused_mon = awful_screen.focused()
  if focused_mon then
    local mon_name = awful_screen.name(focused_mon) or "unknown"
    local geom = awful_screen.geometry(focused_mon)
    table.insert(lines, string.format("Monitor: %s (%dx%d)", mon_name, geom.width, geom.height))

    -- Line 2: Tags on focused monitor
    local tags = awful_screen.tags(focused_mon)
    table.insert(lines, string.format("Tags: %s", format_tags(tags)))
  else
    table.insert(lines, "Monitor: none")
    table.insert(lines, "Tags: none")
  end

  -- Line 3: Focused client
  local focused = client_focus.get()
  if focused then
    local title = _client.title(focused) or "untitled"
    local appid = _client.appid(focused) or "unknown"
    local is_floating = awful_client.floating.get(focused)
    local mode = is_floating and "FLOAT" or "TILE"

    -- Truncate title if too long
    if #title > 30 then
      title = title:sub(1, 27) .. "..."
    end

    table.insert(lines, string.format("Client: %s (%s) [%s]", title, appid, mode))
  else
    table.insert(lines, "Client: none")
  end

  -- Line 4: Cursor position
  local cursor_pos = awesome.get_cursor_position()
  local cursor_mon = awesome.get_cursor_monitor()
  local cursor_mon_name = "none"
  if cursor_mon then
    cursor_mon_name = awful_screen.name(cursor_mon) or "unknown"
  end
  table.insert(lines, string.format("Cursor: (%.0f, %.0f) on %s", cursor_pos.x, cursor_pos.y, cursor_mon_name))

  -- Set the text (with background)
  local text = table.concat(lines, "\n")
  focus_widget:set_text(text)

  -- Note: Redraw is automatic via widget signals
end

-- Initialize the focus tracker
function focus_tracker.init()
  if is_initialized then
    return
  end
  is_initialized = true

  -- Don't create widget yet - wait until first toggle
  -- This avoids trying to create a wibox before monitors are available

  -- Connect to signals for immediate updates (when widget exists)
  -- Use awesome.connect_signal() for global signals (AwesomeWM pattern)
  awesome.connect_signal("client::focus", update_display)
  awesome.connect_signal("client::unfocus", update_display)
  awesome.connect_signal("client::property::name", update_display)
  awesome.connect_signal("client::property::floating", update_display)
  awesome.connect_signal("tag::viewchange", update_display)
  awesome.connect_signal("screen::focus", update_display)

  -- Set up timer for cursor position updates (100ms)
  update_timer = gtimer.new({
    timeout = 0.1,
    autostart = false,
    callback = update_display,
  })
end

-- Toggle widget visibility
function focus_tracker.toggle()
  if not is_initialized then
    focus_tracker.init()
  end

  local wb = create_widget()

  if wb.visible then
    wb:hide()
    if update_timer then
      update_timer:stop()
    end
  else
    -- Update position based on current focused monitor
    local focused_mon = awful_screen.focused()
    if focused_mon then
      local geom = awful_screen.geometry(focused_mon)
      -- Reposition to top-right of focused monitor
      -- Note: wibox doesn't currently support repositioning, so this is FYI
      -- In future, we could destroy and recreate at new position
    end

    update_display()
    -- Note: _redraw() is automatic in widget system
    wb:show()
    if update_timer then
      update_timer:start()
    end
  end
end

-- Show the widget
function focus_tracker.show()
  if not is_initialized then
    focus_tracker.init()
  end

  local wb = create_widget()
  if not wb.visible then
    update_display()
    wb:show()
    if update_timer then
      update_timer:start()
    end
  end
end

-- Hide the widget
function focus_tracker.hide()
  if focus_wibox and focus_wibox.visible then
    focus_wibox:hide()
    if update_timer then
      update_timer:stop()
    end
  end
end

return focus_tracker
