---------------------------------------------------------------------------
-- Test: wibox shape_bounding/shape_clip accept AwesomeWM-style A1 surfaces.
--
-- Regression guard: somewm's _apply_shape creates shape surfaces in
-- cairo.Format.ARGB32 (for anti-aliased borders), but upstream AwesomeWM
-- uses cairo.Format.A1. Users who override _apply_shape with the upstream
-- version (or who assign shape_bounding/shape_clip directly from A1
-- surfaces) trigger a heap-buffer-overflow in drawin_apply_shape_mask
-- because the C renderer assumes ARGB32 stride and byte-3 alpha.
--
-- This test feeds A1 shape surfaces to a live wibox and forces a refresh
-- cycle. Under ASAN, the pre-fix renderer reads past the end of the A1
-- buffer and the test aborts; after the fix, the wibox survives.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful  = require("awful")
local wibox  = require("wibox")
local gears  = require("gears")
local cairo  = require("lgi").cairo

local test_wibox

local steps = {
    -- Step 1: create a wibox with a rounded shape.
    function()
        test_wibox = wibox {
            x = 50, y = 50,
            width = 200, height = 100,
            bg = "#335588",
            visible = true,
            screen = awful.screen.focused(),
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, 20)
            end,
        }
        io.stderr:write("[TEST] Created wibox with rounded shape\n")
        return true
    end,

    -- Step 2: overwrite shape_bounding / shape_clip with A1 surfaces.
    function()
        local bw  = test_wibox.border_width or 0
        local geo = test_wibox:geometry()
        local tw, th = geo.width + 2 * bw, geo.height + 2 * bw

        local function build_a1(width, height)
            local img = cairo.ImageSurface.create(cairo.Format.A1, width, height)
            local cr  = cairo.Context.create(img)
            cr:set_source_rgba(1, 1, 1, 1)
            gears.shape.rounded_rect(cr, width, height, 20)
            cr:set_operator(cairo.Operator.SOURCE)
            cr:fill()
            return img
        end

        local bounding = build_a1(tw, th)
        test_wibox.shape_bounding = bounding._native

        local clip = build_a1(geo.width, geo.height)
        test_wibox.shape_clip = clip._native

        io.stderr:write("[TEST] Assigned A1 shape_bounding and shape_clip\n")
        return true
    end,

    -- Step 3: give the compositor a frame to run drawin_apply_shape_mask.
    function(count)
        if count >= 3 then return true end
    end,

    -- Step 4: the wibox should still be valid (no crash, no corruption).
    function()
        assert(test_wibox.valid,
            "wibox should survive A1 shape assignment without crashing")
        io.stderr:write("[PASS] Wibox survived A1 shape mask rendering\n")
        return true
    end,

    -- Step 5: clear both shape surfaces and let the compositor refresh.
    -- Exercises the nil path in luaA_drawin_set_shape_{bounding,clip}
    -- after real A1 surfaces have been held, catching lifetime regressions.
    function()
        test_wibox.shape_bounding = nil
        test_wibox.shape_clip = nil
        io.stderr:write("[TEST] Cleared A1 shape surfaces\n")
        return true
    end,

    function(count)
        if count >= 2 then return true end
    end,

    function()
        assert(test_wibox.valid,
            "wibox should survive clearing A1 shape surfaces")
        io.stderr:write("[PASS] Wibox survived shape clear\n")
        return true
    end,

    -- Final step: cleanup.
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
