---------------------------------------------------------------------------
-- Test: widgets repaint on a timer with no input (issue #609)
--
-- A gears.timer-driven widget update (textclock, awful.widget.watch, ...) must
-- reach the screen even when nothing is focused and no input arrives. The redraw
-- path ends in wlr_output_schedule_frame(), which queues the frame as a
-- wl_event_loop idle; that idle only runs inside wl_event_loop_dispatch(). The
-- compositor's poll function (some_glib_poll) must dispatch the wl event loop
-- every iteration, otherwise the idle is stranded until unrelated fd traffic
-- (input, a client commit) wakes the loop, and the widget freezes.
--
-- We observe presents via awesome._test_frame_count (incremented in rendermon
-- after each successful wlr_scene_output_commit).
--
-- Reliability note: the assertion needs a quiescent window with no fd traffic
-- between the update and the present, since any traffic would flush the stranded
-- idle and mask the bug. The runner steps via gears.timer (a GLib timeout, which
-- does not touch the Wayland fd), and we first wait for the frame loop to go
-- quiet, so a headless run with no clients reproduces the freeze. A nested
-- backend with a busy parent can still mask it; the authoritative check is the
-- manual one in the issue.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful  = require("awful")
local wibox  = require("wibox")

local wb, tb
local baseline

-- Quiescence tracking for step 1.
local last_count, stable_samples = nil, 0

local steps = {
    -- Step 1: show a wibox with a textbox, then wait for the initial render and
    -- for the frame loop to go idle (frame count unchanged across several 0.1s
    -- samples). This guarantees step 2 measures from a quiet state.
    function(count)
        if count == 1 then
            tb = wibox.widget.textbox("init")
            wb = wibox {
                x = 0, y = 0, width = 120, height = 24,
                bg = "#000000", visible = true,
                screen = awful.screen.focused(),
            }
            wb.widget = tb
            last_count, stable_samples = nil, 0
            return nil
        end

        local now = awesome._test_frame_count
        if last_count ~= nil and now == last_count then
            stable_samples = stable_samples + 1
        else
            stable_samples = 0
        end
        last_count = now

        -- ~0.3s of no new frames, and at least one frame already presented.
        if stable_samples >= 3 and now > 0 then
            return true
        end
        return nil
    end,

    -- Step 2: with the session idle (no input, no clients, no IPC in flight),
    -- update the widget. On a fixed build the frame is presented within an
    -- iteration or two; on a broken build the count never moves and the step
    -- times out (the frozen-widget bug).
    function(count)
        if count == 1 then
            baseline = awesome._test_frame_count
            tb.text = "updated"
            return nil
        end

        if awesome._test_frame_count > baseline then
            io.stderr:write("[PASS] timer-driven redraw presented with no input\n")
            return true
        end
        return nil
    end,

    -- Cleanup.
    function()
        if wb then
            wb.visible = false
            wb = nil
        end
        return true
    end,
}

-- This regression only reproduces on a quiescent session: any Wayland-fd traffic
-- (a nested parent compositor's frame callbacks, a client commit, input) drains
-- the stranded frame idle and would mask the freeze. Under the nested wayland
-- backend (the default for `make test-one`) the parent keeps the fd busy, so the
-- check is only meaningful on the headless backend (HEADLESS=1, as CI runs it).
-- Skip elsewhere rather than pass without actually exercising the bug.
if not (os.getenv("WLR_BACKENDS") or ""):find("headless", 1, true) then
    runner.run_direct()
    io.stderr:write("[SKIP] test-widget-idle-repaint: needs the headless backend "
        .. "(HEADLESS=1); a nested parent compositor masks the bug under test.\n")
    runner.done()
    return
end

runner.run_steps(steps)
