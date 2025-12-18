-- awful.ipc - IPC command dispatcher for somewm
--
-- This module provides the command registry and dispatcher for the Unix socket
-- IPC system. Commands are registered with ipc.register(name, handler) and
-- executed when received from somewm-client.
--
-- Protocol:
--   Request:  COMMAND [ARGS...]\n
--   Response: STATUS [MESSAGE]\n[DATA...]\n\n

local gstring = require("gears.string")
local gtable = require("gears.table")

local ipc = {}
local commands = {}

--- Register a command handler
-- @param name Command name (e.g., "tag.view")
-- @param handler Function to execute command. Receives variadic args from command line.
--                Should return nil on success or result string.
--                Errors should be raised with error().
function ipc.register(name, handler)
  commands[name] = handler
end

--- Format userdata pointer as ID (remove space after colon)
-- Converts "userdata: 0x123" to "userdata:0x123" for easier CLI usage
local function format_id(userdata)
  return tostring(userdata):gsub(": ", ":")
end

--- Parse command string into command name and arguments
-- Converts "tag view 2" → {"tag.view", "2"}
-- Converts "exec kitty" → {"exec", "kitty"}
-- @param command_string Raw command from socket
-- @return command name, array of arguments
local function parse_command(command_string)
  -- Split on whitespace, but keep client IDs together
  -- Client IDs look like: window/client(title with spaces):0xHEX
  local parts = {}
  local i = 1

  while i <= #command_string do
    -- Skip whitespace
    local ws_start, ws_end = command_string:find("^%s+", i)
    if ws_start then
      i = ws_end + 1
    end

    if i > #command_string then break end

    -- Check if this looks like a client ID (starts with window/client or userdata)
    if command_string:find("^window/client%b():%w+", i) or
       command_string:find("^userdata:%w+", i) then
      -- Extract the full ID including spaces in the title
      local id_start = i
      local paren_start = command_string:find("%(", i)

      if paren_start then
        -- Find matching closing paren and then the :0xHEX part
        local depth = 0
        local j = paren_start
        while j <= #command_string do
          local char = command_string:sub(j, j)
          if char == "(" then
            depth = depth + 1
          elseif char == ")" then
            depth = depth - 1
            if depth == 0 then
              -- Found closing paren, now look for :0xHEX
              local colon_start, hex_end = command_string:find(":%w+", j)
              if colon_start then
                local space_after = command_string:find("%s", hex_end + 1) or (#command_string + 1)
                table.insert(parts, command_string:sub(id_start, space_after - 1))
                i = space_after
                break
              end
            end
          end
          j = j + 1
        end
      else
        -- userdata:0xHEX format (no parens)
        local word_end = command_string:find("%s", i) or (#command_string + 1)
        table.insert(parts, command_string:sub(i, word_end - 1))
        i = word_end
      end
    else
      -- Regular word (no spaces)
      local word_end = command_string:find("%s", i) or (#command_string + 1)
      table.insert(parts, command_string:sub(i, word_end - 1))
      i = word_end
    end
  end

  if #parts == 0 then
    return nil, {}
  end

  -- Single-word commands (no category)
  local single_word_commands = {
    ["ping"] = true,
    ["exec"] = true,
    ["quit"] = true,
    ["eval"] = true,
    ["input"] = true,
  }

  local cmd_name
  local args

  if #parts == 1 then
    cmd_name = parts[1]
    args = {}
  elseif single_word_commands[parts[1]] then
    -- Single-word command with arguments
    cmd_name = parts[1]
    args = { unpack(parts, 2) }
  else
    -- Two-part command name (e.g., "tag view")
    cmd_name = parts[1] .. "." .. parts[2]
    args = { unpack(parts, 3) }
  end

  return cmd_name, args
end

--- Execute IPC command
-- This is the main dispatcher called from C when a command is received.
-- @param command_string Raw command string from socket
-- @param client_fd File descriptor of connected client (for reference)
-- @return Response string in protocol format ("OK\n\n" or "ERROR msg\n\n")
function ipc.dispatch(command_string, client_fd)
  -- Parse command
  local cmd_name, args = parse_command(command_string)

  if not cmd_name then
    return "ERROR Empty command\n\n"
  end

  -- Find handler
  local handler = commands[cmd_name]
  if not handler then
    return string.format("ERROR Unknown command: %s\n\n", cmd_name)
  end

  -- Execute with error handling
  local success, result = pcall(handler, unpack(args))

  if not success then
    -- Error occurred
    return string.format("ERROR %s\n\n", tostring(result))
  end

  -- Success
  if result and result ~= "" then
    return string.format("OK\n%s\n\n", tostring(result))
  else
    return "OK\n\n"
  end
end

--- Register all built-in commands
local function register_builtin_commands()
  -- C API references (matches AwesomeWM pattern)
  local capi = {
    client = client,
    screen = screen,
    tag = tag,
    mouse = mouse,
    awesome = awesome,
    root = root,
  }

  -- Awful library imports
  local awful_client = require("awful.client")
  local awful_screen = require("awful.screen")
  local awful_tag = require("awful.tag")
  local awful_placement = require("awful.placement")
  local awful_spawn = require("awful.spawn")

  -- =================================================================
  -- BASIC COMMANDS
  -- =================================================================

  --- ping - Test connection
  ipc.register("ping", function()
    return "PONG"
  end)

  -- =================================================================
  -- TAG COMMANDS
  -- =================================================================

  --- tag.view <N> - Switch to tag N
  ipc.register("tag.view", function(tag_num)
    if not tag_num then
      error("Missing tag number")
    end

    local tag_idx = tonumber(tag_num)
    if not tag_idx then
      error("Invalid tag number: " .. tag_num)
    end

    -- Get focused screen
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    -- Get tags from screen
    local tags = s.tags
    if tag_idx < 1 or tag_idx > #tags then
      error(string.format("Invalid tag: %d (valid range: 1-%d)", tag_idx, #tags))
    end

    local tag_obj = tags[tag_idx]
    if not tag_obj then
      error(string.format("Tag %d not found on focused screen", tag_idx))
    end

    tag_obj:view_only()
    return string.format("Switched to tag %d", tag_idx)
  end)

  --- tag.toggle <N> - Toggle tag N visibility
  ipc.register("tag.toggle", function(tag_num)
    if not tag_num then
      error("Missing tag number")
    end

    local tag_idx = tonumber(tag_num)
    if not tag_idx then
      error("Invalid tag number: " .. tag_num)
    end

    -- Get focused screen
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    -- Get tags from screen
    local tags = s.tags
    if tag_idx < 1 or tag_idx > #tags then
      error(string.format("Invalid tag: %d (valid range: 1-%d)", tag_idx, #tags))
    end

    local tag_obj = tags[tag_idx]
    if not tag_obj then
      error(string.format("Tag %d not found on focused screen", tag_idx))
    end

    awful_tag.viewtoggle(tag_obj)
    return string.format("Toggled tag %d", tag_idx)
  end)

  --- tag.current - Get current active tag(s)
  ipc.register("tag.current", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    -- Get selected tags from screen
    local selectedtags = {}
    for i, t in ipairs(s.tags) do
      if t.selected then
        table.insert(selectedtags, i)
      end
    end

    if #selectedtags == 0 then
      return "No tags selected"
    end

    return table.concat(selectedtags, ",")
  end)

  --- tag.list - List all tags
  ipc.register("tag.list", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    -- Get tags for the focused screen
    local tags = s.tags

    local result = {}
    for i, t in ipairs(tags) do
      local status = t.selected and "[active]" or ""
      local name = t.name or tostring(i)
      table.insert(result, string.format("%d: %s %s", i, name, status))
    end

    return table.concat(result, "\n")
  end)

  -- =================================================================
  -- LAYOUT COMMANDS
  -- =================================================================

  local awful_layout = require("awful.layout")

  --- layout.list - List all available layouts for the current tag
  ipc.register("layout.list", function()
    local s = awful_screen.focused()
    if not s or not s.selected_tag then
      error("No focused screen or selected tag")
    end

    local layouts = s.selected_tag.layouts or awful_layout.layouts
    local current_layout = s.selected_tag.layout

    local result = {}
    for i, l in ipairs(layouts) do
      local marker = (l == current_layout) and "[active]" or ""
      table.insert(result, string.format("%d: %s %s", i, l.name, marker))
    end

    return table.concat(result, "\n")
  end)

  --- layout.get - Get current layout name
  ipc.register("layout.get", function()
    local s = awful_screen.focused()
    if not s or not s.selected_tag or not s.selected_tag.layout then
      error("No focused screen or selected tag")
    end

    return s.selected_tag.layout.name
  end)

  --- layout.set <name|number> - Set layout by name or index
  ipc.register("layout.set", function(layout_spec)
    if not layout_spec then
      error("Missing layout name or number")
    end

    local s = awful_screen.focused()
    if not s or not s.selected_tag then
      error("No focused screen or selected tag")
    end

    local layouts = s.selected_tag.layouts or awful_layout.layouts
    local target_layout = nil

    -- Try as number first
    local layout_idx = tonumber(layout_spec)
    if layout_idx then
      if layout_idx < 1 or layout_idx > #layouts then
        error(string.format("Invalid layout index: %d (valid range: 1-%d)", layout_idx, #layouts))
      end
      target_layout = layouts[layout_idx]
    else
      -- Try as name
      for _, l in ipairs(layouts) do
        if l.name == layout_spec then
          target_layout = l
          break
        end
      end

      if not target_layout then
        error(string.format("Layout not found: %s", layout_spec))
      end
    end

    s.selected_tag.layout = target_layout
    return string.format("Layout set to: %s", target_layout.name)
  end)

  --- layout.next - Cycle to next layout
  ipc.register("layout.next", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    awful_layout.inc(1, s)

    if s.selected_tag and s.selected_tag.layout then
      return string.format("Layout: %s", s.selected_tag.layout.name)
    else
      return "Layout changed"
    end
  end)

  --- layout.prev - Cycle to previous layout
  ipc.register("layout.prev", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    awful_layout.inc(-1, s)

    if s.selected_tag and s.selected_tag.layout then
      return string.format("Layout: %s", s.selected_tag.layout.name)
    else
      return "Layout changed"
    end
  end)

  -- =================================================================
  -- CLIENT COMMANDS
  -- =================================================================

  --- client.list - List all clients
  ipc.register("client.list", function()
    local clients_list = capi.client.get()
    if #clients_list == 0 then
      return "No clients"
    end

    local result = {}
    for _, c in ipairs(clients_list) do
      -- Get client properties
      local title = c.name or ""
      local appid = c.class or ""
      local floating = c.floating

      -- Get tag indices for this client
      local tag_list = {}
      local client_tags = c:tags()
      for _, t in ipairs(client_tags) do
        table.insert(tag_list, t.index)
      end

      -- Simple text format for now (JSON can be added later)
      local line = string.format(
        'id=%s title="%s" class="%s" tags=%s floating=%s',
        format_id(c),
        title,
        appid,
        table.concat(tag_list, ","),
        tostring(floating)
      )
      table.insert(result, line)
    end

    return table.concat(result, "\n")
  end)

  --- client.kill <ID|focused> - Kill a client
  ipc.register("client.kill", function(target)
    target = target or "focused"

    if target == "focused" then
      -- Use C API to get focused client directly
      local focusedclient = capi.client.focus
      if not focusedclient then
        error("No focused client")
      end
      capi.client.kill(focusedclient)
      return "Killed focused client"
    else
      -- Find by pointer address string
      for _, c in ipairs(capi.client.get()) do
        if format_id(c) == target then
          capi.client.kill(c)
          return string.format("Killed client %s", target)
        end
      end
      error("Client not found: " .. target)
    end
  end)

  --- client.focus <ID|next|prev> - Focus a client
  ipc.register("client.focus", function(target)
    if not target or target == "focused" then
      error("Must specify target: ID, next, or prev")
    end

    if target == "next" then
      -- TODO: Implement focus next/prev
      error("focus next/prev not yet implemented")
    elseif target == "prev" then
      error("focus next/prev not yet implemented")
    else
      -- Find by pointer address string
      for _, c in ipairs(capi.client.get()) do
        if format_id(c) == target then
          capi.client.focus = c
          return string.format("Focused client %s", target)
        end
      end
      error("Client not found: " .. target)
    end
  end)

  --- client.close <ID|focused> - Close a client gracefully
  ipc.register("client.close", function(target)
    target = target or "focused"

    if target == "focused" then
      -- Use C API to get focused client directly
      local focusedclient = capi.client.focus
      if not focusedclient then
        error("No focused client")
      end
      capi.client.kill(focusedclient)
      return "Closed focused client"
    else
      -- Find by pointer address string
      for _, c in ipairs(capi.client.get()) do
        if format_id(c) == target then
          capi.client.kill(c)
          return string.format("Closed client %s", target)
        end
      end
      error("Client not found: " .. target)
    end
  end)

  --- client.toggletag <TAG> [CLIENT_ID] - Toggle tag on client (default: focused)
  ipc.register("client.toggletag", function(tag_num, client_id)
    if not tag_num then
      error("Missing tag number")
    end

    local tag_idx = tonumber(tag_num)
    if not tag_idx then
      error("Invalid tag number: " .. tag_num)
    end

    -- Validate tag index (use AwesomeWM-compatible root.tags())
    local tag_count = #capi.root.tags()
    if tag_idx < 1 or tag_idx > tag_count then
      error(string.format("Invalid tag: %d (valid range: 1-%d)", tag_idx, tag_count))
    end

    -- Get target client
    local targetclient
    if not client_id or client_id == "focused" then
      targetclient = capi.client.focus
      if not targetclient then
        error("No focused client")
      end
    else
      -- Find by pointer address string (supports partial match on pointer address)
      for _, c in ipairs(capi.client.get()) do
        local full_id = format_id(c)
        if full_id == client_id or full_id:find(client_id, 1, true) then
          targetclient = c
          break
        end
      end
      if not targetclient then
        error("Client not found: " .. client_id)
      end
    end

    -- Get tag object (AwesomeWM-compatible approach)
    local all_tags = capi.root.tags()
    local tag_obj = all_tags[tag_idx]

    -- Use AwesomeWM's toggle_tag API
    targetclient:toggle_tag(tag_obj)

    -- Get updated tags to show result
    local tag_objects = targetclient:tags()
    local tag_list = {}
    for _, t in ipairs(tag_objects) do
      table.insert(tag_list, t.index)
    end

    return string.format("Toggled tag %d on client. Now on tags: %s", tag_idx, table.concat(tag_list, ","))
  end)

  --- client.movetotag <TAG> [CLIENT_ID] - Move client to exactly one tag (clears other tags)
  ipc.register("client.movetotag", function(tag_num, client_id)
    if not tag_num then
      error("Missing tag number")
    end

    local tag_idx = tonumber(tag_num)
    if not tag_idx then
      error("Invalid tag number: " .. tag_num)
    end

    -- Validate tag index (use AwesomeWM-compatible root.tags())
    local tag_count = #capi.root.tags()
    if tag_idx < 1 or tag_idx > tag_count then
      error(string.format("Invalid tag: %d (valid range: 1-%d)", tag_idx, tag_count))
    end

    -- Get target client
    local targetclient
    if not client_id or client_id == "focused" then
      targetclient = capi.client.focus
      if not targetclient then
        error("No focused client")
      end
    else
      -- Find by pointer address string (supports partial match on pointer address)
      for _, c in ipairs(capi.client.get()) do
        local full_id = format_id(c)
        if full_id == client_id or full_id:find(client_id, 1, true) then
          targetclient = c
          break
        end
      end
      if not targetclient then
        error("Client not found: " .. client_id)
      end
    end

    -- Get tag object (AwesomeWM-compatible approach)
    local all_tags = capi.root.tags()
    local tag_obj = all_tags[tag_idx]

    -- Use AwesomeWM's move_to_tag API
    targetclient:move_to_tag(tag_obj)

    return string.format("Moved client to tag %d", tag_idx)
  end)

  -- =================================================================
  -- CLIENT GEOMETRY COMMANDS
  -- =================================================================

  --- client.geometry <ID|focused> [x y w h] - Get or set client geometry
  ipc.register("client.geometry", function(target, x, y, w, h)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- If no coordinates provided, return current geometry
    if not x then
      local geom = c:geometry()
      return string.format("x=%d y=%d width=%d height=%d", geom.x, geom.y, geom.width, geom.height)
    end

    -- Set geometry
    x = tonumber(x)
    y = tonumber(y)
    w = tonumber(w)
    h = tonumber(h)

    if not x or not y or not w or not h then
      error("Invalid geometry values. Usage: client.geometry <ID> <x> <y> <w> <h>")
    end

    c:geometry({ x = x, y = y, width = w, height = h })
    return string.format("Set geometry to x=%d y=%d width=%d height=%d", x, y, w, h)
  end)

  --- client.move <ID|focused> <x> <y> - Move client to position
  ipc.register("client.move", function(target, x, y)
    if not x or not y then
      error("Missing arguments. Usage: client.move <ID|focused> <x> <y>")
    end

    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    x = tonumber(x)
    y = tonumber(y)
    if not x or not y then
      error("Invalid coordinates")
    end

    local geom = c:geometry()
    c:geometry({ x = x, y = y, width = geom.width, height = geom.height })
    return string.format("Moved to x=%d y=%d", x, y)
  end)

  --- client.resize <ID|focused> <w> <h> - Resize client
  ipc.register("client.resize", function(target, w, h)
    if not w or not h then
      error("Missing arguments. Usage: client.resize <ID|focused> <width> <height>")
    end

    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    w = tonumber(w)
    h = tonumber(h)
    if not w or not h then
      error("Invalid dimensions")
    end

    local geom = c:geometry()
    c:geometry({ x = geom.x, y = geom.y, width = w, height = h })
    return string.format("Resized to width=%d height=%d", w, h)
  end)

  --- client.moveresize <ID|focused> <dx> <dy> <dw> <dh> - Move and resize client relatively
  ipc.register("client.moveresize", function(target, dx, dy, dw, dh)
    if not dx or not dy or not dw or not dh then
      error("Missing arguments. Usage: client.moveresize <ID|focused> <dx> <dy> <dw> <dh>")
    end

    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    dx = tonumber(dx)
    dy = tonumber(dy)
    dw = tonumber(dw)
    dh = tonumber(dh)
    if not dx or not dy or not dw or not dh then
      error("Invalid delta values")
    end

    local geom = c:geometry()
    c:geometry({
      x = geom.x + dx,
      y = geom.y + dy,
      width = geom.width + dw,
      height = geom.height + dh,
    })
    return string.format(
      "Applied deltas: dx=%d dy=%d dw=%d dh=%d (new: x=%d y=%d w=%d h=%d)",
      dx,
      dy,
      dw,
      dh,
      geom.x + dx,
      geom.y + dy,
      geom.width + dw,
      geom.height + dh
    )
  end)

  --- client.center <ID|focused> - Center client on screen
  ipc.register("client.center", function(target)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- Use awful.placement API (same as rc.lua)
    awful_placement.centered(c)
    return "Centered client on screen"
  end)

  -- =================================================================
  -- CLIENT PROPERTY COMMANDS
  -- =================================================================

  --- client.floating <ID|focused> [true|false] - Get or set floating state
  ipc.register("client.floating", function(target, value)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- If no value provided, return current state
    if not value then
      return tostring(c.floating)
    end

    -- Set floating state
    local new_floating
    if value == "true" or value == "1" then
      new_floating = true
    elseif value == "false" or value == "0" then
      new_floating = false
    else
      error("Invalid value. Use 'true' or 'false'")
    end

    c.floating = new_floating
    return string.format("Set floating to %s", tostring(new_floating))
  end)

  --- client.fullscreen <ID|focused> [true|false] - Get or set fullscreen state
  ipc.register("client.fullscreen", function(target, value)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- If no value provided, return current state
    if not value then
      return tostring(c.fullscreen)
    end

    -- Set fullscreen state
    local new_fullscreen
    if value == "true" or value == "1" then
      new_fullscreen = true
    elseif value == "false" or value == "0" then
      new_fullscreen = false
    else
      error("Invalid value. Use 'true' or 'false'")
    end

    c.fullscreen = new_fullscreen
    return string.format("Set fullscreen to %s", tostring(new_fullscreen))
  end)

  --- client.sticky <ID|focused> [true|false] - Get or set sticky state (visible on all tags)
  ipc.register("client.sticky", function(target, value)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- If no value provided, return current state
    if not value then
      return tostring(c.sticky)
    end

    -- Set sticky state
    local new_sticky
    if value == "true" or value == "1" then
      new_sticky = true
    elseif value == "false" or value == "0" then
      new_sticky = false
    else
      error("Invalid value. Use 'true' or 'false'")
    end

    c.sticky = new_sticky
    return string.format("Set sticky to %s", tostring(new_sticky))
  end)

  --- client.ontop <ID|focused> [true|false] - Get or set ontop state
  ipc.register("client.ontop", function(target, value)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- If no value provided, return current state
    if not value then
      return tostring(c.ontop)
    end

    -- Set ontop state
    local new_ontop
    if value == "true" or value == "1" then
      new_ontop = true
    elseif value == "false" or value == "0" then
      new_ontop = false
    else
      error("Invalid value. Use 'true' or 'false'")
    end

    c.ontop = new_ontop
    return string.format("Set ontop to %s", tostring(new_ontop))
  end)

  -- =================================================================
  -- CLIENT STACK OPERATIONS
  -- =================================================================

  --- client.raise <ID|focused> - Raise client to top of stack
  ipc.register("client.raise", function(target)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    c:raise()
    return "Raised client to top of stack"
  end)

  --- client.lower <ID|focused> - Lower client to bottom of stack
  ipc.register("client.lower", function(target)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    c:lower()
    return "Lowered client to bottom of stack"
  end)

  --- client.swap <ID1> <ID2> - Swap two clients in the stack
  ipc.register("client.swap", function(id1, id2)
    if not id1 or not id2 then
      error("Missing arguments. Usage: client.swap <ID1> <ID2>")
    end

    -- Find both clients
    local c1, c2
    for _, c in ipairs(capi.client.get()) do
      if format_id(c) == id1 then
        c1 = c
      end
      if format_id(c) == id2 then
        c2 = c
      end
    end

    if not c1 then
      error("Client not found: " .. id1)
    end
    if not c2 then
      error("Client not found: " .. id2)
    end

    -- Use awful.client API (same as rc.lua)
    awful_client.swap(c1, c2)
    return string.format("Swapped %s and %s", id1, id2)
  end)

  --- client.swapidx <±N> [ID|focused] - Swap client with Nth client in stack
  ipc.register("client.swapidx", function(offset, target)
    if not offset then
      error("Missing argument. Usage: client.swapidx <±N> [ID|focused]")
    end

    offset = tonumber(offset)
    if not offset then
      error("Invalid offset. Must be a number")
    end

    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- Use awful.client API (same as rc.lua)
    awful_client.swap.byidx(offset, c)
    return string.format("Swapped with client at offset %d", offset)
  end)

  --- client.zoom <ID|focused> - Swap client with master (zoom)
  ipc.register("client.zoom", function(target)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- Use awful.client API (same as rc.lua)
    awful_client.setmaster(c)
    return "Zoomed client to master position"
  end)

  -- =================================================================
  -- CLIENT QUERY COMMANDS
  -- =================================================================

  --- client.visible - List all visible clients on current tags
  ipc.register("client.visible", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local visible_clients = awful_client.visible(s)
    if #visible_clients == 0 then
      return "No visible clients"
    end

    local result = {}
    for _, c in ipairs(visible_clients) do
      local title = c.name or ""
      local appid = c.class or ""
      table.insert(result, string.format('id=%s title="%s" class="%s"', format_id(c), title, appid))
    end

    return table.concat(result, "\n")
  end)

  --- client.tiled - List all tiled (non-floating) clients
  ipc.register("client.tiled", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tiled_clients = awful_client.tiled(s)
    if #tiled_clients == 0 then
      return "No tiled clients"
    end

    local result = {}
    for _, c in ipairs(tiled_clients) do
      local title = c.name or ""
      local appid = c.class or ""
      table.insert(result, string.format('id=%s title="%s" class="%s"', format_id(c), title, appid))
    end

    return table.concat(result, "\n")
  end)

  --- client.master - Get the master client on focused screen
  ipc.register("client.master", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local master = awful_client.getmaster(s)
    if not master then
      return "No master client"
    end

    local title = master.name or ""
    local appid = master.class or ""
    local geom = master:geometry()
    return string.format(
      'id=%s title="%s" class="%s" x=%d y=%d width=%d height=%d',
      format_id(master),
      title,
      appid,
      geom.x,
      geom.y,
      geom.width,
      geom.height
    )
  end)

  --- client.info <ID|focused> - Get comprehensive client information
  ipc.register("client.info", function(target)
    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- Gather comprehensive info
    local title = c.name or ""
    local appid = c.class or ""
    local geom = c:geometry()
    local floating = c.floating
    local fullscreen = c.fullscreen
    local sticky = c.sticky
    local ontop = c.ontop
    local urgent = c.urgent

    -- Get tag indices for this client
    local tag_list = {}
    local client_tags = c:tags()
    for _, t in ipairs(client_tags) do
      table.insert(tag_list, t.index)
    end

    local result = {}
    table.insert(result, string.format("ID: %s", format_id(c)))
    table.insert(result, string.format("Title: %s", title))
    table.insert(result, string.format("Class: %s", appid))
    table.insert(
      result,
      string.format("Geometry: x=%d y=%d width=%d height=%d", geom.x, geom.y, geom.width, geom.height)
    )
    table.insert(result, string.format("Tags: %s", table.concat(tag_list, ",")))
    table.insert(result, string.format("Floating: %s", tostring(floating)))
    table.insert(result, string.format("Fullscreen: %s", tostring(fullscreen)))
    table.insert(result, string.format("Sticky: %s", tostring(sticky)))
    table.insert(result, string.format("Ontop: %s", tostring(ontop)))
    table.insert(result, string.format("Urgent: %s", tostring(urgent)))

    return table.concat(result, "\n")
  end)

  -- =================================================================
  -- SCREEN COMMANDS
  -- =================================================================

  --- screen.list - List all screens/monitors
  ipc.register("screen.list", function()
    local screen_count = capi.screen.count()
    if screen_count == 0 then
      return "No screens"
    end

    local result = {}
    local focusedscreen = awful_screen.focused()

    for i = 1, screen_count do
      local s = capi.screen.get(i)
      local geom = s.geometry
      local is_focused = (s == focusedscreen)

      -- Get active tags for this screen
      local activetags = {}
      for j, t in ipairs(s.tags) do
        if t.selected then
          table.insert(activetags, j)
        end
      end

      -- Get current layout name
      local layout_name = "?"
      if s.selected_tag and s.selected_tag.layout then
        layout_name = s.selected_tag.layout.name or "?"
      end

      local line = string.format(
        'screen=%d geometry=%dx%d+%d+%d tags=%s layout="%s" focused=%s',
        s.index,
        geom.width,
        geom.height,
        geom.x,
        geom.y,
        table.concat(activetags, ","),
        layout_name,
        tostring(is_focused)
      )
      table.insert(result, line)
    end

    return table.concat(result, "\n")
  end)

  --- screen.focused - Get focused screen info
  ipc.register("screen.focused", function()
    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local name = capi.screen.name(s) or "Unknown"
    local geom = capi.screen.geometry(s)
    local tagmask = capi.screen.tags(s)
    local layout_idx = capi.screen.get_layout(s)
    local layout_symbol = capi.screen.get_layout_symbol(layout_idx)

    -- Convert tagmask to list
    local activetags = {}
    local tag_count = tag.count()
    for j = 1, tag_count do
      local bit = 2 ^ (j - 1)
      if tagmask % (bit * 2) >= bit then
        table.insert(activetags, j)
      end
    end

    return string.format(
      'id=%s name="%s" geometry=%dx%d+%d+%d tags=%s layout="%s"',
      format_id(s),
      name,
      geom.width,
      geom.height,
      geom.x,
      geom.y,
      table.concat(activetags, ","),
      layout_symbol or "?"
    )
  end)

  --- screen.count - Get number of screens
  ipc.register("screen.count", function()
    return tostring(capi.screen.count())
  end)

  --- screen.clients <screen_id> - List clients on a specific screen
  ipc.register("screen.clients", function(screen_id)
    if not screen_id then
      error("Missing screen ID")
    end

    -- Find the screen
    local targetscreen = nil
    for _, s in ipairs(capi.screen.get()) do
      if format_id(s) == screen_id then
        targetscreen = s
        break
      end
    end

    if not targetscreen then
      error("Screen not found: " .. screen_id)
    end

    -- Use target screen variable
    local s = targetscreen

    -- Find clients that have tags matching this screen
    local clients_list = capi.client.get()
    local screenclients = {}

    for _, c in ipairs(clients_list) do
      local clienttags = c:tags()
      -- Check if any client tag is on this screen
      local matches = false
      for _, t in ipairs(clienttags) do
        if t.screen == s then
          matches = true
          break
        end
      end

      if matches then
        local title = c.name or ""
        local appid = c.class or ""
        local floating = c.floating

        table.insert(
          screenclients,
          string.format('id=%s title="%s" class="%s" floating=%s', format_id(c), title, appid, tostring(floating))
        )
      end
    end

    if #screenclients == 0 then
      return "No clients on this screen"
    end

    return table.concat(screenclients, "\n")
  end)

  -- =================================================================
  -- MISC COMMANDS
  -- =================================================================

  --- exec <command...> - Spawn a process
  ipc.register("exec", function(...)
    local args = { ... }
    if #args == 0 then
      error("Missing command")
    end

    local cmd = table.concat(args, " ")
    awful_spawn.with_shell(cmd)
    return string.format("Spawned: %s", cmd)
  end)

  --- quit - Exit compositor
  ipc.register("quit", function()
    capi.awesome.quit()
    return "Exiting compositor"
  end)

  --- eval <lua_code> - Execute arbitrary Lua code
  ipc.register("eval", function(...)
    local code = table.concat({ ... }, " ")
    if not code or code == "" then
      error("Missing Lua code to evaluate")
    end

    -- Load and execute the code
    local func, err = loadstring(code)
    if not func then
      error("Syntax error: " .. tostring(err))
    end

    -- Execute and capture results
    local results = { pcall(func) }
    local success = table.remove(results, 1)

    if not success then
      error(tostring(results[1]))
    end

    -- Format results
    if #results == 0 then
      return "OK (no return value)"
    elseif #results == 1 then
      return tostring(results[1])
    else
      local formatted = {}
      for i, v in ipairs(results) do
        table.insert(formatted, tostring(v))
      end
      return table.concat(formatted, "\n")
    end
  end)

  --- hotkeys - Show hotkeys popup
  ipc.register("hotkeys", function()
    local hotkeys_popup = require("awful.hotkeys_popup")
    hotkeys_popup.show_help()
    return "Showing hotkeys popup"
  end)

  --- menubar - Show menubar application launcher
  ipc.register("menubar", function()
    local menubar = require("menubar")
    if not menubar.utils.terminal then
      menubar.utils.terminal = "alacritty"
    end
    menubar.show()
    return "Showing menubar"
  end)

  --- launcher - Alias for menubar
  ipc.register("launcher", function()
    local menubar = require("menubar")
    if not menubar.utils.terminal then
      menubar.utils.terminal = "alacritty"
    end
    menubar.show()
    return "Showing application launcher (menubar)"
  end)

  -- =================================================================
  -- SCREENSHOT COMMANDS
  -- =================================================================

  local cairo = require("lgi").cairo
  local gears_surface = require("gears.surface")

  --- screenshot.save <path> [--transparent] - Save screenshot to file
  -- Captures the entire desktop and saves to PNG file.
  -- Use --transparent to preserve alpha channel (no wallpaper).
  ipc.register("screenshot.save", function(...)
    local args = { ... }
    if #args == 0 then
      error("Missing file path. Usage: screenshot save <path> [--transparent]")
    end

    local path = nil
    local transparent = false

    -- Parse arguments
    for _, arg in ipairs(args) do
      if arg == "--transparent" or arg == "-t" then
        transparent = true
      elseif not path then
        path = arg
      end
    end

    if not path then
      error("Missing file path")
    end

    -- Get screenshot dimensions
    local w, h = capi.root.size()

    -- Get raw surface (with optional transparency preservation)
    local raw = capi.root.content(transparent)
    if not raw then
      error("Failed to capture screen content")
    end

    -- Create proper Cairo surface (ARGB32 to preserve alpha if requested)
    local format = transparent and cairo.Format.ARGB32 or cairo.Format.RGB24
    local surface = cairo.ImageSurface(format, w, h)
    local cr = cairo.Context(surface)
    cr:set_source_surface(gears_surface(raw))
    cr:paint()

    -- Save to file
    local status = surface:write_to_png(path)
    if status ~= "SUCCESS" then
      error("Failed to write PNG: " .. tostring(status))
    end

    return string.format("Screenshot saved to %s%s", path, transparent and " (with transparency)" or "")
  end)

  --- screenshot.client <path> [client_id] - Save client screenshot to file
  -- Captures a specific client window and saves to PNG file.
  ipc.register("screenshot.client", function(path, target)
    if not path then
      error("Missing file path. Usage: screenshot client <path> [client_id|focused]")
    end

    target = target or "focused"

    -- Get target client
    local c
    if target == "focused" then
      c = capi.client.focus
      if not c then
        error("No focused client")
      end
    else
      for _, cl in ipairs(capi.client.get()) do
        if format_id(cl) == target then
          c = cl
          break
        end
      end
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- Get client content
    local raw = c.content
    if not raw then
      error("Failed to capture client content")
    end

    -- Get client geometry for dimensions
    local geom = c:geometry()
    local bw = c.border_width or 0
    local _, top_size = c:titlebar_top()
    local _, right_size = c:titlebar_right()
    local _, bottom_size = c:titlebar_bottom()
    local _, left_size = c:titlebar_left()

    local w = geom.width - right_size - left_size
    local h = geom.height - bottom_size - top_size

    -- Create proper Cairo surface
    local surface = cairo.ImageSurface(cairo.Format.ARGB32, w, h)
    local cr = cairo.Context(surface)
    cr:set_source_surface(gears_surface(raw))
    cr:paint()

    -- Save to file
    local status = surface:write_to_png(path)
    if status ~= "SUCCESS" then
      error("Failed to write PNG: " .. tostring(status))
    end

    return string.format("Client screenshot saved to %s", path)
  end)

  --- screenshot.screen <path> [screen_id] - Save screen screenshot to file
  -- Captures a specific screen/monitor and saves to PNG file.
  ipc.register("screenshot.screen", function(path, screen_id)
    if not path then
      error("Missing file path. Usage: screenshot screen <path> [screen_id]")
    end

    -- Get target screen
    local s
    if not screen_id then
      s = awful_screen.focused()
    else
      local idx = tonumber(screen_id)
      if idx then
        s = capi.screen[idx]
      else
        -- Try to find by ID string
        for sc in capi.screen do
          if format_id(sc) == screen_id then
            s = sc
            break
          end
        end
      end
    end

    if not s then
      error("Screen not found")
    end

    -- Get screen content
    local raw = s.content
    if not raw then
      error("Failed to capture screen content")
    end

    -- Get screen geometry for dimensions
    local geom = s.geometry

    -- Create proper Cairo surface
    local surface = cairo.ImageSurface(cairo.Format.RGB24, geom.width, geom.height)
    local cr = cairo.Context(surface)
    cr:set_source_surface(gears_surface(raw))
    cr:paint()

    -- Save to file
    local status = surface:write_to_png(path)
    if status ~= "SUCCESS" then
      error("Failed to write PNG: " .. tostring(status))
    end

    return string.format("Screen %d screenshot saved to %s", s.index, path)
  end)

  -- =================================================================
  -- MOUSEGRABBER COMMANDS
  -- =================================================================

  --- mousegrabber.isrunning - Check if mousegrabber is active
  ipc.register("mousegrabber.isrunning", function()
    if mousegrabber and mousegrabber.isrunning then
      return tostring(mousegrabber.isrunning())
    else
      error("mousegrabber module not available")
    end
  end)

  --- mousegrabber.stop - Stop the mousegrabber
  ipc.register("mousegrabber.stop", function()
    if mousegrabber and mousegrabber.stop then
      mousegrabber.stop()
      return "Stopped mousegrabber"
    else
      error("mousegrabber module not available")
    end
  end)

  --- mousegrabber.test [max_events] - Test mousegrabber with a simple event counter
  -- Starts mousegrabber and prints events until max_events is reached or all buttons are released
  ipc.register("mousegrabber.test", function(max_events_str)
    if not mousegrabber or not mousegrabber.run then
      error("mousegrabber module not available")
    end

    if mousegrabber.isrunning() then
      error("mousegrabber already running. Use 'mousegrabber.stop' first")
    end

    local max_events = tonumber(max_events_str) or 10
    local event_count = 0
    local events_log = {}

    mousegrabber.run(function(coords)
      event_count = event_count + 1

      -- Format button state
      local buttons_str = string.format("[%s,%s,%s,%s,%s]",
        coords.buttons[1] and "1" or "0",
        coords.buttons[2] and "1" or "0",
        coords.buttons[3] and "1" or "0",
        coords.buttons[4] and "1" or "0",
        coords.buttons[5] and "1" or "0")

      -- Log this event
      table.insert(events_log, string.format("Event %d: x=%.0f y=%.0f buttons=%s",
        event_count, coords.x, coords.y, buttons_str))

      -- Stop after max_events or when no buttons are pressed
      if event_count >= max_events then
        table.insert(events_log, string.format("Reached max events (%d), stopping", max_events))
        return false
      end

      -- Check if any button is pressed
      local any_pressed = false
      for i = 1, 5 do
        if coords.buttons[i] then
          any_pressed = true
          break
        end
      end

      if not any_pressed and event_count > 1 then
        table.insert(events_log, "All buttons released, stopping")
        return false
      end

      -- Continue grabbing
      return true
    end, "crosshair")  -- Use crosshair cursor during grab

    return string.format("Started mousegrabber test (max %d events)\nMove mouse or click buttons to generate events\nThe grabber will stop when all buttons are released", max_events)
  end)

  --- mousegrabber.track - Start mousegrabber and continuously print coordinates
  -- Useful for testing mouse tracking. Stops when any button is released.
  ipc.register("mousegrabber.track", function()
    if not mousegrabber or not mousegrabber.run then
      error("mousegrabber module not available")
    end

    if mousegrabber.isrunning() then
      error("mousegrabber already running. Use 'mousegrabber.stop' first")
    end

    mousegrabber.run(function(coords)
      -- Print coordinates in real-time (will appear in somewm stdout)
      print(string.format("[mousegrabber] x=%.0f y=%.0f", coords.x, coords.y))

      -- Check if any button is pressed
      local any_pressed = false
      for i = 1, 5 do
        if coords.buttons[i] then
          any_pressed = true
          print(string.format("[mousegrabber] Button %d pressed!", i))
        end
      end

      -- Continue while any button is pressed, stop when all released
      return any_pressed
    end, "crosshair")

    return "Started mousegrabber coordinate tracking\nPress any mouse button and move the mouse\nRelease all buttons to stop"
  end)

  -- ============================================================================
  -- INPUT COMMANDS
  -- ============================================================================
  -- Configure libinput settings at runtime via awful.input module

  local awful_input = require("awful.input")

  -- Map of setting names to their types and descriptions
  local input_settings = {
    tap_to_click = { type = "int", desc = "Enable tap-to-click (0=off, 1=on, -1=default)" },
    tap_and_drag = { type = "int", desc = "Enable tap-and-drag (0=off, 1=on, -1=default)" },
    drag_lock = { type = "int", desc = "Enable drag lock (0=off, 1=on, -1=default)" },
    natural_scrolling = { type = "int", desc = "Enable natural scrolling (0=off, 1=on, -1=default)" },
    disable_while_typing = { type = "int", desc = "Disable touchpad while typing (0=off, 1=on, -1=default)" },
    left_handed = { type = "int", desc = "Left-handed mode (0=off, 1=on, -1=default)" },
    middle_button_emulation = { type = "int", desc = "Middle button emulation (0=off, 1=on, -1=default)" },
    scroll_method = { type = "string", desc = "Scroll method (no_scroll/two_finger/edge/button)" },
    click_method = { type = "string", desc = "Click method (none/button_areas/clickfinger)" },
    send_events_mode = { type = "string", desc = "Send events mode (enabled/disabled/disabled_on_external_mouse)" },
    accel_profile = { type = "string", desc = "Acceleration profile (flat/adaptive)" },
    accel_speed = { type = "number", desc = "Acceleration speed (-1.0 to 1.0)" },
    tap_button_map = { type = "string", desc = "Tap button mapping (lrm/lmr)" },
    keyboard_repeat_rate = { type = "int", desc = "Keyboard repeat rate (repeats per second)" },
    keyboard_repeat_delay = { type = "int", desc = "Keyboard repeat delay (ms before repeat starts)" },
    xkb_layout = { type = "string", desc = "XKB keyboard layout (e.g., 'us', 'us,ru')" },
    xkb_variant = { type = "string", desc = "XKB layout variant (e.g., 'dvorak')" },
    xkb_options = { type = "string", desc = "XKB options (e.g., 'ctrl:nocaps')" },
  }

  --- input [setting] [value] - Get or set libinput/keyboard configuration
  -- No args: list all settings with current values
  -- One arg: get current value of setting
  -- Two args: set setting to value
  ipc.register("input", function(setting, value)
    -- No args: list all settings
    if not setting then
      local lines = { "Input settings (current values):" }
      -- Sort the keys for consistent output
      local sorted_keys = {}
      for k in pairs(input_settings) do
        table.insert(sorted_keys, k)
      end
      table.sort(sorted_keys)

      for _, name in ipairs(sorted_keys) do
        local info = input_settings[name]
        local current = awful_input[name]
        if current == nil then current = "(nil)" end
        table.insert(lines, string.format("  %-25s = %-10s  # %s", name, tostring(current), info.desc))
      end
      return table.concat(lines, "\n")
    end

    -- Check if setting is valid
    local info = input_settings[setting]
    if not info then
      local valid_settings = {}
      for k in pairs(input_settings) do
        table.insert(valid_settings, k)
      end
      table.sort(valid_settings)
      error("Unknown setting: " .. setting .. "\nValid settings: " .. table.concat(valid_settings, ", "))
    end

    -- One arg: get current value
    if value == nil then
      local current = awful_input[setting]
      if current == nil then return "(nil)" end
      return tostring(current)
    end

    -- Two args: set value
    local new_value
    if info.type == "int" then
      new_value = tonumber(value)
      if not new_value then
        error("Invalid integer value: " .. value)
      end
      new_value = math.floor(new_value)
    elseif info.type == "number" then
      new_value = tonumber(value)
      if not new_value then
        error("Invalid number value: " .. value)
      end
    elseif info.type == "string" then
      new_value = value
    end

    awful_input[setting] = new_value
    return string.format("%s = %s", setting, tostring(new_value))
  end)
end

-- Initialize built-in commands
register_builtin_commands()

-- Register global dispatcher function (called from C)
function _G._ipc_dispatch(command_string, client_fd)
  return ipc.dispatch(command_string, client_fd)
end

return ipc
