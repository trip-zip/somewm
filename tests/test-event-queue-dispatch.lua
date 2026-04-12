---------------------------------------------------------------------------
--- Test: event queue defers C-emitted signals to the frame boundary
--
-- Verifies the observable behavior of event_queue.c:
--   1. Property signals queued from C are NOT delivered synchronously.
--   2. They ARE delivered by the next some_refresh() drain.
--   3. Multiple emissions in one frame all drain together.
--   4. Signals queued in a later frame remain separate from earlier ones.
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
local geo_count = 0
local x_count = 0
local geo_count_at_emit = nil
local frame_one_count = 0

local steps = {
    -- Step 1: Spawn a client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client...\n")
            test_client("event_queue_test")
        end
        my_client = utils.find_client_by_class("event_queue_test")
        if my_client then
            io.stderr:write("[TEST] Client spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Make floating, attach signal counters, drain anything left
    -- over from spawn so the test starts from a clean slate.
    function()
        my_client.floating = true
        my_client:connect_signal("property::geometry", function()
            geo_count = geo_count + 1
        end)
        my_client:connect_signal("property::x", function()
            x_count = x_count + 1
        end)
        return true
    end,

    -- Step 3: Reset counters now that any spawn-time signals have drained.
    function()
        geo_count = 0
        x_count = 0
        return true
    end,

    -- Step 4: Verify deferred dispatch.
    -- Setting geometry once queues exactly one property::geometry event.
    -- The handler must NOT have run yet at this point (within the same
    -- step, before the runner yields to the event loop).
    function()
        my_client:geometry({x = 50, y = 50, width = 320, height = 240})
        geo_count_at_emit = geo_count
        io.stderr:write(string.format(
            "[TEST] right after emit: geo_count=%d (expect 0, queued)\n",
            geo_count_at_emit))
        return true
    end,

    -- Step 5: After the runner yields, drain has happened. Counter > 0.
    function()
        assert(geo_count_at_emit == 0,
            string.format(
                "regression: queued geometry signal fired synchronously " ..
                "(expected 0 in-step, got %d)", geo_count_at_emit))
        assert(geo_count >= 1,
            string.format(
                "regression: queued geometry signal not drained " ..
                "(expected >= 1 after drain, got %d)", geo_count))

        io.stderr:write(string.format(
            "[TEST] PASS: deferred dispatch (in-step=0, after-drain=%d)\n",
            geo_count))
        frame_one_count = geo_count
        return true
    end,

    -- Step 6: Multiple emissions in one step all drain in the next cycle.
    -- Three geometry calls => three property::geometry events queued =>
    -- three handler invocations during the next drain.
    function()
        geo_count = 0
        x_count = 0

        my_client:geometry({x = 60, y = 60, width = 320, height = 240})
        my_client:geometry({x = 70, y = 70, width = 320, height = 240})
        my_client:geometry({x = 80, y = 80, width = 320, height = 240})

        return true
    end,

    -- Step 7: Verify all three drained together.
    function()
        assert(geo_count == 3,
            string.format(
                "regression: expected 3 property::geometry events from " ..
                "3 geometry() calls in one frame, got %d", geo_count))
        assert(x_count == 3,
            string.format(
                "regression: expected 3 property::x events from 3 " ..
                "geometry() calls (x changed each time), got %d", x_count))

        io.stderr:write(string.format(
            "[TEST] PASS: 3 emissions drained together (geo=%d, x=%d)\n",
            geo_count, x_count))
        return true
    end,

    -- Step 8: Cross-frame separation.
    -- Set geometry, yield, set geometry, yield. Each frame should drain
    -- its own events. The total should equal sum of per-frame counts.
    function()
        geo_count = 0
        my_client:geometry({x = 100, y = 100, width = 400, height = 300})
        return true
    end,

    function()
        assert(geo_count == 1,
            string.format(
                "regression: expected 1 geometry event after first frame, got %d",
                geo_count))
        my_client:geometry({x = 110, y = 110, width = 400, height = 300})
        return true
    end,

    function()
        assert(geo_count == 2,
            string.format(
                "regression: expected 2 geometry events total after second " ..
                "frame, got %d", geo_count))
        io.stderr:write("[TEST] PASS: cross-frame separation\n")
        return true
    end,

    -- Step 9: Cleanup
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

        if count >= 10 then
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
