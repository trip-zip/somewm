---------------------------------------------------------------------------
--- Pointer target scenarios: the windows change while the pointer is still.
---
--- 10. a window is raised under the pointer, then a press with no motion
--- 11. the top window closes under the pointer, then a press with no motion
--- 12. a new window maps under the pointer, below an ontop window
---
--- The press is injected without any motion, so the compositor has to have
--- moved pointer focus on its own when the windows changed
--- (tests/_pointer_probe.lua).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local probe  = require("_pointer_probe")

if probe.missing() then return end

local BIG, SMALL = probe.BIG, probe.SMALL

runner.run_async(function()
    probe.bind_click_to_activate()

    probe.scenario(10, "window raised under a still pointer", function()
        local small = probe.wayland("s10_small", SMALL)
        local big = probe.wayland("s10_big", BIG)
        probe.raise_over(big, small)
        local x, y = probe.center(small)
        probe.move(x, y)
        assert(probe.wait_for(big, "^enter "), "the window on top never got the pointer")
        probe.raise_over(small, big)
        return probe.expect_press(probe.button, small)
    end)

    probe.scenario(11, "top window closes under a still pointer", function()
        local big = probe.wayland("s11_big", BIG)
        local small = probe.wayland("s11_small", SMALL)
        probe.raise_over(small, big)
        local x, y = probe.center(small)
        probe.move(x, y)
        assert(probe.wait_for(small, "^enter "), "the window on top never got the pointer")
        local c = small.c
        c:kill()
        assert(async.wait_for_condition(function() return not c.valid end, 5),
            "the top window did not close")
        async.sleep(0.2)
        return probe.expect_press(probe.button, big)
    end)

    probe.scenario(12, "new window maps under the pointer, below an ontop window", function()
        local top = probe.wayland("s12_ontop", SMALL)
        top.c.ontop = true
        async.sleep(0.2)
        local x, y = probe.center(top)
        probe.move(x, y)
        assert(probe.wait_for(top, "^enter "), "the ontop window never got the pointer")
        local new = probe.wayland("s12_new", BIG)
        async.sleep(0.3)
        local ok, detail = probe.expect_press(probe.button, top)
        local leaked = probe.count(new, "^enter ")
        return ok and leaked == 0, string.format("%s, pointer enters sent to the new window: %d",
            detail, leaked)
    end)

    probe.finish()
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
