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

return utils

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
