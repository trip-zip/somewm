---------------------------------------------------------------------------
--- Test: spawned client receives focus
--
-- Verifies that when a client is spawned, it automatically receives focus.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local my_client

local steps = {
    -- Step 1: Spawn a client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client...\n")
            test_client("focus_test")
        end
        my_client = utils.find_client_by_class("focus_test")
        if my_client then
            io.stderr:write("[TEST] Client spawned\n")
            return true
        end
        return nil -- Keep waiting
    end,

    -- Step 2: Wait for client to have focus
    function(count)
        io.stderr:write(string.format("[TEST] Checking focus (attempt %d): client.focus=%s, my_client=%s\n",
            count, tostring(client.focus), tostring(my_client)))

        if client.focus == my_client then
            io.stderr:write("[TEST] PASS: spawned client has focus\n")
            return true
        end

        -- Timeout after ~1 second (10 iterations * 100ms)
        if count > 10 then
            error(string.format("Expected spawned client to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end

        return nil -- Keep waiting
    end,

    -- Step 3: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
