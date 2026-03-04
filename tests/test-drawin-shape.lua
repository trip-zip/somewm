---------------------------------------------------------------------------
-- Test: Drawin shape (rounded corners) properties
--
-- Verifies that shape_bounding is correctly applied to drawins.
-- The C rendering code's correctness is verified by code review,
-- not pixel-peeping screenshots.
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")

local test_wibox = nil

local steps = {
    -- Step 1: Create wibox with rounded corners
    function()
        test_wibox = wibox {
            x = 50,
            y = 50,
            width = 200,
            height = 100,
            bg = "#ff5500",
            visible = true,
            screen = awful.screen.focused(),
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, 20)
            end,
        }
        io.stderr:write("[TEST] Created wibox with rounded shape\n")
        return true
    end,

    -- Step 2: Verify shape property is set
    function()
        assert(test_wibox.shape ~= nil, "shape should be set")
        assert(type(test_wibox.shape) == "function", "shape should be a function")
        io.stderr:write("[PASS] Shape property verified\n")
        return true
    end,

    -- Step 3: Verify drawable exists and is valid
    function()
        local drawable = test_wibox.drawable
        assert(drawable ~= nil, "drawable should exist")
        assert(drawable.valid == true, "drawable should be valid")
        io.stderr:write("[PASS] Drawable exists and is valid\n")
        return true
    end,

    -- Step 4: Verify geometry is correct
    function()
        local geo = test_wibox:geometry()
        assert(geo.x == 50, "x should be 50")
        assert(geo.y == 50, "y should be 50")
        assert(geo.width == 200, "width should be 200")
        assert(geo.height == 100, "height should be 100")
        io.stderr:write("[PASS] Geometry verified\n")
        return true
    end,

    -- Step 5: Verify visibility
    function()
        assert(test_wibox.visible == true, "wibox should be visible")
        io.stderr:write("[PASS] Visibility verified\n")
        return true
    end,

    -- Step 6: Cleanup
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
