---------------------------------------------------------------------------
-- Test: drawin shape masks accept both A1 and ARGB32 surfaces.
--
-- somewm's own wibox:_apply_shape and awful.mouse.snap build masks in
-- cairo.Format.ARGB32 for anti-aliased edges, while AwesomeWM's
-- _apply_shape and gears.surface.apply_shape_bounding build them in
-- cairo.Format.A1. A1 rows are ~32x smaller, so reading one as the
-- other walks off the end of the buffer.
--
-- Under ASAN a reader that assumes a single format aborts here; a
-- format-aware one survives every producer.
---------------------------------------------------------------------------

local runner   = require("_runner")
local awful    = require("awful")
local wibox    = require("wibox")
local gears    = require("gears")
local gsurface = require("gears.surface")
local cairo    = require("lgi").cairo

local test_wibox

local function build_a1(width, height)
    local img = cairo.ImageSurface.create(cairo.Format.A1, width, height)
    local cr  = cairo.Context.create(img)
    cr:set_source_rgba(1, 1, 1, 1)
    gears.shape.rounded_rect(cr, width, height, 20)
    cr:set_operator(cairo.Operator.SOURCE)
    cr:fill()
    return img
end

-- Give the compositor a few frames to run the mask reader, then check the
-- wibox came through it. Under ASAN a mis-read mask aborts before this.
local function settle(msg)
    return function(count)
        if count >= 3 then
            assert(test_wibox.valid, msg)
            return true
        end
    end
end

local steps = {
    -- Step 1: a shaped wibox. somewm's _apply_shape builds ARGB32 masks,
    -- so this covers the anti-aliased path.
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
        return true
    end,

    settle("wibox should survive ARGB32 shape masks"),

    -- Step 2: gears.surface.apply_shape_bounding is public API and builds
    -- an A1 surface, so it reaches the C reader without any override.
    function()
        gsurface.apply_shape_bounding(test_wibox, function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, 20)
        end)
        return true
    end,

    settle("wibox should survive gears.surface.apply_shape_bounding (A1)"),

    -- Step 3: A1 assigned straight to shape_bounding / shape_clip, as a
    -- config overriding _apply_shape with AwesomeWM's version would.
    function()
        local bw  = test_wibox.border_width or 0
        local geo = test_wibox:geometry()

        test_wibox.shape_bounding =
            build_a1(geo.width + 2 * bw, geo.height + 2 * bw)._native
        test_wibox.shape_clip = build_a1(geo.width, geo.height)._native
        return true
    end,

    settle("wibox should survive directly assigned A1 shape masks"),

    -- Step 4: clearing after real A1 surfaces were held catches lifetime
    -- regressions in the nil path of the shape setters.
    function()
        test_wibox.shape_bounding = nil
        test_wibox.shape_clip = nil
        return true
    end,

    settle("wibox should survive clearing shape masks"),

    function()
        if test_wibox then
            test_wibox.visible = false
            test_wibox = nil
        end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
