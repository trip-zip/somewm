---------------------------------------------------------------------------
--- State management for persistent compositor testing.
--
-- This module provides functions to reset compositor state between tests
-- when running in persistent mode (PERSISTENT=1). This allows running
-- multiple tests without restarting the compositor, dramatically improving
-- test suite performance.
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
-- @module _state
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local timer = require("gears.timer")

local state = {}

-- Track signal connections for cleanup
local tracked_signals = {}

-- Track timers for cleanup
local tracked_timers = {}

---------------------------------------------------------------------------
--- Signal Tracking
-- These functions track signal connections so they can be disconnected
-- between tests, preventing test pollution.
---------------------------------------------------------------------------

--- Connect a signal and track it for later cleanup.
-- Use this instead of obj.connect_signal() in tests to ensure
-- signals are properly disconnected between tests.
-- @tparam table obj Object to connect signal on (e.g., client, screen)
-- @tparam string signal Signal name
-- @tparam function func Handler function
function state.track_signal(obj, signal, func)
    table.insert(tracked_signals, {
        obj = obj,
        signal = signal,
        func = func,
    })
    obj.connect_signal(signal, func)
end

--- Connect a global signal (on awesome object) and track it.
-- @tparam string signal Signal name
-- @tparam function func Handler function
function state.track_global_signal(signal, func)
    table.insert(tracked_signals, {
        obj = awesome,
        signal = signal,
        func = func,
        is_global = true,
    })
    awesome.connect_signal(signal, func)
end

--- Disconnect all tracked signals.
-- Called automatically by state.reset().
function state.disconnect_tracked_signals()
    for _, conn in ipairs(tracked_signals) do
        if conn.is_global then
            awesome.disconnect_signal(conn.signal, conn.func)
        else
            conn.obj.disconnect_signal(conn.signal, conn.func)
        end
    end
    tracked_signals = {}
end

---------------------------------------------------------------------------
--- Timer Tracking
---------------------------------------------------------------------------

--- Create a timer and track it for cleanup.
-- @tparam table args Timer arguments (same as gears.timer)
-- @treturn timer The created timer
function state.track_timer(args)
    local t = timer(args)
    table.insert(tracked_timers, t)
    return t
end

--- Stop and remove all tracked timers.
function state.stop_tracked_timers()
    for _, t in ipairs(tracked_timers) do
        if t.started then
            t:stop()
        end
    end
    tracked_timers = {}
end

---------------------------------------------------------------------------
--- Client Management
---------------------------------------------------------------------------

--- Kill all managed clients.
-- @tparam[opt=false] boolean force Use SIGKILL instead of graceful close
function state.kill_all_clients(force)
    for _, c in ipairs(client.get()) do
        if force then
            -- Force kill via pid
            local pid = c.pid
            if pid then
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
        else
            c:kill()
        end
    end
end

--- Wait for all clients to be gone (blocking, for shell script use).
-- Note: This is a blocking wait, only for use in state.reset() via IPC.
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @treturn boolean True if all clients gone, false if timeout
function state.wait_for_no_clients(timeout_secs)
    timeout_secs = timeout_secs or 5
    local start = os.time()

    while os.time() - start < timeout_secs do
        if #client.get() == 0 then
            return true
        end
        -- Small yield to allow events to process
        -- Note: This doesn't actually yield in a useful way, but the
        -- shell script will poll the result
    end

    return false
end

---------------------------------------------------------------------------
--- Tag Management
---------------------------------------------------------------------------

--- Reset tags to default test configuration.
-- Creates a single "test" tag per screen with floating layout.
function state.reset_tags()
    for s in screen do
        -- Delete all tags except the first one
        local tags = s.tags
        for i = #tags, 2, -1 do
            tags[i]:delete()
        end

        -- Reset first tag
        if tags[1] then
            tags[1].name = "test"
            tags[1].layout = awful.layout.suit.floating
            tags[1]:view_only()
            tags[1].selected = true
        else
            -- No tags? Create one
            awful.tag({ "test" }, s, awful.layout.suit.floating)
        end
    end
end

---------------------------------------------------------------------------
--- Focus Management
---------------------------------------------------------------------------

--- Clear focus history.
function state.clear_focus_history()
    local aclient = require("awful.client")
    if aclient.focus and aclient.focus.history then
        -- Clear the history list
        if aclient.focus.history.list then
            for i = #aclient.focus.history.list, 1, -1 do
                aclient.focus.history.list[i] = nil
            end
        end
    end

    -- Clear current focus
    if client.focus then
        client.focus = nil
    end
end

---------------------------------------------------------------------------
--- Full State Reset
---------------------------------------------------------------------------

--- Reset all compositor state for a fresh test.
-- Call this between tests when running in persistent mode.
-- @tparam[opt] table options Reset options
-- @tparam[opt=true] boolean options.kill_clients Kill all clients
-- @tparam[opt=true] boolean options.reset_tags Reset tags to defaults
-- @tparam[opt=true] boolean options.clear_focus Clear focus history
-- @tparam[opt=true] boolean options.disconnect_signals Disconnect tracked signals
-- @tparam[opt=true] boolean options.stop_timers Stop tracked timers
-- @treturn boolean True if reset succeeded
function state.reset(options)
    options = options or {}

    -- Default all options to true
    local kill_clients = options.kill_clients ~= false
    local reset_tags = options.reset_tags ~= false
    local clear_focus = options.clear_focus ~= false
    local disconnect_signals = options.disconnect_signals ~= false
    local stop_timers = options.stop_timers ~= false

    io.stderr:write("[STATE] Resetting compositor state...\n")

    -- 1. Stop tracked timers first (prevents interference)
    if stop_timers then
        state.stop_tracked_timers()
    end

    -- 2. Disconnect tracked signals (prevents spurious events)
    if disconnect_signals then
        state.disconnect_tracked_signals()
    end

    -- 3. Kill all clients
    if kill_clients then
        state.kill_all_clients(false)

        -- Wait briefly for clients to close gracefully
        local client_count = #client.get()
        if client_count > 0 then
            io.stderr:write(string.format("[STATE] Waiting for %d clients to close...\n", client_count))

            -- Poll for up to 2 seconds
            local waited = 0
            while #client.get() > 0 and waited < 20 do
                -- Can't actually sleep here without blocking, so we just
                -- note the count and let the shell script handle waiting
                waited = waited + 1
            end

            -- Force kill any remaining
            if #client.get() > 0 then
                io.stderr:write("[STATE] Force-killing remaining clients...\n")
                state.kill_all_clients(true)
            end
        end
    end

    -- 4. Clear focus history
    if clear_focus then
        state.clear_focus_history()
    end

    -- 5. Reset tags
    if reset_tags then
        state.reset_tags()
    end

    io.stderr:write("[STATE] Reset complete.\n")
    return true
end

--- Get current state summary (for debugging).
-- @treturn table State summary
function state.get_summary()
    return {
        client_count = #client.get(),
        screen_count = screen.count(),
        tracked_signals = #tracked_signals,
        tracked_timers = #tracked_timers,
        focused_class = client.focus and client.focus.class or nil,
    }
end

--- Print state summary to stderr.
function state.debug()
    local s = state.get_summary()
    io.stderr:write(string.format(
        "[STATE] clients=%d screens=%d signals=%d timers=%d focus=%s\n",
        s.client_count, s.screen_count, s.tracked_signals, s.tracked_timers,
        s.focused_class or "nil"
    ))
end

return state

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
