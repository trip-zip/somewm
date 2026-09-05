-- Test: the bundled bar's layouts convert to Clay declarations and draw what
-- the layout engine draws.
--
-- The tree is the shape of somewmrc.lua's wibar: a stack of an align of two
-- fixed layouts and a background, and a centered place, with a widget the
-- compile step can never convert standing in for every textbox and imagebox.
-- Four things are checked: the tree converts; Clay's boxes, read back
-- through awesome._test_widget_boxes(), are where the engine used to put
-- the same widgets; the pointer over a gap between two leaves still reaches
-- the wibox; and the screen looks the same converted as it
-- does painted whole (a shape puts the drawable back on the path where cairo
-- paints every pixel, and a full-rectangle shape masks nothing away).
--
-- Run: make test-one TEST=tests/test-clay-widget-layouts.lua

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local gshape = require("gears.shape")

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 400, 24
local GAP = 6
local BAR_BG, MID_BG = "#101010", "#204080"

local cap = capture.new(s, BX, BY, BW, BH)
local leaf_widget, assert_box = capture.leaf_widget, capture.assert_box
local bar, captured

-- Every leaf's own color, well inside its box, plus the gap between two of
-- them: what the bar looks like whichever path drew it.
local function assert_bar(shot, what)
    cap:assert_pixel(shot, 20, 12, "#ff0000", what .. ": the first leaf")
    cap:assert_pixel(shot, 43, 12, BAR_BG, what .. ": the gap between leaves")
    cap:assert_pixel(shot, 100, 12, "#00ff00", what .. ": the second leaf")
    cap:assert_pixel(shot, 200, 2, MID_BG, what .. ": the middle background")
    cap:assert_pixel(shot, 200, 12, "#00ffff", what .. ": the clock")
    cap:assert_pixel(shot, 340, 12, "#ffff00", what .. ": the right fixed")
    cap:assert_pixel(shot, 390, 12, "#ff00ff", what .. ": the last leaf")
end

