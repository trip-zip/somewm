-- Test container boxes and pixels, including shapes and surface backgrounds.
--
-- Run: make test-one TEST=tests/test-clay-widget-containers.lua

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local cairo = require("lgi").cairo
local gshape = require("gears.shape")

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 200, 40
local OUTER, INNER, BORDER, RADIUS = 4, 6, 2, 12
local BAR_BG, BOX_BG, BORDER_COLOR = "#101010", "#204080", "#ff8000"

local cap = capture.new(s, BX, BY, BW, BH)
local bar, box, captured, shaped

local steps = {
    -- A wibox built with a shape, the way awful.wibar applies the theme's
    -- wibar_shape: the shape lands before the drawin is visible, which is
    -- before it enters the object registry. A rounded rectangle converts,
    -- with the radius on the root element.
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
        if #awesome._test_widget_boxes(shaped.drawin) > 0 then
            local d = shaped.drawin
            local line = awesome._clay_tree(s):match(string.format(
                "  drawin screen %d %dx%d%%+%d%%+%d [^\n]*", s.index,
                d.width, d.height, d.x, d.y))

            assert(line and line:find("radius 4", 1, true),
                "the rounded wibox has no radius: " .. tostring(line))
            shaped.visible = false
            io.stderr:write("[PASS] a wibox born rounded converts\n")
            return true
        end
        assert(count < 20, "a rounded wibox never converted")
    end,

    function(count)
        if count == 1 then
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH,
                visible = true, screen = s, bg = BAR_BG,
            }
            box = wibox.widget {
                widget = wibox.container.background,
                bg = BOX_BG,
                border_width = BORDER,
                border_color = BORDER_COLOR,
                {
                    widget = wibox.container.margin,
                    margins = INNER,
                    capture.leaf_widget(math.huge, nil, "#ff0000"),
                },
            }
            bar:setup {
                widget = wibox.container.margin,
                margins = OUTER,
                box,
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

    -- A rounded shape on the background, drawn the way a theme draws one
    -- (a function calling gears.shape.rounded_rect), is read for its
    -- radius, and the chain under it still converts: the renderer cuts what
    -- the children draw to the arc, as the container's own clip did. The
    -- leaf goes to the corner to be cut.
    function(count)
        if count == 1 then
            box.border_width = 0
            box.widget.margins = 0
            box.shape = function(cr, w, h)
                gshape.rounded_rect(cr, w, h, RADIUS)
            end
            return nil
        end

        local shot = cap:shot()

        if cap:pixel(shot, OUTER, OUTER) ~= 0x10 then
            assert(count < 20, "the rounded background never drew")
            return nil
        end
        assert(#awesome._test_widget_boxes(bar.drawin) == 5,
            "a rounded background put its subtree on cairo")
        cap:assert_pixel(shot, OUTER + 2, OUTER + 2, BAR_BG,
            "the leaf's corner past the arc")
        cap:assert_pixel(shot, OUTER + RADIUS, OUTER, "#ff0000",
            "the leaf's top edge inside the arc")
        cap:assert_pixel(shot, OUTER, OUTER + RADIUS, "#ff0000",
            "the leaf's left edge inside the arc")
        io.stderr:write("[PASS] a rounded background cuts its children to the arc\n")
        return true
    end,

    -- With nothing filling it, the shape still cuts: the unfocused item of a
    -- tasklist is one of these. The leaf covers the box, so nothing on
    -- screen says when the fill went; two frames is more than it takes.
    function(count)
        if count == 1 then
            box.bg = nil
            return nil
        end
        if count < 3 then
            return nil
        end

        local shot = cap:shot()

        assert(#awesome._test_widget_boxes(bar.drawin) == 5,
            "an unfilled rounded background put its subtree on cairo")
        cap:assert_pixel(shot, OUTER + 2, OUTER + 2, BAR_BG,
            "the leaf's corner past the arc, unfilled")
        cap:assert_pixel(shot, OUTER + RADIUS, OUTER, "#ff0000",
            "the leaf's top edge inside the arc, unfilled")
        io.stderr:write("[PASS] a rounded background with no fill still cuts\n")
        return true
    end,

    -- A rounded shape with a border keeps the background and its subtree.
    function(count)
        if count == 1 then
            box.bg = BOX_BG
            box.border_width = BORDER
            box.widget.margins = INNER
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 5 then
            io.stderr:write("[PASS] a rounded shape with a border converts\n")
            box.shape = nil
            return true
        end
        assert(count < 20, "the background with a rounded shape and border did not convert")
    end,

    function(count)
        if #awesome._test_widget_boxes(bar.drawin) == 5 then
            return true
        end
        assert(count < 20, "dropping the shape did not convert the background again")
    end,

    -- A hexagon draws unshaped: the tree stays converted and its pixels
    -- match the unshaped bar.
    function(count)
        if count == 1 then
            bar.shape = gshape.hexagon
            return nil
        end
        assert(#awesome._test_widget_boxes(bar.drawin) == 5,
            "a hexagon put the drawable back on cairo")
        return cap:compare(count, captured, "a hexagon drawn unshaped")
    end,

    function()
        bar.shape = nil
        return true
    end,

    -- A transparent surface bgimage keeps the widget tree visible.
    function(count)
        if count == 1 then
            bar.bgimage = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
            return nil
        end
        assert(#awesome._test_widget_boxes(bar.drawin) == 5, "bgimage changed the widget count")
        assert(awesome._clay_tree(s):find(" image ", 1, true), "bgimage has no image node")
        return cap:compare(count, captured, "a background image")
    end,

    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
