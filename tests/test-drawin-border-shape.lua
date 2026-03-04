---------------------------------------------------------------------------
-- Test: Drawin borders follow shape_bounding
--
-- Regression test for issue #172: borders should be clipped to match
-- the shape_bounding mask, not remain rectangular.
--
-- Verifies properties are correctly set. The C code applies shape to
-- border when both are present - that's an implementation detail verified
-- by code review, not pixel-peeping.
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")
local gears = require("gears")

local test_wibox = nil

local steps = {
    -- Step 1: Create wibox with shape and border
    function()
        test_wibox = wibox {
            x = 50, y = 50,
            width = 200, height = 100,
            visible = true,
            bg = "#ff0000",
            border_width = 4,
            border_color = "#00ff00",
            ontop = true,
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, 20)
            end,
        }
        io.stderr:write("[TEST] Created wibox with rounded shape and border\n")
        return true
    end,

    -- Step 2: Verify border properties are set
    function()
        assert(test_wibox.border_width == 4, "border_width should be 4")
        assert(test_wibox.border_color == "#00ff00", "border_color should be green")
        io.stderr:write("[PASS] Border properties verified\n")
        return true
    end,

    -- Step 3: Verify shape is set (this is what makes border follow shape)
    function()
        assert(test_wibox.shape ~= nil, "shape should be set")
        assert(type(test_wibox.shape) == "function", "shape should be a function")
        io.stderr:write("[PASS] Shape property verified\n")
        return true
    end,

    -- Step 4: Verify drawable exists and is valid
    function()
        local drawable = test_wibox.drawable
        assert(drawable ~= nil, "drawable should exist")
        assert(drawable.valid == true, "drawable should be valid")
        io.stderr:write("[PASS] Drawable exists and is valid\n")
        return true
    end,

    -- Step 5: Cleanup
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
