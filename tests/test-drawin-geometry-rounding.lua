---------------------------------------------------------------------------
-- Test: Drawin geometry rounding (fractional coordinates)
--
-- Verifies that fractional geometry values are correctly rounded:
--   x, y   → round()  (C99 round, away from zero at .5)
--   w, h   → ceil()   (C99 ceil, always rounds up)
--
-- Regression test for #200.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local test_wibox = nil

local steps = {
    -- Step 1: Create wibox for testing
    function()
        test_wibox = wibox {
            x = 100,
            y = 100,
            width = 200,
            height = 100,
            visible = true,
            screen = awful.screen.focused(),
        }
        assert(test_wibox, "wibox creation failed")
        return true
    end,

    -- Step 2: Test geometry table setter with fractional values
    function()
        test_wibox:geometry({
            x = 10.7,
            y = 10.3,
            width = 100.1,
            height = 100.9,
        })

        local geo = test_wibox:geometry()
        assert(geo.x == 11, "x: expected 11 (round 10.7), got " .. geo.x)
        assert(geo.y == 10, "y: expected 10 (round 10.3), got " .. geo.y)
        assert(geo.width == 101, "width: expected 101 (ceil 100.1), got " .. geo.width)
        assert(geo.height == 101, "height: expected 101 (ceil 100.9), got " .. geo.height)
        io.stderr:write("[PASS] Geometry table setter rounding\n")
        return true
    end,

    -- Step 3: Test property setters with fractional values
    function()
        test_wibox.x = 20.5
        test_wibox.y = -3.7
        test_wibox.width = 50.01
        test_wibox.height = 200.0

        local geo = test_wibox:geometry()
        assert(geo.x == 21, "x: expected 21 (round 20.5), got " .. geo.x)
        assert(geo.y == -4, "y: expected -4 (round -3.7), got " .. geo.y)
        assert(geo.width == 51, "width: expected 51 (ceil 50.01), got " .. geo.width)
        assert(geo.height == 200, "height: expected 200 (ceil 200.0), got " .. geo.height)
        io.stderr:write("[PASS] Property setter rounding\n")
        return true
    end,

    -- Step 4: Cleanup
    function()
        if test_wibox then
            test_wibox.visible = false
            test_wibox = nil
        end
        io.stderr:write("[TEST] Cleanup complete\n")
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
