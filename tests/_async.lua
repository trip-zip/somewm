---------------------------------------------------------------------------
--- Async primitives for somewm integration tests.
--
-- Provides non-blocking, event-driven waiting using coroutines and gears.timer.
-- These primitives replace magic polling counts with semantic, reliable waits.
--
-- Usage with runner.run_async():
--     runner.run_async(function()
--         test_client("myapp")
--         local c = async.wait_for_client("myapp", 5)
--         assert(c, "Client did not appear")
--         runner.done()
--     end)
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
-- @module _async
---------------------------------------------------------------------------

local timer = require("gears.timer")

local async = {}

-- Current test coroutine (set by runner.run_async)
local current_co = nil

--- Internal: Set the current test coroutine.
-- Called by runner.run_async() before starting the test.
-- @tparam thread co The coroutine running the test
function async._set_coroutine(co)
    current_co = co
end

--- Internal: Get the current test coroutine.
-- @treturn thread The current test coroutine
function async._get_coroutine()
    return current_co
end

--- Internal: Resume the test coroutine with a value.
-- Used by async primitives when their wait completes.
-- @param ... Values to pass to coroutine.resume
function async._resume(...)
    if current_co and coroutine.status(current_co) == "suspended" then
        local ok, err = coroutine.resume(current_co, ...)
        if not ok then
            io.stderr:write("Error in test coroutine: " .. tostring(err) .. "\n")
            require("_runner").done("Coroutine error: " .. tostring(err))
        end
    end
end

---------------------------------------------------------------------------
--- Wait for a signal on an object.
-- Yields the coroutine until the signal fires or timeout.
-- @tparam table obj Object to connect signal on (e.g., client, screen)
-- @tparam string signal_name Signal name (e.g., "manage", "focus")
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @tparam[opt] function filter Optional filter function(args...) -> boolean
-- @return Signal arguments if fired, nil if timeout
-- @usage local c = async.wait_for_signal(client, "manage", 5)
function async.wait_for_signal(obj, signal_name, timeout_secs, filter)
    timeout_secs = timeout_secs or 5

    -- Must be called from within a coroutine
    local co = coroutine.running()
    if not co then
        error("wait_for_signal must be called from runner.run_async()", 2)
    end

    local completed = false
    local result = nil
    local handler

    -- Signal handler - fires when signal is emitted
    handler = function(...)
        if completed then return end

        -- Apply filter if provided
        if filter and not filter(...) then
            return -- Signal fired but filter rejected it
        end

        completed = true
        obj.disconnect_signal(signal_name, handler)
        result = {...}

        -- Resume coroutine with the signal arguments
        timer.delayed_call(function()
            async._resume(unpack(result))
        end)
    end

    -- Connect handler
    obj.connect_signal(signal_name, handler)

    -- Timeout handler
    timer.start_new(timeout_secs, function()
        if completed then return false end
        completed = true
        obj.disconnect_signal(signal_name, handler)

        -- Resume coroutine with nil (timeout)
        timer.delayed_call(function()
            async._resume(nil)
        end)
        return false
    end)

    -- Yield coroutine - will be resumed by handler or timeout
    return coroutine.yield()
end

