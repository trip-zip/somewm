---------------------------------------------------------------------------
--- Test: mouse::move coalescing across a single frame
--
-- Verifies the invariant documented in event_queue.c
-- (some_event_queue_move): between enter/leave brackets on a given
-- object, every mouse::move on that object folds into one event
-- carrying the latest coordinates.
--
-- Uses mouse._fake_motion(dx, dy) to inject relative motion through
-- motionnotify() the same way a real pointer device would. The regular
-- mouse.coords() API only warps the cursor position; it does not
-- generate motion signals.
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
local move_count = 0
local last_x, last_y

local CLIENT_X, CLIENT_Y = 100, 100
local CLIENT_W, CLIENT_H = 400, 300

-- Park cursor here before starting. Well clear of client edges.
local PARK_X, PARK_Y = CLIENT_X + 50, CLIENT_Y + 50

-- Final cursor position after 10 increments of (+1, +1).
local FINAL_ABS_X = PARK_X + 10
local FINAL_ABS_Y = PARK_Y + 10
local FINAL_LOCAL_X = FINAL_ABS_X - CLIENT_X
local FINAL_LOCAL_Y = FINAL_ABS_Y - CLIENT_Y

local steps = {
    function(count)
        if count == 1 then
            test_client("coalesce_test")
        end
        my_client = utils.find_client_by_class("coalesce_test")
        return my_client and true or nil
    end,

    function()
        my_client.floating = true
        my_client:geometry({x = CLIENT_X, y = CLIENT_Y,
                            width = CLIENT_W, height = CLIENT_H})
        return true
    end,

    -- Warp cursor to a known position inside the client. coords() does
    -- NOT generate motion events — it just sets cursor position.
    function()
        mouse.coords({x = PARK_X, y = PARK_Y}, false)
        return true
    end,

    -- Trigger an initial motionnotify at the parked position. This
    -- emits mouse::enter (if not already over the client) and an
    -- initial mouse::move. Both drain on the next some_refresh().
    function()
        mouse._fake_motion(0, 0)
        return true
    end,

    -- Connect the counter AFTER any priming events have drained, so
    -- the coalescing assertion only sees the 10 motions we inject.
    function()
        my_client:connect_signal("mouse::move", function(_, x, y)
            move_count = move_count + 1
            last_x, last_y = x, y
        end)
        return true
    end,

    -- Let any residual queued events drain.
    function()
        move_count = 0
        return true
    end,

    -- Inject 10 motions, each +1 in x and +1 in y. All stay inside
    -- the client, so no leave/enter breaks the coalescing chain.
    -- 10 queued mouse::move events should fold into 1.
    function()
        for i = 1, 10 do
            mouse._fake_motion(1, 1)
        end
        return true
    end,

    -- After the next drain, assert coalescing folded 10 motions to one,
    -- and the remaining event carries the FINAL coordinates (proving
    -- we update in place rather than keeping an earlier position).
    function()
        assert(move_count == 1,
            string.format(
                "regression: expected 1 coalesced mouse::move after 10 " ..
                "motion injections on the same client, got %d", move_count))
        assert(last_x == FINAL_LOCAL_X and last_y == FINAL_LOCAL_Y,
            string.format(
                "regression: coalesced move should carry final coords " ..
                "(%d, %d), got (%s, %s)",
                FINAL_LOCAL_X, FINAL_LOCAL_Y,
                tostring(last_x), tostring(last_y)))
        io.stderr:write(string.format(
            "[TEST] PASS: 10 motions coalesced to 1 move at (%d, %d)\n",
            last_x, last_y))
        return true
    end,
}

runner.run_steps(steps)
