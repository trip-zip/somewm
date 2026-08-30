---------------------------------------------------------------------------
-- Test: a bare dirty mark on an idle session produces a frame
--
-- The Clay frame loop only rebuilds an output's tree inside the
-- wlr_output.events.frame handler, and only when the output was marked
-- dirty. A geometry change that redraws no drawable (moving a wibox) is a
-- pure declare_output_mark_dirty(); the mark must wake the poll and reach a
-- presented frame with no input and no client traffic, or the move is
-- invisible until unrelated fd activity wakes the loop.
--
-- Presents are observed via awesome._test_frame_count, the same hook as
-- tests/test-widget-idle-repaint.lua, and the same quiescence discipline
-- applies: measure only after the frame loop has gone quiet.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful  = require("awful")
local wibox  = require("wibox")

local wb
local baseline

local last_count, stable_samples = nil, 0

local steps = {
    -- Step 1: show a wibox, then wait for the frame loop to go idle (frame
    -- count unchanged across several 0.1s samples).
    function(count)
        if count == 1 then
            wb = wibox {
                x = 0, y = 0, width = 120, height = 24,
                bg = "#000000", visible = true,
                screen = awful.screen.focused(),
            }
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

        if stable_samples >= 3 and now > 0 then
            return true
        end
        return nil
    end,

    -- Step 2: move the wibox. This redraws nothing; it only marks the
    -- output dirty. The next frames must present the move.
    function(count)
        if count == 1 then
            baseline = awesome._test_frame_count
            wb.x = wb.x + 10
            return nil
        end

        if awesome._test_frame_count > baseline then
            io.stderr:write("[PASS] dirty mark on an idle session presented a frame\n")
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

-- Meaningful only on the headless backend: a nested parent compositor keeps
-- the Wayland fd busy and would drain a stranded frame idle, masking the
-- bug (same reasoning as test-widget-idle-repaint.lua).
if not (os.getenv("WLR_BACKENDS") or ""):find("headless", 1, true) then
    runner.run_direct()
    io.stderr:write("[SKIP] test-declare-dirty-mark: needs the headless backend "
        .. "(HEADLESS=1); a nested parent compositor masks the bug under test.\n")
    runner.done()
    return
end

runner.run_steps(steps)
