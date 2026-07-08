---------------------------------------------------------------------------
--- Test that a timer armed during the refresh cycle fires on an idle session.
---
--- gears.timer delayed calls run from the "refresh" signal, which the
--- compositor emits while preparing to sleep. A timer armed there used to be
--- invisible to the poll timeout the event loop had already computed, so on
--- an idle session (no input, no client traffic) it never fired until an
--- unrelated event woke the loop. This stranded every _async wait between
--- steps and froze rc.lua timers armed from delayed_call context.
---
--- The chain below reproduces it: the outer timer fires in the dispatch
--- phase and queues a delayed call; the delayed call runs during refresh and
--- arms the inner timer there, with no other event-loop activity left.
--- Without the fix the inner timer never fires and the test times out.
---------------------------------------------------------------------------

local runner = require("_runner")
local timer = require("gears.timer")

runner.run_direct()

timer.start_new(1.0, function()
    timer.delayed_call(function()
        local armed_at = os.time()
        timer.start_new(0.5, function()
            -- A rescue event (like the harness SIGTERM at timeout) can fire a
            -- stranded timer late, so completing is not enough: it must fire
            -- close to its deadline.
            local elapsed = os.time() - armed_at
            if elapsed > 5 then
                runner.done(string.format(
                    "timer armed during refresh was stranded for %d seconds", elapsed))
            else
                runner.done()
            end
            return false
        end)
    end)
    return false
end)
