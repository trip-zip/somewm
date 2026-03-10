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

-- Lua 5.2+ compatibility
local unpack = unpack or table.unpack
local loadstring = loadstring or load

local ipc = {}
local commands = {}

-- Simple JSON encoder for IPC responses
local function json_encode_value(val, indent, depth)
  indent = indent or ""
  depth = depth or 0
  local t = type(val)

  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then -- NaN
      return "null"
    elseif val == math.huge or val == -math.huge then
      return "null"
    else
      return tostring(val)
    end
  elseif t == "string" then
    -- Escape special characters
    local escaped = val:gsub('\\', '\\\\')
                       :gsub('"', '\\"')
                       :gsub('\n', '\\n')
                       :gsub('\r', '\\r')
                       :gsub('\t', '\\t')
    return '"' .. escaped .. '"'
  elseif t == "table" then
    -- Check if array (sequential integer keys starting at 1)
    local is_array = true
    local max_idx = 0
    for k, _ in pairs(val) do
      if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
        is_array = false
        break
      end
      if k > max_idx then max_idx = k end
    end
    -- Also verify no holes
    if is_array and max_idx > 0 then
      for i = 1, max_idx do
        if val[i] == nil then
          is_array = false
          break
        end
      end
    end

    local parts = {}
    if is_array and max_idx > 0 then
      for i = 1, max_idx do
        table.insert(parts, json_encode_value(val[i], indent, depth + 1))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- Object
      for k, v in pairs(val) do
        local key = type(k) == "string" and k or tostring(k)
        table.insert(parts, json_encode_value(key, indent, depth + 1) .. ":" .. json_encode_value(v, indent, depth + 1))
      end
      if #parts == 0 then
        return "{}"
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif t == "userdata" then
    -- Format userdata as string ID
    return json_encode_value(tostring(val):gsub(": ", ":"), indent, depth)
  else
    return '"' .. tostring(val) .. '"'
  end
end

-- Encode a table to JSON string
local function json_encode(val)
  return json_encode_value(val)
end

-- Export for commands that want to return structured data
ipc.json_encode = json_encode

--- Register a command handler
-- @param name Command name (e.g., "tag.view")
-- @param handler Function to execute command. Receives variadic args from command line.
--                Should return nil on success or result string.
--                Errors should be raised with error().
function ipc.register(name, handler)
  commands[name] = handler
end

--- Format userdata pointer as ID for screens (remove space after colon)
-- Converts "screen: 0x123" to "screen:0x123" for CLI usage.
-- Note: Clients use numeric IDs (c.id) instead.
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
    ["version"] = true,
    ["lock"] = true,
    ["reload"] = true,
    ["restart"] = true,
    ["hotkeys"] = true,
    ["menubar"] = true,
    ["launcher"] = true,
    ["notify"] = true,
    ["dpms"] = true,
    ["idle"] = true,
    ["commands"] = true,
    ["subscribe"] = true,
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
-- Active subscribers: client_fd -> filter_set (table of event_type=true, or true for all)
local subscribers = {}
local subscriber_count = 0

function ipc.dispatch(command_string, client_fd)
  -- Check for --json flag
  local json_mode = false
  if command_string:match("^%-%-json%s+") then
    json_mode = true
    command_string = command_string:gsub("^%-%-json%s+", "")
  end

  -- Parse command
  local cmd_name, args = parse_command(command_string)

  if not cmd_name then
    if json_mode then
      return json_encode({status = "error", error = "Empty command"}) .. "\n\n"
    end
    return "ERROR Empty command\n\n"
  end

  -- Handle subscribe specially (needs client_fd)
  if cmd_name == "subscribe" then
    if _ipc_subscribe then
      _ipc_subscribe(client_fd)
    end
    -- Store filter set for this subscriber
    if not subscribers[client_fd] then
      subscriber_count = subscriber_count + 1
    end
    if #args > 0 then
      local filters = {}
      for _, event_type in ipairs(args) do
        if event_type == "all" then
          filters = true
          break
        end
        filters[event_type] = true
      end
      subscribers[client_fd] = filters
    else
      subscribers[client_fd] = true -- true means all events
    end
    if json_mode then
      return json_encode({status = "ok", result = "Subscribed to events"}) .. "\n\n"
    end
    return "OK\nSubscribed to events\n\n"
  end

  -- Find handler
  local handler = commands[cmd_name]
  if not handler then
    if json_mode then
      return json_encode({status = "error", error = "Unknown command: " .. cmd_name}) .. "\n\n"
    end
    return string.format("ERROR Unknown command: %s\n\n", cmd_name)
  end

  -- Execute with error handling
  local success, result = pcall(handler, unpack(args))

  if not success then
    -- Error occurred
    if json_mode then
      return json_encode({status = "error", error = tostring(result)}) .. "\n\n"
    end
    return string.format("ERROR %s\n\n", tostring(result))
  end

  -- Success
  if json_mode then
    -- If result is a table, encode it directly; otherwise wrap in result field
    local response
    if type(result) == "table" then
      result.status = "ok"
      response = result
    else
      response = {status = "ok", result = result or ""}
    end
    return json_encode(response) .. "\n\n"
  end

  if result and result ~= "" then
    return string.format("OK\n%s\n\n", tostring(result))
  else
    return "OK\n\n"
  end
end

--- Broadcast an event to all subscribers
-- @param event_type Event type string (e.g., "client_focus", "tag_switch")
-- @param data Table of event data to JSON-encode
function ipc.broadcast(event_type, data)
  if subscriber_count <= 0 or not _ipc_broadcast then return end

  local message = "EVENT " .. event_type .. " " .. json_encode(data or {}) .. "\n"
  _ipc_broadcast(message)
end

