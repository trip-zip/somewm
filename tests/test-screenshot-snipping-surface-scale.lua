-- Test: awful.screenshot{interactive=true} sets surface_scale=1.0 on its
-- snipping wibox. Without this, the overlay repaints at physical resolution
-- on every mousemove and drops to ~1 FPS at HiDPI.

local awful  = require("awful")
local runner = require("_runner")

local steps = {
    function()
        screen[1].scale = 1.5
        return true
    end,

    function()
        local ss = awful.screenshot {
            interactive = true,
            screen      = screen[1],
        }
        ss:refresh()

        local frame = ss._private.frame
        assert(frame, "snipping frame wibox was not created")
        assert(frame.surface_scale == 1.0,
            "expected frame.surface_scale=1.0, got " .. tostring(frame.surface_scale))

        ss:reject("test_done")
        return true
    end,
}

runner.run_steps(steps)
