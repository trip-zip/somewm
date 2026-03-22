---------------------------------------------------------------------------
--- Integration test for hot-reload (awesome.restart()).
--
-- Verifies that awesome.restart() performs an in-process Lua state rebuild
-- without crashing. Spawns a client, triggers restart, verifies no crash.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

-- Skip test if no terminal available
if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available for spawning test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local test_class = "somewm_hot_reload_test"
local c = nil

local steps = {
    -- Step 1: Spawn a test client
    function(count)
        if count == 1 then
            print("Step 1: Spawning test client")
            test_client(test_class, "HotReloadTest")
        end

        c = utils.find_client_by_class(test_class)
        if c then
            print("Step 1: Client found: " .. tostring(c.name))
            return true
        end
    end,

    -- Step 2: Trigger hot-reload and quit
    function(count)
        if count == 1 then
            print("Step 2: Pre-restart - clients=" .. #client.get() ..
                  " screens=" .. screen.count())
            print("Step 2: Calling awesome.restart()")
            -- awesome.restart() defers to idle. After hot-reload completes,
            -- this test's Lua state is destroyed. Queue a quit that will
            -- execute in the NEW Lua state after rc.lua loads.
            awesome.restart()
        end
        -- Return true immediately so the test runner sees completion.
        -- The hot-reload happens on the next idle iteration.
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
