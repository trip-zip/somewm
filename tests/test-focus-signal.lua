---------------------------------------------------------------------------
--- Test: focus signal fires when client gains focus
--
-- Verifies that the object-level "focus" signal is emitted from C
-- when a client receives keyboard focus.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Track signal emissions
local focus_count = 0
local focus_client = nil

client.connect_signal("focus", function(c)
    focus_count = focus_count + 1
    focus_client = c
    io.stderr:write(string.format("[SIGNAL] focus fired, count=%d, class=%s\n",
        focus_count, c and c.class or "nil"))
end)

local my_client

local steps = {
    -- Step 1: Spawn a client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client...\n")
            test_client("signal_test")
        end
        my_client = utils.find_client_by_class("signal_test")
        if my_client then
            return true
        end
        return nil -- Keep waiting
    end,

    -- Step 2: Verify focus signal fired
    function()
        io.stderr:write(string.format("[TEST] Checking: focus_count=%d\n", focus_count))

        if focus_count < 1 then
            return nil -- Keep waiting
        end

        -- Verify signal fired exactly once
        assert(focus_count == 1,
            string.format("Expected 1 focus signal, got %d", focus_count))

        -- Verify it was for our client
        assert(focus_client == my_client,
            "Focus signal was for wrong client")

        io.stderr:write("[TEST] PASS: focus signal fired correctly\n")
        return true
    end,

    -- Step 3: Clean up
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing client\n")
            if my_client and my_client.valid then
                my_client:kill()
            end
        end

        if #client.get() == 0 then
            io.stderr:write("[TEST] Cleanup: done\n")
            return true
        end

        -- Force kill after waiting
        if count >= 15 then
            io.stderr:write("[TEST] Cleanup: force killing via SIGKILL\n")
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
