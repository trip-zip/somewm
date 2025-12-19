---------------------------------------------------------------------------
--- Test client helper for somewm integration tests.
--
-- This module provides a Wayland-compatible way to spawn test clients,
-- similar to AwesomeWM's _client.lua but using native Wayland terminals.
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
-- @module _client
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")

local module = {}

-- Track spawned test client PIDs for cleanup
local spawned_pids = {}

-- Detect which terminal is available for spawning test clients
local terminal_cmd = nil
local terminal_detected = false

local function detect_terminal()
    if terminal_detected then
        return terminal_cmd ~= nil
    end
    terminal_detected = true

    -- Try terminals in order of preference
    -- Each entry: { executable, class_flag, exec_flag }
    -- Note: kitty is preferred because it has reliable --class support in headless mode
    -- ghostty's --class flag has issues in headless/GPU-less environments
    local terminals = {
        { "kitty", "--class=%s", "-e" },
        { "foot", "--app-id=%s", "-e" },
        { "alacritty", "--class=%s", "-e" },
        { "ghostty", "--class=%s", "-e" },  -- ghostty last due to headless issues
    }

    for _, t in ipairs(terminals) do
        local exe, class_flag, exec_flag = t[1], t[2], t[3]
        -- Check if terminal exists
        local handle = io.popen("which " .. exe .. " 2>/dev/null")
        if handle then
            local result = handle:read("*a")
            handle:close()
            if result and result:match(exe) then
                terminal_cmd = { exe, class_flag, exec_flag }
                return true
            end
        end
    end

    io.stderr:write("WARNING: No suitable terminal found for test clients\n")
    io.stderr:write("  Tried: ghostty, kitty, foot, alacritty\n")
    return false
end

--- Spawn a test client with the given class/app_id.
-- @tparam[opt="test_client"] string class The app_id/class for the client
-- @tparam[opt="Test Client"] string title The window title (note: may not be honored by all terminals)
-- @tparam[opt] table sn_rules Startup notification rules (for compatibility, currently unused)
-- @tparam[opt] function callback Callback when client appears (for compatibility, currently unused)
-- @treturn number|nil The PID of the spawned process, or nil on failure
local function spawn_client(_, class, title, sn_rules, callback)
    class = class or "test_client"
    title = title or "Test Client"

    if not detect_terminal() then
        io.stderr:write("ERROR: Cannot spawn test client - no terminal available\n")
        return nil
    end

    local exe, class_flag, exec_flag = terminal_cmd[1], terminal_cmd[2], terminal_cmd[3]

    -- Build command
    local cmd = string.format(
        "%s %s %s sleep infinity",
        exe,
        string.format(class_flag, class),
        exec_flag
    )

    -- Spawn the client
    local pid = awful.spawn(cmd)

    if pid and type(pid) == "number" and pid > 0 then
        table.insert(spawned_pids, pid)
        return pid
    else
        io.stderr:write("ERROR: Failed to spawn test client: " .. tostring(pid) .. "\n")
        return nil
    end
end

--- Terminate all spawned test clients.
-- This should be called at the end of tests to clean up.
function module.terminate()
    for _, pid in ipairs(spawned_pids) do
        -- Try graceful kill first, then force kill
        os.execute("kill " .. pid .. " 2>/dev/null")
    end

    -- Also kill any remaining clients via the compositor
    for _, c in ipairs(client.get()) do
        c:kill()
    end

    spawned_pids = {}
end

--- Get the list of spawned PIDs.
-- @treturn table List of PIDs for spawned test clients
function module.get_spawned_pids()
    return gears.table.clone(spawned_pids)
end

--- Check if a terminal is available for spawning.
-- @treturn boolean True if a terminal was detected
function module.is_available()
    return detect_terminal()
end

--- Get the detected terminal command info.
-- @treturn table|nil Table with {exe, class_flag, exec_flag} or nil
function module.get_terminal_info()
    if detect_terminal() then
        return {
            executable = terminal_cmd[1],
            class_flag = terminal_cmd[2],
            exec_flag = terminal_cmd[3],
        }
    end
    return nil
end

-- Make the module callable for spawning clients
-- Usage: test_client("myapp", "My Window")
return setmetatable(module, { __call = spawn_client })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
