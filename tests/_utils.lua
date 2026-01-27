---------------------------------------------------------------------------
--- Test utility functions for somewm integration tests.
--
-- This module provides common helper functions used across integration tests,
-- such as waiting for clients, finding clients by properties, etc.
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
-- @module _utils
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")

local utils = {}

--- Find a client by its class/app_id.
-- @tparam string class The class/app_id to search for
-- @treturn client|nil The matching client or nil if not found
function utils.find_client_by_class(class)
    for _, c in ipairs(client.get()) do
        if c.class == class then
            return c
        end
    end
    return nil
end

--- Find a client by its title/name.
-- @tparam string title The title to search for (exact match)
-- @treturn client|nil The matching client or nil if not found
function utils.find_client_by_title(title)
    for _, c in ipairs(client.get()) do
        if c.name == title then
            return c
        end
    end
    return nil
end

--- Find clients matching a predicate function.
-- @tparam function matcher Function that takes a client and returns true/false
-- @treturn table List of matching clients
function utils.find_clients(matcher)
    local results = {}
    for _, c in ipairs(client.get()) do
        if matcher(c) then
            table.insert(results, c)
        end
    end
    return results
end

--- Create a step function that waits for N clients to exist.
-- This is designed to be used directly in runner.run_steps().
-- @tparam number n Number of clients to wait for
-- @treturn function A step function that returns true when N clients exist
function utils.step_wait_for_clients(n)
    return function()
        return #client.get() >= n
    end
end

--- Create a step function that waits for a client with specific class.
-- @tparam string class The class/app_id to wait for
-- @treturn function A step function that returns the client when found
function utils.step_wait_for_class(class)
    return function()
        local c = utils.find_client_by_class(class)
        return c ~= nil
    end
end

--- Create a step function that spawns a client on first call, then waits.
-- This is a common pattern: spawn once, then poll until client appears.
-- @tparam function spawn_fn Function to call on first step call
-- @tparam function wait_fn Function that returns true when ready
-- @treturn function A step function for use in runner.run_steps()
function utils.step_spawn_and_wait(spawn_fn, wait_fn)
    local spawned = false
    return function(count)
        if count == 1 and not spawned then
            spawn_fn()
            spawned = true
        end
        return wait_fn()
    end
end

--- Assert that a geometry matches expected values.
-- Allows for some tolerance due to borders/decorations.
-- @tparam table actual The actual geometry {x, y, width, height}
-- @tparam table expected The expected geometry {x, y, width, height}
-- @tparam[opt=0] number tolerance Allowed difference for each value
function utils.assert_geometry(actual, expected, tolerance)
    tolerance = tolerance or 0

    local function check(name, a, e)
        if e ~= nil then
            local diff = math.abs(a - e)
            if diff > tolerance then
                error(string.format(
                    "Geometry mismatch: %s expected %d, got %d (diff %d, tolerance %d)",
                    name, e, a, diff, tolerance
                ))
            end
        end
    end

    check("x", actual.x, expected.x)
    check("y", actual.y, expected.y)
    check("width", actual.width, expected.width)
    check("height", actual.height, expected.height)
end

--- Assert that a client has expected properties.
-- @tparam client c The client to check
-- @tparam table props Table of property_name = expected_value
function utils.assert_client_props(c, props)
    for prop, expected in pairs(props) do
        local actual = c[prop]
        if actual ~= expected then
            error(string.format(
                "Client property mismatch: %s expected %s, got %s",
                prop, tostring(expected), tostring(actual)
            ))
        end
    end
end

--- Kill all clients and wait for them to be gone.
-- Returns a step function for use in runner.run_steps().
-- @treturn function A step function that kills all clients
function utils.step_kill_all_clients()
    local killed = false
    return function()
        if not killed then
            for _, c in ipairs(client.get()) do
                c:kill()
            end
            killed = true
        end
        return #client.get() == 0
    end
end

--- Get the focused screen's workarea.
-- @treturn table The workarea geometry {x, y, width, height}
function utils.get_workarea()
    local s = awful.screen.focused()
    return s and s.workarea or { x = 0, y = 0, width = 1280, height = 720 }
end

--- Check if we're running in headless mode.
-- @treturn boolean True if running with headless backend
function utils.is_headless()
    return os.getenv("WLR_BACKENDS") == "headless"
end

---------------------------------------------------------------------------
--- Debug helpers for focus history, signals, and stacking order
-- @section debug_helpers
---------------------------------------------------------------------------

