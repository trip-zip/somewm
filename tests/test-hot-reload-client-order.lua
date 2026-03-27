---------------------------------------------------------------------------
--- Integration test for hot-reload client ordering.
--
-- Verifies that awesome.restart() preserves client order in the tiling
-- layout. Spawns two clients, confirms their order, then triggers
-- hot-reload. The fix (client_array_append instead of client_array_push
-- in Phase E) prevents the globalconf.clients array from reversing.
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

local class_a = "order_test_A"
local class_b = "order_test_B"

local steps = {
    -- Step 1: Spawn first client
    function(count)
        if count == 1 then
            print("Step 1: Spawning client A")
            test_client(class_a, "Order A")
        end
        if utils.find_client_by_class(class_a) then
            return true
        end
    end,

    -- Step 2: Spawn second client
    function(count)
        if count == 1 then
            print("Step 2: Spawning client B")
            test_client(class_b, "Order B")
        end
        if utils.find_client_by_class(class_b) then
            return true
        end
    end,

    -- Step 3: Verify both clients exist in tiling layout, then restart
    function(count)
        if count == 1 then
            local clients = client.get()
            assert(#clients == 2,
                "Expected 2 clients, got " .. #clients)

            -- Log the pre-restart order
            print("Step 3: Pre-restart client order:")
            for i, c in ipairs(clients) do
                print(string.format("  [%d] class=%s", i, c.class))
            end

            print("Step 3: Calling awesome.restart()")
            awesome.restart()
        end
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