--- Remove a subscriber (called when client disconnects or via cleanup)
function ipc.remove_subscriber(client_fd)
  if subscribers[client_fd] then
    subscribers[client_fd] = nil
    subscriber_count = subscriber_count - 1
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

  --- Find a client by numeric ID
  -- @param target The numeric ID to search for (e.g., "1", "42")
  -- @return client_t or nil
  local function find_client_by_id(target)
    local num_id = tonumber(target)
    if not num_id then
      return nil
    end
    for _, c in ipairs(capi.client.get()) do
      if c.id == num_id then
        return c
      end
    end
    return nil
  end

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

  -- Helper: Find tag by name or index on a screen
  local function find_tag(screen, identifier)
    if not screen then return nil end
    local tags = screen.tags or {}

    -- Try as number first
    local idx = tonumber(identifier)
    if idx and idx >= 1 and idx <= #tags then
      return tags[idx], idx
    end

    -- Try as name
    for i, t in ipairs(tags) do
      if t.name == identifier then
        return t, i
      end
    end

    return nil
  end

  --- tag.add <name> [screen] - Create a new tag
  ipc.register("tag.add", function(name, screen_arg)
    if not name then
      error("Usage: tag add <name> [screen]")
    end

    local s
    if screen_arg then
      local screen_idx = tonumber(screen_arg)
      if screen_idx then
        s = capi.screen[screen_idx]
      end
    end
    s = s or awful_screen.focused()

    if not s then
      error("No screen available")
    end

    -- Check if tag with this name already exists
    for _, t in ipairs(s.tags) do
      if t.name == name then
        error("Tag '" .. name .. "' already exists on this screen")
      end
    end

    local new_tag = awful_tag.add(name, {
      screen = s,
      layout = awful_layout.layouts[1] or awful_layout.suit.tile,
    })

    if not new_tag then
      error("Failed to create tag")
    end

    return string.format("Created tag '%s' on screen %d", name, s.index)
  end)

  --- tag.delete <name|index> - Delete a tag
  ipc.register("tag.delete", function(identifier)
    if not identifier then
      error("Usage: tag delete <name|index>")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag, idx = find_tag(s, identifier)
    if not tag then
      error("Tag not found: " .. identifier)
    end

    -- Don't delete the last tag
    if #s.tags <= 1 then
      error("Cannot delete the last tag")
    end

    local name = tag.name
    tag:delete()

    return string.format("Deleted tag '%s' (was index %d)", name, idx)
  end)

  --- tag.rename <old> <new> - Rename a tag
  ipc.register("tag.rename", function(old_name, new_name)
    if not old_name then
      error("Usage: tag rename <old> <new>")
    end
    if not new_name then
      error("Missing new name")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag = find_tag(s, old_name)
    if not tag then
      error("Tag not found: " .. old_name)
    end

    local old = tag.name
    tag.name = new_name

    return string.format("Renamed tag '%s' to '%s'", old, new_name)
  end)

  --- tag.screen <name> [screen] - Get or move tag to screen
  ipc.register("tag.screen", function(identifier, screen_arg)
    if not identifier then
      error("Usage: tag screen <name|index> [screen]")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag = find_tag(s, identifier)
    if not tag then
      error("Tag not found: " .. identifier)
    end

    if screen_arg then
      -- Move to specified screen
      local screen_idx = tonumber(screen_arg)
      local target_screen = screen_idx and capi.screen[screen_idx]
      if not target_screen then
        error("Invalid screen: " .. screen_arg)
      end
      tag.screen = target_screen
      return string.format("Moved tag '%s' to screen %d", tag.name, screen_idx)
    else
      -- Just report current screen
      return string.format("Tag '%s' is on screen %d", tag.name, tag.screen.index)
    end
  end)

  --- tag.swap <tag1> <tag2> - Swap two tags
  ipc.register("tag.swap", function(tag1_id, tag2_id)
    if not tag1_id then
      error("Usage: tag swap <tag1> <tag2>")
    end
    if not tag2_id then
      error("Missing second tag")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag1, idx1 = find_tag(s, tag1_id)
    local tag2, idx2 = find_tag(s, tag2_id)

    if not tag1 then
      error("Tag not found: " .. tag1_id)
    end
    if not tag2 then
      error("Tag not found: " .. tag2_id)
    end

    tag1:swap(tag2)

    return string.format("Swapped tag '%s' (was %d) with '%s' (was %d)",
                        tag1.name, idx1, tag2.name, idx2)
  end)

  --- tag.layout <name|index> [layout] - Get or set tag layout
  ipc.register("tag.layout", function(identifier, layout_name)
    if not identifier then
      error("Usage: tag layout <name|index> [layout]")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag = find_tag(s, identifier)
    if not tag then
      error("Tag not found: " .. identifier)
    end

    if layout_name then
      -- Set layout
      local layouts = tag.layouts or awful_layout.layouts
      for _, l in ipairs(layouts) do
        if l.name == layout_name then
          tag.layout = l
          return string.format("Set tag '%s' layout to %s", tag.name, layout_name)
        end
      end
      -- List available layouts in error
      local available = {}
      for _, l in ipairs(layouts) do
        table.insert(available, l.name)
      end
      error("Unknown layout: " .. layout_name .. " (available: " .. table.concat(available, ", ") .. ")")
    else
      -- Get layout
      local layout = tag.layout
      local layout_name_str = layout and layout.name or "unknown"
      return string.format("Tag '%s' layout: %s", tag.name, layout_name_str)
    end
  end)

  --- tag.gap <name|index> [pixels] - Get or set tag gap
  ipc.register("tag.gap", function(identifier, gap_str)
    if not identifier then
      error("Usage: tag gap <name|index> [pixels]")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag = find_tag(s, identifier)
    if not tag then
      error("Tag not found: " .. identifier)
    end

    if gap_str then
      local gap = tonumber(gap_str)
      if not gap or gap < 0 then
        error("Invalid gap value: " .. gap_str)
      end
      tag.gap = gap
      -- Trigger layout refresh
      awful_layout.arrange(tag.screen)
      return string.format("Set tag '%s' gap to %d", tag.name, gap)
    else
      return string.format("Tag '%s' gap: %d", tag.name, tag.gap or 0)
    end
  end)

  --- tag.mwfact <name|index> [factor] - Get or set master width factor
  ipc.register("tag.mwfact", function(identifier, factor_str)
    if not identifier then
      error("Usage: tag mwfact <name|index> [factor]")
    end

    local s = awful_screen.focused()
    if not s then
      error("No focused screen")
    end

    local tag = find_tag(s, identifier)
    if not tag then
      error("Tag not found: " .. identifier)
    end

    if factor_str then
      local factor = tonumber(factor_str)
      if not factor or factor <= 0 or factor >= 1 then
        error("Invalid factor: " .. factor_str .. " (must be between 0 and 1)")
      end
      tag.master_width_factor = factor
      -- Trigger layout refresh
      awful_layout.arrange(tag.screen)
      return string.format("Set tag '%s' master_width_factor to %.2f", tag.name, factor)
    else
      return string.format("Tag '%s' master_width_factor: %.2f", tag.name, tag.master_width_factor or 0.5)
    end
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
        'id=%d title="%s" class="%s" tags=%s floating=%s',
        c.id,
        title,
        appid,
        table.concat(tag_list, ","),
        tostring(floating)
      )
      table.insert(result, line)
    end

    return table.concat(result, "\n")
  end)

  --- client.kill <ID|focused> [--force] - Kill a client
  ipc.register("client.kill", function(target, flag)
    local force = false
    -- Handle: client kill --force  OR  client kill focused --force  OR  client kill 5 --force
    if target == "--force" then
      force = true
      target = "focused"
    elseif flag == "--force" then
      force = true
    end

    local c = resolve_client(target)

    if force then
      local pid = c.pid
      if not pid or pid <= 0 then
        error("Cannot force-kill: client has no PID")
      end
      capi.awesome.kill(pid, 9) -- SIGKILL
      return string.format("Force-killed client (pid=%d)", pid)
    else
      capi.client.kill(c)
      return string.format("Killed client %s", target)
    end
  end)

  --- client.focus <ID|next|prev|up|down|left|right> - Focus a client
  ipc.register("client.focus", function(target)
    if not target or target == "focused" then
      error("Must specify target: ID, next, prev, up, down, left, or right")
    end

    local direction_labels = { next = "next", prev = "previous" }
    if target == "next" or target == "prev" then
      awful_client.focus.byidx(target == "next" and 1 or -1)
      local c = capi.client.focus
      local label = direction_labels[target]
      return c and string.format("Focused %s client (id=%d)", label, c.id)
                 or string.format("Focused %s client", label)
    elseif target == "up" or target == "down" or target == "left" or target == "right" then
      awful_client.focus.global_bydirection(target)
      local c = capi.client.focus
      return c and string.format("Focused client %s (id=%d)", target, c.id)
                 or string.format("Focused client %s", target)
    else
      -- Find by numeric ID
      local c = find_client_by_id(target)
      if c then
        capi.client.focus = c
        return string.format("Focused client %s", target)
      end
      error("Client not found: " .. target)
    end
  end)

  --- client.close <ID|focused> - Close a client gracefully
  ipc.register("client.close", function(target)
    local c = resolve_client(target)
    capi.client.kill(c)
    return string.format("Closed client %s", target or "focused")
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
      targetclient = find_client_by_id(client_id)
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
      targetclient = find_client_by_id(client_id)
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
      c = find_client_by_id(target)
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
      c = find_client_by_id(target)
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
      c = find_client_by_id(target)
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
      c = find_client_by_id(target)
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
      c = find_client_by_id(target)
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

  -- Helper: resolve target to a client object
  local function resolve_client(target)
    target = target or "focused"
    if target == "focused" then
      local c = capi.client.focus
      if not c then error("No focused client") end
      return c
    end
    local c = find_client_by_id(target)
    if not c then error("Client not found: " .. target) end
    return c
  end

  -- Helper: register a boolean client property command
  local function register_bool_prop(name)
    ipc.register("client." .. name, function(target, value)
      local c = resolve_client(target)

      if not value then
        return tostring(c[name])
      end

      local new_val
      if value == "true" or value == "1" then
        new_val = true
      elseif value == "false" or value == "0" then
        new_val = false
      else
        error("Invalid value. Use 'true' or 'false'")
      end

      c[name] = new_val
      return string.format("Set %s to %s", name, tostring(new_val))
    end)
  end

  register_bool_prop("floating")
  register_bool_prop("fullscreen")
  register_bool_prop("sticky")
  register_bool_prop("ontop")
  register_bool_prop("minimized")
  register_bool_prop("maximized")
  register_bool_prop("maximized_horizontal")
  register_bool_prop("maximized_vertical")
  register_bool_prop("hidden")
  register_bool_prop("modal")
  register_bool_prop("focusable")
  register_bool_prop("urgent")
  register_bool_prop("above")
  register_bool_prop("below")
  register_bool_prop("skip_taskbar")

  --- client.opacity <ID|focused> [value] - Get or set client opacity (0.0-1.0)
  ipc.register("client.opacity", function(target, value)
    local c = resolve_client(target)

    if not value then
      return tostring(c.opacity)
    end

    local new_val = tonumber(value)
    if not new_val or new_val < 0 or new_val > 1 then
      error("Invalid opacity. Must be between 0.0 and 1.0")
    end

    c.opacity = new_val
    return string.format("Set opacity to %.2f", new_val)
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
      c = find_client_by_id(target)
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
      c = find_client_by_id(target)
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
    local c1 = find_client_by_id(id1)
    local c2 = find_client_by_id(id2)

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
      c = find_client_by_id(target)
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
      c = find_client_by_id(target)
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
      table.insert(result, string.format('id=%d title="%s" class="%s"', c.id, title, appid))
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
      table.insert(result, string.format('id=%d title="%s" class="%s"', c.id, title, appid))
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
      'id=%d title="%s" class="%s" x=%d y=%d width=%d height=%d',
      master.id,
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
      c = find_client_by_id(target)
      if not c then
        error("Client not found: " .. target)
      end
    end

    -- Gather comprehensive info
    local geom = c:geometry()

    -- Get tag indices for this client
    local tag_list = {}
    local client_tags = c:tags()
    for _, t in ipairs(client_tags) do
      table.insert(tag_list, t.index)
    end

    local result = {}
    table.insert(result, string.format("ID: %d", c.id))
    table.insert(result, string.format("Title: %s", c.name or ""))
    table.insert(result, string.format("Class: %s", c.class or ""))
    table.insert(result, string.format("Instance: %s", c.instance or ""))
    table.insert(result, string.format("Role: %s", c.role or ""))
    table.insert(result, string.format("Type: %s", c.type or ""))
    table.insert(result, string.format("PID: %s", tostring(c.pid or "")))
    table.insert(result, string.format("Machine: %s", c.machine or ""))
    table.insert(result, string.format("Icon name: %s", c.icon_name or ""))
    table.insert(result, string.format(
      "Geometry: x=%d y=%d width=%d height=%d", geom.x, geom.y, geom.width, geom.height))
    table.insert(result, string.format("Border width: %d", c.border_width or 0))
    table.insert(result, string.format("Screen: %d", c.screen and c.screen.index or 0))
    table.insert(result, string.format("Tags: %s", table.concat(tag_list, ",")))
    table.insert(result, string.format("Floating: %s", tostring(c.floating)))
    table.insert(result, string.format("Fullscreen: %s", tostring(c.fullscreen)))
    table.insert(result, string.format("Maximized: %s", tostring(c.maximized)))
    table.insert(result, string.format("Minimized: %s", tostring(c.minimized)))
    table.insert(result, string.format("Hidden: %s", tostring(c.hidden)))
    table.insert(result, string.format("Sticky: %s", tostring(c.sticky)))
    table.insert(result, string.format("Ontop: %s", tostring(c.ontop)))
    table.insert(result, string.format("Above: %s", tostring(c.above)))
    table.insert(result, string.format("Below: %s", tostring(c.below)))
    table.insert(result, string.format("Urgent: %s", tostring(c.urgent)))
    table.insert(result, string.format("Modal: %s", tostring(c.modal)))
    table.insert(result, string.format("Focusable: %s", tostring(c.focusable)))
    table.insert(result, string.format("Skip taskbar: %s", tostring(c.skip_taskbar)))
    table.insert(result, string.format("Opacity: %.2f", c.opacity or 1.0))

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

    local name = s.name or "Unknown"
    local geom = s.geometry

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

    return string.format(
      'id=%s name="%s" geometry=%dx%d+%d+%d tags=%s layout="%s"',
      format_id(s),
      name,
      geom.width,
      geom.height,
      geom.x,
      geom.y,
      table.concat(activetags, ","),
      layout_name
    )
  end)

  --- screen.count - Get number of screens
  ipc.register("screen.count", function()
    return tostring(capi.screen.count())
  end)

  --- screen.scale [screen] [value] - Get or set screen scale
  --- Examples:
  ---   screen scale           - Get scale of focused screen
  ---   screen scale 1         - Get scale of screen 1
  ---   screen scale 1.5       - Set scale of focused screen to 1.5
  ---   screen scale 1 1.5     - Set scale of screen 1 to 1.5
  ipc.register("screen.scale", function(arg1, arg2)
    local s, scale_value

    -- Parse arguments
    if arg1 and arg2 then
      -- Both provided: arg1 is screen, arg2 is scale
      local screen_idx = tonumber(arg1)
      if not screen_idx then
        error("Invalid screen index: " .. tostring(arg1))
      end
      s = capi.screen[screen_idx]
      if not s then
        error("Screen not found: " .. tostring(arg1))
      end
      scale_value = tonumber(arg2)
      if not scale_value then
        error("Invalid scale value: " .. tostring(arg2))
      end
    elseif arg1 then
      -- One argument: could be screen index or scale value
      local num = tonumber(arg1)
      if not num then
        error("Invalid argument: " .. tostring(arg1))
      end
      -- If it looks like a scale (has decimal or > 5), treat as scale for focused screen
      -- Otherwise treat as screen index
      if num > 5 or (arg1:find("%.") ~= nil) then
        s = awful_screen.focused()
        scale_value = num
      else
        -- Could be screen index or integer scale - check if screen exists
        local potential_screen = capi.screen[math.floor(num)]
        if potential_screen and num == math.floor(num) then
          -- It's a valid screen index, just get its scale
          s = potential_screen
          scale_value = nil
        else
          -- Treat as scale value for focused screen
          s = awful_screen.focused()
          scale_value = num
        end
      end
    else
      -- No arguments: get scale of focused screen
      s = awful_screen.focused()
    end

    if not s then
      error("No screen available")
    end

    if scale_value then
      -- Set scale
      if scale_value < 0.1 or scale_value > 10.0 then
        error("Scale must be between 0.1 and 10.0")
      end
      s.scale = scale_value
      return string.format("Screen %d scale set to %.2f", s.index, s.scale)
    else
      -- Get scale
      return string.format("%.2f", s.scale)
    end
  end)

  --- screen.clients <screen_id> - List clients on a specific screen
  ipc.register("screen.clients", function(screen_id)
    if not screen_id then
      error("Missing screen ID")
    end

    -- Find the screen (try numeric index first, then by format_id)
    local targetscreen = nil
    local num = tonumber(screen_id)
    if num then
      targetscreen = capi.screen[num]
    else
      for s in capi.screen do
        if format_id(s) == screen_id then
          targetscreen = s
          break
        end
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
          string.format('id=%d title="%s" class="%s" floating=%s', c.id, title, appid, tostring(floating))
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
      c = find_client_by_id(target)
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
    tap_3fg_drag = { type = "int", desc = "Enable three-finger drag (0=off, 1=on, -1=default)" },
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

  -- =================================================================
  -- KEYBINDING COMMANDS
  -- =================================================================

  local awful_key = require("awful.key")
  local awful_keyboard = require("awful.keyboard")

  --- Helper to format modifiers table as string
  local function format_modifiers(mods)
    if not mods or #mods == 0 then return "" end
    local sorted = {}
    for _, m in ipairs(mods) do
      table.insert(sorted, m)
    end
    table.sort(sorted)
    return table.concat(sorted, "+")
  end

  --- Helper to parse modifier string like "Mod4+Shift" into table
  local function parse_modifiers(mod_str)
    if not mod_str or mod_str == "" then return {} end
    local mods = {}
    for mod in mod_str:gmatch("[^+,]+") do
      mod = mod:match("^%s*(.-)%s*$")  -- trim whitespace
      if mod ~= "" then
        table.insert(mods, mod)
      end
    end
    return mods
  end

  --- keybind.list [client] - List all keybindings
  ipc.register("keybind.list", function(target)
    local lines = {}

    if target == "client" then
      -- List default client keybindings
      table.insert(lines, "Default client keybindings:")
      local client_keys = awful_keyboard.client_keybindings or {}
      if #client_keys == 0 then
        table.insert(lines, "  (none)")
      else
        for _, k in ipairs(client_keys) do
          local mods = format_modifiers(k.modifiers)
          local key = k.key or "(any)"
          local desc = k.description or ""
          local group = k.group or ""
          table.insert(lines, string.format("  %-20s  %-30s  (%s)",
            mods ~= "" and (mods .. "+" .. key) or key,
            desc,
            group))
        end
      end
    else
      -- List global (root) keybindings
      table.insert(lines, "Global keybindings:")
      local root_keys = capi.root.keys or {}
      if #root_keys == 0 then
        table.insert(lines, "  (none)")
      else
        for _, k in ipairs(root_keys) do
          local mods = format_modifiers(k.modifiers)
          local key = k.key or "(any)"
          local desc = k.description or ""
          local group = k.group or ""
          table.insert(lines, string.format("  %-20s  %-30s  (%s)",
            mods ~= "" and (mods .. "+" .. key) or key,
            desc,
            group))
        end
      end
    end

    return table.concat(lines, "\n")
  end)

  --- keybind.add <modifiers> <key> <command> [description] [group]
  --- Add a global keybinding that spawns a command
  ipc.register("keybind.add", function(mod_str, key, ...)
    if not mod_str then
      error("Usage: keybind add <modifiers> <key> <command> [description] [group]\nExample: keybind add Mod4+Shift t 'kitty' 'spawn terminal' 'launcher'")
    end
    if not key then
      error("Missing key")
    end

    local args = {...}
    if #args == 0 then
      error("Missing command to execute")
    end

    -- Join remaining args as command (in case it has spaces)
    local cmd = args[1]
    local desc = args[2] or ("Run: " .. cmd)
    local group = args[3] or "custom"

    local mods = parse_modifiers(mod_str)

    -- Create the keybinding
    local new_key = awful_key({
      modifiers = mods,
      key = key,
      description = desc,
      group = group,
      on_press = function()
        awful_spawn(cmd)
      end,
    })

    -- Add to global keybindings
    awful_keyboard.append_global_keybinding(new_key)

    local mod_display = #mods > 0 and (table.concat(mods, "+") .. "+") or ""
    return string.format("Added keybinding: %s%s -> %s", mod_display, key, cmd)
  end)

  --- keybind.remove <modifiers> <key> - Remove a global keybinding
  ipc.register("keybind.remove", function(mod_str, key)
    if not mod_str then
      error("Usage: keybind remove <modifiers> <key>")
    end
    if not key then
      error("Missing key")
    end

    local mods = parse_modifiers(mod_str)
    local root_keys = capi.root.keys or {}

    -- Find matching keybinding
    local found = nil
    for _, k in ipairs(root_keys) do
      local k_mods = k.modifiers or {}
      -- Check if modifiers match (order-independent)
      local mods_match = #k_mods == #mods
      if mods_match then
        for _, m in ipairs(mods) do
          local has_mod = false
          for _, km in ipairs(k_mods) do
            if km == m then has_mod = true; break end
          end
          if not has_mod then mods_match = false; break end
        end
      end
      if mods_match and k.key == key then
        found = k
        break
      end
    end

    if not found then
      local mod_display = #mods > 0 and (table.concat(mods, "+") .. "+") or ""
      error("Keybinding not found: " .. mod_display .. key)
    end

    awful_keyboard.remove_global_keybinding(found)

    local mod_display = #mods > 0 and (table.concat(mods, "+") .. "+") or ""
    return string.format("Removed keybinding: %s%s", mod_display, key)
  end)

  --- keybind.trigger <modifiers> <key> - Manually trigger a keybinding
  ipc.register("keybind.trigger", function(mod_str, key)
    if not mod_str then
      error("Usage: keybind trigger <modifiers> <key>")
    end
    if not key then
      error("Missing key")
    end

    local mods = parse_modifiers(mod_str)
    local root_keys = capi.root.keys or {}

    -- Find matching keybinding
    for _, k in ipairs(root_keys) do
      local k_mods = k.modifiers or {}
      local mods_match = #k_mods == #mods
      if mods_match then
        for _, m in ipairs(mods) do
          local has_mod = false
          for _, km in ipairs(k_mods) do
            if km == m then has_mod = true; break end
          end
          if not has_mod then mods_match = false; break end
        end
      end
      if mods_match and k.key == key then
        -- Trigger the keybinding
        if k.on_press then
          k:on_press()
        elseif k.trigger then
          k:trigger()
        else
          error("Keybinding has no action")
        end
        local mod_display = #mods > 0 and (table.concat(mods, "+") .. "+") or ""
        return string.format("Triggered: %s%s", mod_display, key)
      end
    end

    local mod_display = #mods > 0 and (table.concat(mods, "+") .. "+") or ""
    error("Keybinding not found: " .. mod_display .. key)
  end)

  -- =================================================================
  -- SESSION COMMANDS
  -- =================================================================

  --- version - Show compositor version information
  ipc.register("version", function()
    local lines = {}
    table.insert(lines, "somewm " .. (capi.awesome.version or "unknown"))
    if capi.awesome.release then
      table.insert(lines, "Release: " .. capi.awesome.release)
    end
    if capi.awesome.conffile then
      table.insert(lines, "Config: " .. capi.awesome.conffile)
    end
    -- Add API version info if available
    if capi.awesome.api_version then
      table.insert(lines, "API version: " .. capi.awesome.api_version)
    end
    return table.concat(lines, "\n")
  end)

  --- lock - Lock the session
  ipc.register("lock", function()
    local ok = capi.awesome.lock()
    if ok then
      return "Locked"
    else
      error("Lock failed (no lock surface registered or ext-session-lock active)")
    end
  end)

  --- reload - Reload configuration (validates first)
  ipc.register("reload", function()
    local awful_util = require("awful.util")

    -- Get config file path
    local conffile = capi.awesome.conffile
    if not conffile then
      error("No configuration file found")
    end

    -- Validate config first if checkfile is available
    if awful_util.checkfile then
      local result = awful_util.checkfile(conffile)
      if result then
        error("Config validation failed: " .. result)
      end
    end

    -- Restart (which reloads config)
    if capi.awesome.restart then
      capi.awesome.restart()
      return "Reloading..."
    else
      error("Reload not supported")
    end
  end)

  --- restart - Full compositor restart
  ipc.register("restart", function()
    if capi.awesome.restart then
      capi.awesome.restart()
      return "Restarting..."
    else
      error("Restart not supported")
    end
  end)

  -- =================================================================
  -- RULES COMMANDS
  -- =================================================================

  local ruled_client_ok, ruled_client = pcall(require, "ruled.client")

  if ruled_client_ok then
    --- rule.list - List all client rules
    ipc.register("rule.list", function()
      local rules = ruled_client.rules or {}
      if #rules == 0 then
        return "No rules defined"
      end

      local lines = {}
      for i, rule in ipairs(rules) do
        local id = rule.id or tostring(i)
        local rule_match = rule.rule or {}
        local rule_any = rule.rule_any or {}

        -- Build match description
        local match_parts = {}
        if rule_match.class then
          table.insert(match_parts, "class=" .. tostring(rule_match.class))
        end
        if rule_match.instance then
          table.insert(match_parts, "instance=" .. tostring(rule_match.instance))
        end
        if rule_match.name then
          table.insert(match_parts, "name=" .. tostring(rule_match.name))
        end
        if rule_match.role then
          table.insert(match_parts, "role=" .. tostring(rule_match.role))
        end
        if rule_match.type then
          table.insert(match_parts, "type=" .. tostring(rule_match.type))
        end

        -- Add rule_any matches
        for k, v in pairs(rule_any) do
          if type(v) == "table" then
            table.insert(match_parts, k .. "={" .. table.concat(v, ",") .. "}")
          else
            table.insert(match_parts, k .. "=" .. tostring(v))
          end
        end

        local match_str = #match_parts > 0 and table.concat(match_parts, ", ") or "(all)"

        -- Build properties description
        local props = rule.properties or {}
        local prop_parts = {}
        for k, v in pairs(props) do
          if type(v) == "boolean" then
            table.insert(prop_parts, k .. "=" .. (v and "true" or "false"))
          elseif type(v) == "number" then
            table.insert(prop_parts, k .. "=" .. tostring(v))
          elseif type(v) == "string" then
            table.insert(prop_parts, k .. "=\"" .. v .. "\"")
          else
            table.insert(prop_parts, k .. "=<" .. type(v) .. ">")
          end
        end
        local props_str = #prop_parts > 0 and table.concat(prop_parts, ", ") or "(no props)"

        table.insert(lines, string.format("[%s] match: %s", id, match_str))
        table.insert(lines, string.format("     props: %s", props_str))
      end

      return table.concat(lines, "\n")
    end)

    --- rule.add <json> - Add a new rule from JSON
    ipc.register("rule.add", function(...)
      local args = {...}
      if #args == 0 then
        error("Usage: rule add <json>")
      end

      -- Join all args (JSON might have spaces)
      local json_str = table.concat(args, " ")

      -- Simple JSON parser (basic subset)
      local function parse_json(str)
        -- Try to use cjson if available
        local cjson_ok, cjson = pcall(require, "cjson")
        if cjson_ok then
          return cjson.decode(str)
        end

        -- Fallback: use Lua's load to parse JSON-like Lua table
        -- Replace JSON syntax with Lua syntax
        str = str:gsub(':%s*"', ' = "')
        str = str:gsub(':%s*(%d)', ' = %1')
        str = str:gsub(':%s*true', ' = true')
        str = str:gsub(':%s*false', ' = false')
        str = str:gsub(':%s*null', ' = nil')
        str = str:gsub(':%s*%[', ' = {')
        str = str:gsub(':%s*{', ' = {')
        str = str:gsub('%[', '{')
        str = str:gsub('%]', '}')

        local fn, err = load("return " .. str)
        if not fn then
          error("Invalid JSON: " .. (err or "parse error"))
        end
        return fn()
      end

      local ok, rule = pcall(parse_json, json_str)
      if not ok then
        error("Failed to parse rule: " .. tostring(rule))
      end

      -- Generate ID if not provided
      if not rule.id then
        rule.id = "ipc_rule_" .. os.time()
      end

      ruled_client.append_rule(rule)
      return "Added rule: " .. rule.id
    end)

    --- rule.remove <id> - Remove a rule by ID
    ipc.register("rule.remove", function(rule_id)
      if not rule_id then
        error("Usage: rule remove <id>")
      end

      local rules = ruled_client.rules or {}
      local found = false

      for i, rule in ipairs(rules) do
        if (rule.id and rule.id == rule_id) or tostring(i) == rule_id then
          table.remove(rules, i)
          found = true
          break
        end
      end

      if not found then
        error("Rule not found: " .. rule_id)
      end

      return "Removed rule: " .. rule_id
    end)

    --- rule.test <client_id> - Show which rules match a client
    ipc.register("rule.test", function(client_id)
      if not client_id then
        error("Usage: rule test <client_id|focused>")
      end

      local c
      if client_id == "focused" then
        c = capi.client.focus
      else
        c = find_client_by_id(client_id)
      end

      if not c then
        error("Client not found: " .. client_id)
      end

      local rules = ruled_client.rules or {}
      local matching = {}

      -- Test each rule against the client
      for i, rule in ipairs(rules) do
        local matches = true
        local rule_match = rule.rule or {}

        -- Check each match criterion
        for k, v in pairs(rule_match) do
          local client_val = c[k]
          if type(v) == "string" then
            if type(client_val) ~= "string" or not client_val:match(v) then
              matches = false
              break
            end
          elseif client_val ~= v then
            matches = false
            break
          end
        end

        if matches then
          local id = rule.id or tostring(i)
          table.insert(matching, id)
        end
      end

      if #matching == 0 then
        return "No rules match this client"
      end

      return "Matching rules: " .. table.concat(matching, ", ")
    end)
  end

  -- =================================================================
  -- WIBAR COMMANDS
  -- =================================================================

  --- Helper to collect all wibars from screens
  local function get_all_wibars()
    local wibars = {}
    for s in capi.screen do
      if s.mywibox then
        table.insert(wibars, {screen = s.index, wibar = s.mywibox})
      end
    end
    return wibars
  end

  --- wibar.list - List all wibars
  ipc.register("wibar.list", function()
    local wibars = get_all_wibars()
    if #wibars == 0 then
      return "No wibars found"
    end

    local lines = {}
    for _, wb in ipairs(wibars) do
      local status = wb.wibar.visible and "visible" or "hidden"
      local pos = wb.wibar.position or "top"
      table.insert(lines, string.format("Screen %d: %s (%s)", wb.screen, status, pos))
    end
    return table.concat(lines, "\n")
  end)

  --- wibar.show <screen|all> - Show wibar(s)
  ipc.register("wibar.show", function(target)
    if not target then
      error("Usage: wibar show <screen|all>")
    end

    if target == "all" then
      local wibars = get_all_wibars()
      local count = 0
      for _, wb in ipairs(wibars) do
        wb.wibar.visible = true
        count = count + 1
      end
      return string.format("Showed %d wibar(s)", count)
    else
      local screen_idx = tonumber(target)
      if not screen_idx then
        error("Invalid screen: " .. target)
      end
      local s = capi.screen[screen_idx]
      if not s then
        error("Screen not found: " .. target)
      end
      if not s.mywibox then
        error("No wibar on screen " .. target)
      end
      s.mywibox.visible = true
      return "Showed wibar on screen " .. target
    end
  end)

  --- wibar.hide <screen|all> - Hide wibar(s)
  ipc.register("wibar.hide", function(target)
    if not target then
      error("Usage: wibar hide <screen|all>")
    end

    if target == "all" then
      local wibars = get_all_wibars()
      local count = 0
      for _, wb in ipairs(wibars) do
        wb.wibar.visible = false
        count = count + 1
      end
      return string.format("Hid %d wibar(s)", count)
    else
      local screen_idx = tonumber(target)
      if not screen_idx then
        error("Invalid screen: " .. target)
      end
      local s = capi.screen[screen_idx]
      if not s then
        error("Screen not found: " .. target)
      end
      if not s.mywibox then
        error("No wibar on screen " .. target)
      end
      s.mywibox.visible = false
      return "Hid wibar on screen " .. target
    end
  end)

  --- wibar.toggle <screen|all> - Toggle wibar(s)
  ipc.register("wibar.toggle", function(target)
    if not target then
      error("Usage: wibar toggle <screen|all>")
    end

    if target == "all" then
      local wibars = get_all_wibars()
      local count = 0
      for _, wb in ipairs(wibars) do
        wb.wibar.visible = not wb.wibar.visible
        count = count + 1
      end
      return string.format("Toggled %d wibar(s)", count)
    else
      local screen_idx = tonumber(target)
      if not screen_idx then
        error("Invalid screen: " .. target)
      end
      local s = capi.screen[screen_idx]
      if not s then
        error("Screen not found: " .. target)
      end
      if not s.mywibox then
        error("No wibar on screen " .. target)
      end
      s.mywibox.visible = not s.mywibox.visible
      local status = s.mywibox.visible and "shown" or "hidden"
      return "Wibar on screen " .. target .. " is now " .. status
    end
  end)

  -- =================================================================
  -- MULTI-MONITOR COMMANDS
  -- =================================================================

  --- screen.focus <id|next|prev> - Focus a screen
  ipc.register("screen.focus", function(target)
    if not target then
      error("Usage: screen focus <id|next|prev>")
    end

    local s
    if target == "next" then
      awful_screen.focus_relative(1)
      s = awful_screen.focused()
    elseif target == "prev" then
      awful_screen.focus_relative(-1)
      s = awful_screen.focused()
    else
      local screen_idx = tonumber(target)
      if not screen_idx then
        error("Invalid screen: " .. target)
      end
      s = capi.screen[screen_idx]
      if not s then
        error("Screen not found: " .. target)
      end
      awful_screen.focus(s)
    end

    return "Focused screen " .. s.index
  end)

  --- client.movetoscreen <screen> [client_id] - Move client to screen
  ipc.register("client.movetoscreen", function(screen_arg, client_id)
    if not screen_arg then
      error("Usage: client movetoscreen <screen> [client_id]")
    end

    -- Get client
    local c
    if not client_id or client_id == "focused" then
      c = capi.client.focus
    else
      c = find_client_by_id(client_id)
    end

    if not c then
      error("No client found")
    end

    -- Get target screen
    local target_screen
    if screen_arg == "next" then
      local current_idx = c.screen.index
      local next_idx = current_idx % capi.screen.count() + 1
      target_screen = capi.screen[next_idx]
    elseif screen_arg == "prev" then
      local current_idx = c.screen.index
      local prev_idx = (current_idx - 2) % capi.screen.count() + 1
      target_screen = capi.screen[prev_idx]
    else
      local screen_idx = tonumber(screen_arg)
      if screen_idx then
        target_screen = capi.screen[screen_idx]
      end
    end

    if not target_screen then
      error("Invalid screen: " .. screen_arg)
    end

    c:move_to_screen(target_screen)
    return string.format("Moved client to screen %d", target_screen.index)
  end)

  -- =================================================================
  -- NOTIFICATION COMMANDS
  -- =================================================================

  local naughty_ok, naughty = pcall(require, "naughty")

  if naughty_ok then
    --- notify <message> [options...] - Send a notification
    -- Options: --title <text>, --timeout <seconds>, --urgency <low|normal|critical>
    ipc.register("notify", function(...)
      local args = {...}
      if #args == 0 then
        error("Usage: notify <message> [--title T] [--timeout N] [--urgency U]")
      end

      -- Parse arguments
      local message_parts = {}
      local title = nil
      local timeout = 5
      local urgency = "normal"

      local i = 1
      while i <= #args do
        local arg = args[i]
        if arg == "--title" and args[i + 1] then
          title = args[i + 1]
          i = i + 2
        elseif arg == "--timeout" and args[i + 1] then
          timeout = tonumber(args[i + 1]) or 5
          i = i + 2
        elseif arg == "--urgency" and args[i + 1] then
          urgency = args[i + 1]
          i = i + 2
        else
          table.insert(message_parts, arg)
          i = i + 1
        end
      end

      local message = table.concat(message_parts, " ")
      if message == "" then
        error("Message cannot be empty")
      end

      -- Map urgency string to naughty preset
      local preset = naughty.config.presets.normal
      if urgency == "low" then
        preset = naughty.config.presets.low
      elseif urgency == "critical" then
        preset = naughty.config.presets.critical
      end

      naughty.notify({
        title = title,
        text = message,
        timeout = timeout,
        preset = preset,
      })

      return "Notification sent"
    end)
  end

  -- =================================================================
  -- MOUSE COMMANDS
  -- =================================================================

  --- mouse.coords [x y] - Get or set mouse cursor position
  ipc.register("mouse.coords", function(x, y)
    if not x then
      -- Get current position
      local coords = capi.mouse.coords()
      return string.format("x=%d y=%d", coords.x, coords.y)
    end

    x = tonumber(x)
    y = tonumber(y)
    if not x or not y then
      error("Invalid coordinates. Usage: mouse coords <x> <y>")
    end

    capi.mouse.coords({ x = x, y = y })
    return string.format("Moved cursor to x=%d y=%d", x, y)
  end)

  --- mouse.screen - Get screen under mouse cursor
  ipc.register("mouse.screen", function()
    local coords = capi.mouse.coords()
    -- Find which screen contains the cursor
    for i = 1, capi.screen.count() do
      local s = capi.screen[i]
      local geom = s.geometry
      if coords.x >= geom.x and coords.x < geom.x + geom.width
         and coords.y >= geom.y and coords.y < geom.y + geom.height then
        return string.format("Screen %d", s.index)
      end
    end
    -- Fallback to focused screen
    local s = awful_screen.focused()
    return string.format("Screen %d", s and s.index or 0)
  end)

  -- =================================================================
  -- PLACEMENT COMMANDS
  -- =================================================================

  --- client.placement <func> [ID|focused] - Apply placement function to client
  ipc.register("client.placement", function(func_name, target)
    if not func_name then
      local available = {
        "no_offscreen", "no_overlap", "under_mouse", "next_to_mouse",
        "maximize", "stretch", "centered", "top_left", "top_right",
        "bottom_left", "bottom_right",
      }
      error("Usage: client placement <func> [ID|focused]\nAvailable: " .. table.concat(available, ", "))
    end

    local c = resolve_client(target)

    local func = awful_placement[func_name]
    if not func then
      error("Unknown placement function: " .. func_name)
    end

    func(c)
    return string.format("Applied placement '%s'", func_name)
  end)

  -- =================================================================
  -- OUTPUT/DISPLAY COMMANDS
  -- =================================================================

  --- output.list - List all outputs
  ipc.register("output.list", function()
    local outputs = capi.screen.outputs and capi.screen.outputs() or nil
    if outputs then
      if #outputs == 0 then return "No outputs" end
      local lines = {}
      for _, o in ipairs(outputs) do
        table.insert(lines, string.format("name=%s enabled=%s", o.name or "?", tostring(o.enabled ~= false)))
      end
      return table.concat(lines, "\n")
    end

    -- Fallback: list screens as outputs
    local lines = {}
    for i = 1, capi.screen.count() do
      local s = capi.screen[i]
      local geom = s.geometry
      local name = s.name or ("Screen " .. i)
      table.insert(lines, string.format(
        'name="%s" geometry=%dx%d+%d+%d scale=%.2f',
        name, geom.width, geom.height, geom.x, geom.y, s.scale or 1.0))
    end
    if #lines == 0 then return "No outputs" end
    return table.concat(lines, "\n")
  end)

  -- =================================================================
  -- DPMS AND IDLE COMMANDS
  -- =================================================================

  --- dpms <on|off|status> - Control display power management
  ipc.register("dpms", function(action)
    if not action or action == "status" then
      return "DPMS status: use 'dpms on' or 'dpms off' to control displays"
    elseif action == "off" then
      if capi.awesome.dpms_off then
        capi.awesome.dpms_off()
        return "Displays turned off"
      else
        error("DPMS not supported")
      end
    elseif action == "on" then
      if capi.awesome.dpms_on then
        capi.awesome.dpms_on()
        return "Displays turned on"
      else
        error("DPMS not supported")
      end
    else
      error("Usage: dpms <on|off|status>")
    end
  end)

  --- idle <timeout|status|clear> - Manage idle timeouts
  ipc.register("idle", function(action, ...)
    local args = {...}

    if not action or action == "status" then
      if capi.awesome.idle_timeouts then
        local timeouts = capi.awesome.idle_timeouts
        if type(timeouts) == "table" then
          if next(timeouts) == nil then
            return "No active idle timeouts"
          end
          local lines = {}
          for name, info in pairs(timeouts) do
            if type(info) == "table" then
              table.insert(lines, string.format("%s: %ds", name, info.timeout or 0))
            else
              table.insert(lines, string.format("%s: %s", name, tostring(info)))
            end
          end
          return table.concat(lines, "\n")
        end
      end
      return "No idle timeout info available"
    elseif action == "timeout" then
      local name = args[1]
      local seconds = tonumber(args[2])
      if not name or not seconds then
        error("Usage: idle timeout <name> <seconds>")
      end
      if capi.awesome.set_idle_timeout then
        capi.awesome.set_idle_timeout(name, seconds, function()
          -- Default action: turn off displays
          if capi.awesome.dpms_off then
            capi.awesome.dpms_off()
          end
        end)
        return string.format("Set idle timeout '%s' to %ds", name, seconds)
      else
        error("Idle timeout not supported")
      end
    elseif action == "clear" then
      local name = args[1]
      if name then
        if capi.awesome.clear_idle_timeout then
          capi.awesome.clear_idle_timeout(name)
          return string.format("Cleared idle timeout '%s'", name)
        end
      else
        if capi.awesome.clear_all_idle_timeouts then
          capi.awesome.clear_all_idle_timeouts()
          return "Cleared all idle timeouts"
        end
      end
      error("Clear idle timeout not supported")
    else
      error("Usage: idle <timeout|status|clear>")
    end
  end)

  -- =================================================================
  -- THEME COMMANDS
  -- =================================================================

  --- theme.get [key] - Get theme values
  ipc.register("theme.get", function(key)
    local beautiful = require("beautiful")
    local theme = beautiful.get()

    if not theme then
      error("No theme loaded")
    end

    if key then
      local val = theme[key]
      if val == nil then
        error("Theme key not found: " .. key)
      end
      return tostring(val)
    end

    -- List all theme keys and values
    local lines = {}
    local keys = {}
    for k in pairs(theme) do
      table.insert(keys, k)
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
      local v = theme[k]
      local vtype = type(v)
      if vtype == "string" or vtype == "number" or vtype == "boolean" then
        table.insert(lines, string.format("%s = %s", k, tostring(v)))
      else
        table.insert(lines, string.format("%s = <%s>", k, vtype))
      end
    end

    if #lines == 0 then return "Theme is empty" end
    return table.concat(lines, "\n")
  end)

  --- theme.set <key> <value> - Set a theme value
  ipc.register("theme.set", function(key, ...)
    if not key then
      error("Usage: theme set <key> <value>")
    end

    local args = {...}
    if #args == 0 then
      error("Missing value")
    end

    local value = table.concat(args, " ")
    local beautiful = require("beautiful")
    local theme = beautiful.get()

    if not theme then
      error("No theme loaded")
    end

    -- Try to convert to number if it looks like one
    local num = tonumber(value)
    if num then
      value = num
    elseif value == "true" then
      value = true
    elseif value == "false" then
      value = false
    end

    theme[key] = value
    beautiful[key] = value
    return string.format("Set theme.%s = %s", key, tostring(value))
  end)

  -- =================================================================
  -- TITLEBAR COMMANDS
  -- =================================================================

  local awful_titlebar = require("awful.titlebar")

  -- Helper: resolve client and position for titlebar commands
  -- Handles: titlebar show [ID] [position]  or  titlebar show [position]
  local function resolve_titlebar_args(target, position)
    target = target or "focused"
    if target == "top" or target == "bottom" or target == "left" or target == "right" then
      position = target
      target = "focused"
    end
    return resolve_client(target), position
  end

  local titlebar_actions = {
    { name = "show",   func = awful_titlebar.show,   past = "Showed" },
    { name = "hide",   func = awful_titlebar.hide,   past = "Hid" },
    { name = "toggle", func = awful_titlebar.toggle,  past = "Toggled" },
  }
  for _, action in ipairs(titlebar_actions) do
    ipc.register("titlebar." .. action.name, function(target, position)
      local c, pos = resolve_titlebar_args(target, position)
      action.func(c, pos)
      return string.format("%s titlebar%s", action.past, pos and (" (" .. pos .. ")") or "")
    end)
  end

  -- =================================================================
  -- WALLPAPER COMMANDS
  -- =================================================================

  --- wallpaper.set <path> [screen] - Set wallpaper from image file
  ipc.register("wallpaper.set", function(path, screen_arg)
    if not path then
      error("Usage: wallpaper set <path> [screen]")
    end

    local s
    if screen_arg then
      local idx = tonumber(screen_arg)
      if idx then s = capi.screen[idx] end
    end
    s = s or awful_screen.focused()

    if not s then error("No screen available") end

    local gears_wallpaper = require("gears.wallpaper")
    gears_wallpaper.maximized(path, s, false)
    return string.format("Set wallpaper to %s on screen %d", path, s.index)
  end)

  --- wallpaper.color <hex> [screen] - Set wallpaper to solid color
  ipc.register("wallpaper.color", function(color, screen_arg)
    if not color then
      error("Usage: wallpaper color <hex> [screen]")
    end

    local s
    if screen_arg then
      local idx = tonumber(screen_arg)
      if idx then s = capi.screen[idx] end
    end
    s = s or awful_screen.focused()

    if not s then error("No screen available") end

    local gears_wallpaper = require("gears.wallpaper")
    gears_wallpaper.set(require("gears.color")(color))
    return string.format("Set wallpaper color to %s", color)
  end)

  -- =================================================================
  -- COMMANDS LIST (for shell completions)
  -- =================================================================

  --- commands - List all registered command names
  ipc.register("commands", function()
    local names = {}
    for name in pairs(commands) do
      table.insert(names, name)
    end
    table.sort(names)
    return table.concat(names, "\n")
  end)
end

-- Initialize built-in commands
register_builtin_commands()

-- Register global dispatcher function (called from C)
function _G._ipc_dispatch(command_string, client_fd)
  return ipc.dispatch(command_string, client_fd)
end

-- =================================================================
-- EVENT SUBSCRIPTION SIGNAL HOOKS
-- =================================================================
-- Connect to AwesomeWM signals and broadcast events to subscribers.
-- These run after ipc module is loaded, so all APIs are available.

local function setup_event_hooks()
  local capi = {
    client = client,
    screen = screen,
    tag = tag,
    awesome = awesome,
  }

  -- Client managed (new window appeared)
  if capi.client and capi.client.connect_signal then
    capi.client.connect_signal("manage", function(c)
      ipc.broadcast("client_manage", {
        id = c.id,
        title = c.name or "",
        class = c.class or "",
        pid = c.pid,
      })
    end)

    -- Client unmanaged (window closed)
    capi.client.connect_signal("unmanage", function(c)
      ipc.broadcast("client_unmanage", {
        id = c.id,
        title = c.name or "",
        class = c.class or "",
      })
    end)

    -- Client focused
    capi.client.connect_signal("focus", function(c)
      ipc.broadcast("client_focus", {
        id = c.id,
        title = c.name or "",
        class = c.class or "",
      })
    end)

    -- Client unfocused
    capi.client.connect_signal("unfocus", function(c)
      ipc.broadcast("client_unfocus", {
        id = c.id,
        title = c.name or "",
        class = c.class or "",
      })
    end)

    -- Client property changes
    capi.client.connect_signal("property::name", function(c)
      ipc.broadcast("client_title", {
        id = c.id,
        title = c.name or "",
      })
    end)

    capi.client.connect_signal("property::urgent", function(c)
      ipc.broadcast("client_urgent", {
        id = c.id,
        urgent = c.urgent,
        title = c.name or "",
        class = c.class or "",
      })
    end)

    capi.client.connect_signal("property::fullscreen", function(c)
      ipc.broadcast("client_fullscreen", {
        id = c.id,
        fullscreen = c.fullscreen,
      })
    end)

    capi.client.connect_signal("property::floating", function(c)
      ipc.broadcast("client_floating", {
        id = c.id,
        floating = c.floating,
      })
    end)

    capi.client.connect_signal("property::minimized", function(c)
      ipc.broadcast("client_minimized", {
        id = c.id,
        minimized = c.minimized,
      })
    end)
  end

  -- Tag signals
  if capi.tag and capi.tag.connect_signal then
    capi.tag.connect_signal("property::selected", function(t)
      ipc.broadcast("tag_switch", {
        index = t.index,
        name = t.name or "",
        selected = t.selected,
        screen = t.screen and t.screen.index or 0,
      })
    end)
  end

  -- Screen signals
  if capi.screen and capi.screen.connect_signal then
    capi.screen.connect_signal("added", function(s)
      ipc.broadcast("screen_add", {
        index = s.index,
        name = s.name or "",
      })
    end)

    capi.screen.connect_signal("removed", function(s)
      ipc.broadcast("screen_remove", {
        index = s.index,
        name = s.name or "",
      })
    end)
  end
end

-- Set up hooks (safe to call even if signals aren't available yet)
pcall(setup_event_hooks)

return ipc