--- Debug: Print current focus history state.
-- Prints the focus history list with client classes/names for debugging.
-- @tparam[opt=false] boolean verbose Include additional client details
function utils.debug_focus_history(verbose)
    local aclient = require("awful.client")
    local history = aclient.focus.history.list
    local enabled, count = aclient.focus.history.is_enabled()

    io.stderr:write(string.format(
        "[DEBUG] Focus History: enabled=%s, disabled_count=%d, entries=%d\n",
        tostring(enabled), count or -1, #history
    ))

    if #history == 0 then
        io.stderr:write("[DEBUG]   (empty)\n")
    else
        for i, c in ipairs(history) do
            if verbose then
                io.stderr:write(string.format(
                    "[DEBUG]   %d: class=%s name=%s valid=%s focused=%s\n",
                    i, tostring(c.class), tostring(c.name),
                    tostring(c.valid), tostring(c == client.focus)
                ))
            else
                io.stderr:write(string.format(
                    "[DEBUG]   %d: class=%s\n", i, tostring(c.class)
                ))
            end
        end
    end
end

--- Debug: Print all managed clients.
-- @tparam[opt=false] boolean verbose Include geometry and state details
function utils.debug_clients(verbose)
    local clients = client.get()
    io.stderr:write(string.format("[DEBUG] Managed clients: %d\n", #clients))

    for i, c in ipairs(clients) do
        if verbose then
            local geo = c:geometry()
            io.stderr:write(string.format(
                "[DEBUG]   %d: class=%s name=%s valid=%s visible=%s minimized=%s geo=%dx%d+%d+%d\n",
                i, tostring(c.class), tostring(c.name),
                tostring(c.valid), tostring(c:isvisible()),
                tostring(c.minimized),
                geo.width, geo.height, geo.x, geo.y
            ))
        else
            io.stderr:write(string.format(
                "[DEBUG]   %d: class=%s focused=%s\n",
                i, tostring(c.class), tostring(c == client.focus)
            ))
        end
    end
end

--- Debug: Print current focused client.
function utils.debug_focused()
    local c = client.focus
    if c then
        io.stderr:write(string.format(
            "[DEBUG] Focused: class=%s name=%s\n",
            tostring(c.class), tostring(c.name)
        ))
    else
        io.stderr:write("[DEBUG] Focused: nil\n")
    end
end

--- Signal tracker for debugging signal flow from C to Lua.
-- Creates a tracker object that counts signal emissions.
-- @treturn table Signal tracker with connect/get_count/reset methods
function utils.create_signal_tracker()
    local tracker = {
        counts = {},
        log = {},
    }

    --- Connect to a signal and track its emissions.
    -- @tparam string signal_name The signal name (e.g., "focus", "property::active")
    -- @tparam[opt] object obj Object to connect on (default: client class)
    function tracker:connect(signal_name, obj)
        self.counts[signal_name] = 0
        local target = obj or client

        target.connect_signal(signal_name, function(c, ...)
            self.counts[signal_name] = (self.counts[signal_name] or 0) + 1
            table.insert(self.log, {
                time = os.time(),
                signal = signal_name,
                client_class = c and c.class or nil,
                args = {...}
            })
            io.stderr:write(string.format(
                "[SIGNAL] %s fired (count=%d) client=%s\n",
                signal_name, self.counts[signal_name],
                c and c.class or "nil"
            ))
        end)
    end

    --- Connect to a global signal on awesome object.
    -- @tparam string signal_name The signal name (e.g., "client::focus")
    function tracker:connect_global(signal_name)
        self.counts[signal_name] = 0

        awesome.connect_signal(signal_name, function(...)
            self.counts[signal_name] = (self.counts[signal_name] or 0) + 1
            table.insert(self.log, {
                time = os.time(),
                signal = signal_name,
                args = {...}
            })
            io.stderr:write(string.format(
                "[SIGNAL] global %s fired (count=%d)\n",
                signal_name, self.counts[signal_name]
            ))
        end)
    end

    --- Get the count for a specific signal.
    -- @tparam string signal_name The signal to check
    -- @treturn number The emission count
    function tracker:get_count(signal_name)
        return self.counts[signal_name] or 0
    end

    --- Reset all counts.
    function tracker:reset()
        for k in pairs(self.counts) do
            self.counts[k] = 0
        end
        self.log = {}
    end

    --- Print summary of all tracked signals.
    function tracker:print_summary()
        io.stderr:write("[SIGNAL SUMMARY]\n")
        for name, count in pairs(self.counts) do
            io.stderr:write(string.format("  %s: %d\n", name, count))
        end
    end

    return tracker
end

--- DEPRECATED: Wait for a condition with debug output.
-- WARNING: This function uses a blocking busy-wait loop that freezes the
-- event loop. Use async.wait_for_condition() instead for non-blocking waits.
--
-- @deprecated Use async.wait_for_condition() from _async.lua instead
-- @tparam string description What we're waiting for
-- @tparam function condition Function that returns true when done
-- @tparam[opt=5] number max_seconds Maximum seconds to wait
-- @treturn boolean True if condition met, false if timed out
function utils.wait_for(description, condition, max_seconds)
    io.stderr:write("[DEPRECATED] utils.wait_for() blocks the event loop! Use async.wait_for_condition() instead.\n")

    max_seconds = max_seconds or 5
    local start = os.time()

    io.stderr:write(string.format("[WAIT] %s...\n", description))

    while os.time() - start < max_seconds do
        if condition() then
            io.stderr:write(string.format("[WAIT] %s: OK\n", description))
            return true
        end
        -- WARNING: This busy-wait blocks the compositor event loop!
    end

    io.stderr:write(string.format("[WAIT] %s: TIMEOUT\n", description))
    return false
end

--- Create a step that verifies focus history contains expected entries.
-- @tparam table expected_classes List of classes in expected order (most recent first)
-- @treturn function Step function for runner.run_steps()
function utils.step_verify_focus_history(expected_classes)
    return function()
        local aclient = require("awful.client")
        local history = aclient.focus.history.list

        if #history < #expected_classes then
            return nil -- Not enough entries yet, keep waiting
        end

        -- Verify order matches
        for i, expected_class in ipairs(expected_classes) do
            local c = history[i]
            if not c or c.class ~= expected_class then
                io.stderr:write(string.format(
                    "[VERIFY] Focus history mismatch at %d: expected=%s got=%s\n",
                    i, expected_class, c and c.class or "nil"
                ))
                return false
            end
        end

        io.stderr:write("[VERIFY] Focus history matches expected order\n")
        return true
    end
end

--- Create a step that waits for focus to be on a specific client class.
-- @tparam string class The class/app_id to wait for
-- @treturn function Step function for runner.run_steps()
function utils.step_wait_for_focus(class)
    return function()
        local c = client.focus
        if c and c.class == class then
            return true
        end
        return nil -- Keep waiting
    end
end

--- Activate a client and verify focus.
-- Helper to properly activate a client using request::activate signal.
-- @tparam client c The client to activate
-- @tparam[opt="test"] string context Activation context
function utils.activate_client(c, context)
    context = context or "test"
    c:emit_signal("request::activate", context, { raise = true })
end

---------------------------------------------------------------------------
--- TDD assertion helpers
-- @section assertions
---------------------------------------------------------------------------

--- Assert that focus is on a specific client class (or nil).
-- Throws an error with descriptive message if assertion fails.
-- @tparam string|nil expected_class Expected class name, or nil for no focus
function utils.assert_focus(expected_class)
    local c = client.focus
    if expected_class == nil then
        if c ~= nil then
            error(string.format(
                "Expected no focus, got %s",
                c.class or "unknown"
            ), 2)
        end
    else
        if c == nil then
            error(string.format(
                "Expected focus on '%s', got nil",
                expected_class
            ), 2)
        elseif c.class ~= expected_class then
            error(string.format(
                "Expected focus on '%s', got '%s'",
                expected_class, c.class or "unknown"
            ), 2)
        end
    end
end

--- Assert that a signal was emitted exactly N times.
-- @tparam table tracker Signal tracker created by create_signal_tracker()
-- @tparam string signal_name The signal to check
-- @tparam number expected Expected emission count
function utils.assert_signal_count(tracker, signal_name, expected)
    local actual = tracker:get_count(signal_name)
    if actual ~= expected then
        error(string.format(
            "Signal '%s': expected %d emissions, got %d",
            signal_name, expected, actual
        ), 2)
    end
end

--- Assert the current number of managed clients.
-- @tparam number expected Expected client count
function utils.assert_client_count(expected)
    local actual = #client.get()
    if actual ~= expected then
        error(string.format(
            "Expected %d clients, got %d",
            expected, actual
        ), 2)
    end
end

--- Assert that a condition is true, with custom message.
-- Like Lua's assert but with better error level for test output.
-- @tparam boolean condition The condition to check
-- @tparam string message Error message if condition is false
function utils.assert_true(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

return utils

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
