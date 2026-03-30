---------------------------------------------------------------------------
--- Test: _set_geometry_silent sets geometry without signals or screen change
--
-- Verifies that c:_set_geometry_silent() applies geometry without emitting
-- property::geometry signals or reassigning the client to a different screen.
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
local signal_count = 0
local original_screen

local steps = {
    -- Step 1: Spawn a client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client...\n")
            test_client("silent_geo_test")
        end
        my_client = utils.find_client_by_class("silent_geo_test")
        if my_client then
            io.stderr:write("[TEST] Client spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Make floating, record screen, connect signal counter
    function()
        my_client.floating = true
        original_screen = my_client.screen

        my_client:connect_signal("property::geometry", function()
            signal_count = signal_count + 1
        end)

        io.stderr:write("[TEST] Client is floating, signal counter connected\n")
        return true
    end,

    -- Step 3: Call _set_geometry_silent with offscreen position
    function()
        local new_geo = {x = 3000, y = 0, width = 400, height = 300}
        local result = my_client:_set_geometry_silent(new_geo)

        -- Check geometry was applied
        local geo = my_client:geometry()
        assert(geo.x == 3000,
            string.format("Expected x=3000, got x=%d", geo.x))
        assert(geo.width == 400,
            string.format("Expected width=400, got width=%d", geo.width))
        assert(geo.height == 300,
            string.format("Expected height=300, got height=%d", geo.height))
        io.stderr:write("[TEST] PASS: geometry was applied\n")

        -- Check no signals fired
        assert(signal_count == 0,
            string.format("Expected 0 signals, got %d", signal_count))
        io.stderr:write("[TEST] PASS: no property::geometry signals fired\n")

        -- Check screen was not reassigned
        assert(my_client.screen == original_screen,
            string.format("Expected screen unchanged, got %s (was %s)",
                tostring(my_client.screen), tostring(original_screen)))
        io.stderr:write("[TEST] PASS: screen was not reassigned\n")

        -- Check return value matches
        assert(result.x == 3000, "Return value x mismatch")
        assert(result.width == 400, "Return value width mismatch")
        io.stderr:write("[TEST] PASS: return value correct\n")

        return true
    end,

    -- Step 4: Control test - normal geometry() should fire signals
    function()
        signal_count = 0
        my_client:geometry({x = 100, y = 100, width = 400, height = 300})

        assert(signal_count > 0,
            string.format("Expected signals from normal geometry(), got %d", signal_count))
        io.stderr:write(string.format("[TEST] PASS: normal geometry() fired %d signals (control)\n",
            signal_count))

        return true
    end,

    -- Step 5: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