local steps = {
    function(count)
        if count == 1 then
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH,
                visible = true, screen = s, bg = BAR_BG,
            }
            bar:setup {
                layout = wibox.layout.stack,
                {
                    layout = wibox.layout.align.horizontal,
                    {
                        layout = wibox.layout.fixed.horizontal,
                        spacing = GAP,
                        leaf_widget(40, nil, "#ff0000"),
                        leaf_widget(60, nil, "#00ff00"),
                        leaf_widget(30, nil, "#0000ff"),
                    },
                    { widget = wibox.container.background, bg = MID_BG },
                    {
                        layout = wibox.layout.fixed.horizontal,
                        leaf_widget(50, nil, "#ffff00"),
                        leaf_widget(24, nil, "#ff00ff"),
                    },
                },
                {
                    leaf_widget(70, 16, "#00ffff"),
                    halign = "center",
                    widget = wibox.container.place,
                },
            }
        end
        if #awesome._test_widget_boxes(bar.drawin) > 0 then
            return true
        end
        assert(count < 20, "the bar never converted")
    end,

    -- Clay's boxes: the drawable and twelve widgets, the stack's wrappers
    -- standing for none.
    function()
        local boxes = awesome._test_widget_boxes(bar.drawin)

        assert(#boxes == 13, #boxes .. " boxes, expected 13")
        assert_box(boxes[1], { x = 0, y = 0, width = BW, height = BH },
            "the drawable's own background")

        -- The shape: left fixed 40+6+60+6+30 wide, the background between,
        -- the right fixed 50+24 at the far edge, the clock centered.
        assert_box(boxes[4], { x = 0, y = 0, width = 142, height = BH }, "the left fixed")
        assert_box(boxes[8], { x = 142, y = 0, width = 184, height = BH }, "the middle")
        assert_box(boxes[9], { x = 326, y = 0, width = 74, height = BH }, "the right fixed")
        assert_box(boxes[13], { x = 165, y = 4, width = 70, height = 16 }, "the clock")
        io.stderr:write("[PASS] Clay solves the bar\n")
        return true
    end,

    -- What the converted tree draws.
    function()
        local shot = cap:shot()

        assert_bar(shot, "the converted tree")
        captured = shot
        io.stderr:write("[PASS] the converted tree draws where it should\n")
        return true
    end,

    -- The pointer over the gap between two leaves is over the wibox: the
    -- container behind the gap resolves to the drawin. Warped twice, since
    -- the hit test runs against the position before the move.
    function()
        mouse.coords({ x = BX + 43, y = BY + 12 })
        mouse.coords({ x = BX + 43, y = BY + 12 })

        local obj = mouse.object_under_pointer()

        assert(obj == bar.drawin, "over the gap: got " .. tostring(obj) .. ", want the wibox")
        io.stderr:write("[PASS] a gap between leaves reaches the wibox\n")
        mouse.coords({ x = 100, y = 100 })
        return true
    end,

    -- A button press lands on the converted widgets under the point, from
    -- the outermost in, with the point in each widget's own coordinates:
    -- find_widgets reads Clay's boxes, and a converted widget has no
    -- hierarchy to read.
    function()
        local middle = bar.widget:get_children()[1]:get_children()[2]
        local got

        middle:connect_signal("button::press", function(_, lx, ly, button, _, geo)
            got = { lx = lx, ly = ly, button = button, geo = geo }
        end)
        bar.drawin.drawable:emit_signal("button::press", 200, 12, 1, {})
        assert(got, "the middle background got no press")
        assert(got.lx == 58 and got.ly == 12, string.format(
            "the press landed at %d,%d in the middle, want 58,12", got.lx, got.ly))
        assert(got.geo.hierarchy == nil and got.geo.width == 184,
            "the middle's geometry is not Clay's box")

        -- Under the point: the stack, the align, the middle, then the place
        -- and the clock over them, the clock through its own hierarchy.
        local clock = bar.widget:get_children()[2]:get_children()[1]
        local under = bar._drawable:find_widgets(200, 12)

        assert(#under == 5, "find_widgets found " .. #under .. " widgets, want 5")
        assert(under[1].widget == bar.widget, "find_widgets did not start at the stack")
        assert(under[3].widget == middle, "the middle is not third")
        assert(under[5].widget == clock and under[5].hierarchy,
            "the clock is not last, with its hierarchy")
        io.stderr:write("[PASS] a press reaches the converted widgets under it\n")
        return true
    end,

    -- A settled bar re-declares to nothing.
    function()
        awesome._test_redeclare()

        local n = awesome._test_redeclare()

        assert(n == 0, "re-declaring the settled bar mutated " .. n .. " nodes")
        io.stderr:write("[PASS] an identical frame reconciles to 0 mutations\n")
        return true
    end,

    -- A refusal only the compile step sees: a fractional stack spacing is
    -- not a whole childGap, so nothing converts. Nothing asks for a
    -- complete repaint on that path, and this surface holds no pixels at
    -- all while the leaves are drawing, so it has to repaint every one.
    capture.step_until(function() return bar end, false,
        function() bar.widget.spacing = 0.5 end,
        "a fractional spacing did not put the drawable back on cairo"),

    function(count)
        if pcall(assert_bar, cap:shot(), "the whole-painted bar") then
            io.stderr:write("[PASS] leaving the converted path repaints whole\n")
            return true
        end
        assert(count < 20, "the bar has holes after it stopped converting")
    end,

    -- And back: the leaf surfaces are new, so every leaf paints whole even
    -- where the dirty region does not reach it.
    capture.step_until(function() return bar end, true,
        function() bar.widget.spacing = 0 end,
        "a whole spacing did not convert the tree again"),

    function(count)
        if pcall(assert_bar, cap:shot(), "the reconverted bar") then
            io.stderr:write("[PASS] returning to the tree paints every leaf\n")
            return true
        end
        assert(count < 20, "a leaf is blank after the tree converted again")
    end,

    -- The same tree painted whole.
    capture.step_until(function() return bar end, false,
        function() bar.shape = gshape.rectangle end,
        "a shape did not put the drawable back on cairo"),

    function(count)
        return cap:compare(count, captured, "a shaped drawable")
    end,

    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
