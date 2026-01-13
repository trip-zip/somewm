---------------------------------------------------------------------------
--- X11/XWayland test client helper for somewm integration tests.
--
-- This module provides a way to spawn X11 applications for testing XWayland
-- support. It mirrors the _client.lua API but spawns X11 apps via XWayland.
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
-- @module _x11_client
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")

local module = {}

-- Track spawned test client PIDs for cleanup
local spawned_pids = {}

-- Detect which X11 terminal/app is available for spawning test clients
local x11_app_cmd = nil
local x11_detected = false

local function detect_x11_app()
    if x11_detected then
        return x11_app_cmd ~= nil
    end
    x11_detected = true

    -- Try X11 terminals/apps in order of preference
    -- Each entry: { executable, class_flag, exec_flag, default_class }
    -- xterm is preferred because it's widely available and has reliable -class
    local apps = {
        -- xterm: -class sets WM_CLASS resource class, -name sets instance
        { "xterm", "-class", "-e", "XTerm" },
        -- xeyes: simple X11 app, good for visual tests (no exec flag)
        { "xeyes", nil, nil, "XEyes" },
        -- xclock: another simple X11 app
        { "xclock", nil, nil, "XClock" },
    }

    for _, app in ipairs(apps) do
        local exe = app[1]
        local handle = io.popen("which " .. exe .. " 2>/dev/null")
        if handle then
            local result = handle:read("*a")
            handle:close()
            if result and result:match(exe) then
                x11_app_cmd = app
                return true
            end
        end
    end

    io.stderr:write("WARNING: No X11 application found for XWayland tests\n")
    io.stderr:write("  Tried: xterm, xeyes, xclock\n")
    io.stderr:write("  Install one of these to run XWayland tests\n")
    return false
end

--- Spawn an X11 test client with the given class.
-- @tparam[opt="xwayland_test"] string class The WM_CLASS for the client
-- @tparam[opt] string title The window title (may not be honored by all apps)
-- @treturn number|nil The PID of the spawned process, or nil on failure
local function spawn_x11_client(_, class, title)
    class = class or "xwayland_test"

    if not detect_x11_app() then
        io.stderr:write("ERROR: Cannot spawn X11 test client - no X11 app available\n")
        return nil
    end

    local exe = x11_app_cmd[1]
    local class_flag = x11_app_cmd[2]
    local exec_flag = x11_app_cmd[3]

    -- Build command based on what app we're using
    local cmd
    if exe == "xterm" then
        -- xterm: -class CLASS -name INSTANCE -T TITLE -e CMD
        cmd = string.format(
            "xterm -class %s -name %s -T '%s' -e 'sleep infinity'",
            class, class:lower(), title or class
        )
    elseif exe == "xeyes" or exe == "xclock" then
        -- These simple apps don't support class override easily,
        -- but we can still spawn them for basic XWayland testing
        cmd = exe
        io.stderr:write(string.format(
            "WARNING: %s doesn't support custom WM_CLASS, using default\n", exe
        ))
    else
        -- Generic fallback
        if class_flag then
            cmd = string.format("%s %s %s", exe, class_flag, class)
        else
            cmd = exe
        end
    end

    io.stderr:write(string.format("[X11] Spawning: %s\n", cmd))

    -- Spawn the client
    local pid = awful.spawn(cmd)

    if pid and type(pid) == "number" and pid > 0 then
        table.insert(spawned_pids, pid)
        return pid
    else
        io.stderr:write("ERROR: Failed to spawn X11 test client: " .. tostring(pid) .. "\n")
        return nil
    end
end

--- Terminate all spawned X11 test clients.
-- This should be called at the end of tests to clean up.
function module.terminate()
    for _, pid in ipairs(spawned_pids) do
        os.execute("kill " .. pid .. " 2>/dev/null")
    end
    spawned_pids = {}
end

--- Get the list of spawned PIDs.
-- @treturn table List of PIDs for spawned X11 test clients
function module.get_spawned_pids()
    return gears.table.clone(spawned_pids)
end

--- Check if an X11 application is available for spawning.
-- @treturn boolean True if an X11 app was detected
function module.is_available()
    return detect_x11_app()
end

--- Get info about the detected X11 application.
-- @treturn table|nil Table with app info or nil
function module.get_app_info()
    if detect_x11_app() then
        return {
            executable = x11_app_cmd[1],
            class_flag = x11_app_cmd[2],
            exec_flag = x11_app_cmd[3],
            default_class = x11_app_cmd[4],
        }
    end
    return nil
end

--- Get the default WM_CLASS for spawned X11 clients.
-- This is useful when the app doesn't support custom class names.
-- @treturn string|nil The default class name
function module.get_default_class()
    if detect_x11_app() then
        -- For xterm with custom class, return what we'll set
        if x11_app_cmd[1] == "xterm" then
            return nil -- We set custom class
        end
        return x11_app_cmd[4]
    end
    return nil
end

--- Check if a client is an XWayland client.
-- @tparam client c The client to check
-- @treturn boolean True if client is XWayland
function module.is_xwayland(c)
    -- XWayland clients have a window ID (X11 window)
    -- Native Wayland clients don't
    return c and c.window and c.window > 0
end

--- Find X11 clients by class.
-- @tparam string class The WM_CLASS to search for
-- @treturn table List of matching X11 clients
function module.find_by_class(class)
    local results = {}
    for _, c in ipairs(client.get()) do
        if c.class == class and module.is_xwayland(c) then
            table.insert(results, c)
        end
    end
    return results
end

-- Make the module callable for spawning clients
-- Usage: x11_client("MyXApp", "Window Title")
return setmetatable(module, { __call = spawn_x11_client })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
