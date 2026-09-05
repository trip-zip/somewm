-- Test: margin and background containers convert to Clay declarations, and a
-- wibar drawn that way is pixel-identical to the same wibar painted whole.
--
-- Two things are checked. First, the boxes Clay solves for the converted
-- chain, read back through awesome._test_widget_boxes(). Second, that the
-- screen looks the same either way: setting a bgimage puts the drawable back on the path where
-- cairo paints every pixel (lua/wibox/clay.lua refuses a background image),
-- so the same tree renders twice, once converted and once whole, and the two
-- captures have to agree.
--
-- Run: make test-one TEST=tests/test-clay-widget-containers.lua

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local cairo = require("lgi").cairo
local gshape = require("gears.shape")

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 200, 40
local OUTER, INNER, BORDER = 4, 6, 2
local BAR_BG, BOX_BG, BORDER_COLOR = "#101010", "#204080", "#ff8000"

local cap = capture.new(s, BX, BY, BW, BH)
local bar, captured, shaped

-- A step that runs `setup` once and then waits for the readback to say the
-- tree did or did not convert.
local function step_until(converted, setup, what)
    return capture.step_until(function() return bar end, converted, setup, what)
end

local steps = {
    -- A wibox built with a shape, the way awful.wibar applies the theme's
    -- wibar_shape: the shape lands before the drawin is visible, which is
    -- before it enters the object registry, so the renderer cannot reach it
    -- by pointer there. It has to paint whole, and it has to survive.
    function(count)
        if count == 1 then
            shaped = wibox {
                x = BX, y = BY + BH + 10, width = BW, height = BH,
                visible = false, screen = s, bg = BAR_BG,
            }
            shaped:setup {
                widget = wibox.container.margin,
                margins = OUTER,
                capture.leaf_widget(math.huge, nil, "#ff0000"),
            }
            -- Shaped before it is ever visible, which is before the drawin
            -- enters the object registry.
            shaped.shape = function(cr, w, h)
                gshape.rounded_rect(cr, w, h, 4)
            end
            shaped.visible = true
            return nil
        end
        assert(#awesome._test_widget_boxes(shaped.drawin) == 0,
            "a shaped wibox converted")
        if count > 3 then
            shaped.visible = false
            io.stderr:write("[PASS] a wibox born shaped paints whole\n")
            return true
        end
    end,

    function(count)
        if count == 1 then
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH,
                visible = true, screen = s, bg = BAR_BG,
            }
            bar:setup {
                widget = wibox.container.margin,
                margins = OUTER,
                {
                    widget = wibox.container.background,
                    bg = BOX_BG,
                    border_width = BORDER,
                    border_color = BORDER_COLOR,
                    {
                        widget = wibox.container.margin,
                        margins = INNER,
                        capture.leaf_widget(math.huge, nil, "#ff0000"),
                    },
                },
            }
        end
        if #awesome._test_widget_boxes(bar.drawin) > 0 then
            return true
        end
        assert(count < 20, "the widget tree never converted")
    end,

    -- Clay's boxes for the chain.
    function()
        local boxes = awesome._test_widget_boxes(bar.drawin)

        local assert_box = capture.assert_box

        assert(#boxes == 5, "expected five nodes, got " .. #boxes)
        assert_box(boxes[1], { x = 0, y = 0, width = BW, height = BH },
            "the drawable's own background")
        assert_box(boxes[2], { x = 0, y = 0, width = BW, height = BH },
            "the outer margin")
        assert_box(boxes[3], { x = OUTER, y = OUTER,
            width = BW - 2 * OUTER, height = BH - 2 * OUTER }, "the background")
        assert_box(boxes[4], { x = OUTER, y = OUTER,
            width = BW - 2 * OUTER, height = BH - 2 * OUTER },
            "the inner margin")
        assert_box(boxes[5], { x = OUTER + INNER, y = OUTER + INNER,
            width = BW - 2 * (OUTER + INNER),
            height = BH - 2 * (OUTER + INNER) }, "the raster leaf")
        io.stderr:write("[PASS] Clay solves the chain\n")
        return true
    end,

    -- What the converted chain draws.
    function()
        local shot = cap:shot()

        cap:assert_pixel(shot, 1, 1, BAR_BG, "the drawable's own background")
        cap:assert_pixel(shot, OUTER + 1, OUTER + 1, BORDER_COLOR,
            "the background's border")
        cap:assert_pixel(shot, OUTER + BORDER + 2, OUTER + BORDER + 2, BOX_BG,
            "the background's fill")
        cap:assert_pixel(shot, math.floor(BW / 2), math.floor(BH / 2), "#ff0000",
            "the raster leaf")
        captured = shot
        io.stderr:write("[PASS] the converted chain draws where it should\n")
        return true
    end,

    -- The same tree painted whole. A shape puts the drawable back on the
    -- path where cairo paints every pixel, because the mask applies to those
    -- pixels; a full-rectangle shape masks nothing away.
    step_until(false, function() bar.shape = gshape.rectangle end,
        "a shape did not put the drawable back on cairo"),

    function(count)
        return cap:compare(count, captured, "a shaped drawable")
    end,

    -- And a background image, the other thing the chain cannot carry.
    step_until(true, function() bar.shape = nil end,
        "dropping the shape did not convert the tree again"),

    step_until(false, function()
        bar.bgimage = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
    end, "a background image did not put the drawable back"),

    function(count)
        return cap:compare(count, captured, "a background image")
    end,

    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
