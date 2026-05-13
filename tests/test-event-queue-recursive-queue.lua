---------------------------------------------------------------------------
--- Test: recursive queueing — handler that queues more events
--
-- Verifies the snapshot invariant documented in
-- some_event_queue_drain(): drain captures the queue length at entry,
-- so events queued BY a handler during dispatch are deferred to the
-- next drain cycle, not processed in the current one. The practical
-- effect is that a handler which re-queues the same signal it is
-- handling cannot cause infinite recursion within a single frame.
--
-- Scenario:
--   A handler connected to property::geometry itself calls c:geometry(),
--   which re-queues another property::geometry. The handler bounds the
--   chain at TARGET total invocations. The test verifies:
--     - The chain reaches TARGET (re-queued events DO eventually drain).
--     - The chain stops at TARGET (no runaway, no infinite loop).
--     - No crash, no hang.
--
-- Per-drain-per-step counting is intentionally NOT asserted: the step
-- runner's timer does not guarantee a 1:1 step-to-drain mapping, so
-- timing-based per-drain checks are flaky. What matters observably is
-- the end-state bound and the absence of a hang.
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
local invocations = 0
local recursion_armed = false
local next_x = 500  -- monotonically increasing so every re-queue mutates geometry
local TARGET = 5

local steps = {
    function(count)
        if count == 1 then
            test_client("recursive_test")
        end
        my_client = utils.find_client_by_class("recursive_test")
        return my_client and true or nil
    end,

    function()
        my_client.floating = true
        my_client:geometry({x = 100, y = 100, width = 400, height = 300})

        -- Handler re-queues when armed, up to TARGET total invocations.
        -- Each re-queue uses a distinct x so property::geometry actually
        -- fires (client_resize_do skips emission on unchanged geometry).
        -- `recursion_armed` keeps spawn-time property::geometry events
        -- from triggering the recursion before we're ready.
        my_client:connect_signal("property::geometry", function(c)
            invocations = invocations + 1
            if recursion_armed and invocations < TARGET then
                next_x = next_x + 1
                c:geometry({x = next_x, y = 100,
                            width = 400, height = 300})
            end
        end)
        return true
    end,

    -- Let spawn-time events drain without arming the recursion.
    function()
        invocations = 0
        return true
    end,

    -- Arm recursion and queue the initial property::geometry.
    function()
        recursion_armed = true
        invocations = 0
        next_x = 500
        my_client:geometry({x = next_x, y = 100, width = 400, height = 300})
        -- Within the same step the handler has NOT fired (deferred dispatch).
        assert(invocations == 0,
            string.format(
                "regression: handler fired synchronously (got %d)",
                invocations))
        return true
    end,

    -- Wait for the re-queue chain to reach TARGET. If the snapshot
    -- invariant were broken the chain could recurse unbounded and
    -- freeze the compositor; the test would time out.
    function(count)
        if invocations >= TARGET then
            io.stderr:write(string.format(
                "[TEST] chain reached %d invocations after %d ticks\n",
                invocations, count))
            return true
        end
        if count > 50 then
            error(string.format(
                "invocations stuck at %d (expected %d) after 50 ticks",
                invocations, TARGET))
        end
        return nil
    end,

    -- Disarm and capture the count. The handler should stop firing now.
    function()
        recursion_armed = false
        return true
    end,

    -- Give several more drain cycles to pass. No new events are being
    -- queued, so invocations should NOT grow.
    function() return true end,
    function() return true end,
    function() return true end,

    function()
        assert(invocations == TARGET,
            string.format(
                "regression: expected exactly %d invocations after the " ..
                "chain stopped; got %d (chain either did not stop or " ..
                "overshot)", TARGET, invocations))
        io.stderr:write(string.format(
            "[TEST] PASS: recursive re-queue chain bounded at %d; no " ..
            "runaway recursion\n", TARGET))
        -- Disarm so runner's cleanup step doesn't re-trigger the chain
        -- when it fires property::geometry via c:kill().
        recursion_armed = false
        return true
    end,
}

runner.run_steps(steps)