---------------------------------------------------------------------------
--- Wait for a condition to become true.
-- Polls the condition function until it returns true or timeout.
-- This is non-blocking - uses timer-based polling.
-- @tparam function condition Function that returns true when ready
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @tparam[opt=0.1] number poll_interval Seconds between polls
-- @treturn boolean True if condition met, false if timeout
-- @usage local ok = async.wait_for_condition(function() return #client.get() >= 2 end, 5)
function async.wait_for_condition(condition, timeout_secs, poll_interval)
    timeout_secs = timeout_secs or 5
    poll_interval = poll_interval or 0.1

    local co = coroutine.running()
    if not co then
        error("wait_for_condition must be called from runner.run_async()", 2)
    end

    local completed = false
    local start_time = os.time()
    local poll_count = 0
    local max_polls = math.ceil(timeout_secs / poll_interval)

    -- Check immediately first
    if condition() then
        return true
    end

    -- Poll timer
    local t
    t = timer.start_new(poll_interval, function()
        if completed then return false end

        poll_count = poll_count + 1

        -- Check condition
        if condition() then
            completed = true
            timer.delayed_call(function()
                async._resume(true)
            end)
            return false
        end

        -- Check timeout (using poll count for accuracy)
        if poll_count >= max_polls then
            completed = true
            timer.delayed_call(function()
                async._resume(false)
            end)
            return false
        end

        -- Keep polling
        return true
    end)

    return coroutine.yield()
end

---------------------------------------------------------------------------
--- Wait for a client with specific class to appear.
-- Combines signal waiting with class filtering.
-- @tparam string class The class/app_id to wait for
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @treturn client|nil The client if found, nil if timeout
-- @usage local c = async.wait_for_client("kitty", 5)
function async.wait_for_client(class, timeout_secs)
    timeout_secs = timeout_secs or 5

    -- Check if already exists
    for _, c in ipairs(client.get()) do
        if c.class == class then
            return c
        end
    end

    -- Wait for "request::manage" signal with class filter
    -- (Note: "manage" is deprecated, use "request::manage")
    local result = async.wait_for_signal(client, "request::manage", timeout_secs, function(c)
        return c and c.class == class
    end)

    if result then
        return result -- First element is the client
    end
    return nil
end

---------------------------------------------------------------------------
--- Wait for client count to reach a specific number.
-- @tparam number count Expected number of clients
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @treturn boolean True if count reached, false if timeout
-- @usage local ok = async.wait_for_client_count(3, 5)
function async.wait_for_client_count(count, timeout_secs)
    return async.wait_for_condition(function()
        return #client.get() >= count
    end, timeout_secs)
end

---------------------------------------------------------------------------
--- Wait for focus to be on a specific client class.
-- @tparam string class The class/app_id expected to have focus
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @treturn client|nil The focused client if matches, nil if timeout
-- @usage local c = async.wait_for_focus("myapp", 2)
function async.wait_for_focus(class, timeout_secs)
    timeout_secs = timeout_secs or 5

    -- Check current focus first
    local c = client.focus
    if c and c.class == class then
        return c
    end

    -- Wait for focus signal with class filter
    local result = async.wait_for_signal(client, "focus", timeout_secs, function(focused)
        return focused and focused.class == class
    end)

    if result then
        return result
    end
    return nil
end

---------------------------------------------------------------------------
--- Wait for all clients to be gone.
-- Useful for cleanup verification.
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @treturn boolean True if all clients gone, false if timeout
-- @usage local ok = async.wait_for_no_clients(3)
function async.wait_for_no_clients(timeout_secs)
    return async.wait_for_condition(function()
        return #client.get() == 0
    end, timeout_secs)
end

---------------------------------------------------------------------------
--- Non-blocking sleep.
-- Yields the coroutine for specified duration.
-- @tparam number secs Seconds to sleep
-- @usage async.sleep(0.5)  -- Wait 500ms
function async.sleep(secs)
    local co = coroutine.running()
    if not co then
        error("sleep must be called from runner.run_async()", 2)
    end

    timer.start_new(secs, function()
        timer.delayed_call(function()
            async._resume()
        end)
        return false
    end)

    coroutine.yield()
end

---------------------------------------------------------------------------
--- Spawn a client and wait for it to appear.
-- Combines spawning and waiting in one call.
-- @tparam function spawn_fn Function that spawns the client
-- @tparam string class Expected class/app_id of the client
-- @tparam[opt=5] number timeout_secs Maximum seconds to wait
-- @treturn client|nil The client if spawned, nil if timeout
-- @usage local c = async.spawn_and_wait(function() test_client("myapp") end, "myapp", 5)
function async.spawn_and_wait(spawn_fn, class, timeout_secs)
    spawn_fn()
    return async.wait_for_client(class, timeout_secs)
end

return async

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
