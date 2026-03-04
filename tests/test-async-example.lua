---------------------------------------------------------------------------
-- Example test demonstrating the async test API.
--
-- This test shows how to use the new event-driven async primitives
-- instead of magic polling counts. Compare with older tests that use
-- `runner.run_steps()` with `count < 5` style waits.
--
-- Run with: make test-one TEST=tests/test-async-example.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")

-- Use runner.run_async() instead of runner.run_steps()
-- The test function runs as a coroutine and can use async.* functions
runner.run_async(function()
    -- Spawn a test client
    -- test_client() returns immediately - client spawns asynchronously
    test_client("async_test_app")

    -- Wait for client to appear (event-driven, not polling!)
    -- This yields the coroutine until the "manage" signal fires
    -- with a client matching our class, or timeout after 5 seconds
    local c = async.wait_for_client("async_test_app", 5)

    -- Assert client appeared
    if not c then
        runner.done("Client did not appear within 5 seconds")
        return
    end

    io.stderr:write("[TEST] Client appeared: " .. tostring(c.class) .. "\n")

    -- Verify it has focus (new clients get focus by default)
    local focused = async.wait_for_focus("async_test_app", 2)
    if not focused then
        runner.done("Client did not receive focus")
        return
    end

    io.stderr:write("[TEST] Client has focus\n")

    -- Test some client properties
    assert(c.valid, "Client should be valid")
    assert(c.class == "async_test_app", "Class should match")

    -- Kill the client
    -- Note: Terminal running 'sleep infinity' may take a moment to close
    c:kill()

    -- Wait for client to be gone (give it more time in headless mode)
    local gone = async.wait_for_no_clients(5)
    if not gone then
        -- Force kill any remaining clients
        io.stderr:write("[TEST] Client slow to close, force killing...\n")
        for _, remaining in ipairs(client.get()) do
            if remaining.pid then
                os.execute("kill -9 " .. remaining.pid .. " 2>/dev/null")
            end
        end
        -- Wait a bit more
        async.sleep(0.5)
        gone = async.wait_for_no_clients(2)
        if not gone then
            runner.done("Client did not close even after force kill")
            return
        end
    end

    io.stderr:write("[TEST] Client closed successfully\n")

    -- Test passed!
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
