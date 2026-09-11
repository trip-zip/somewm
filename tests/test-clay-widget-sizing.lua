---------------------------------------------------------------------------
-- Test: Clay is the only solver of a converted tree
--
-- `somewm-client clay tree` prints a sizing column per node, one axis each
-- for w= and h=. `fit` and `grow` (Clay's CLAY_SIZING_FIT and
-- CLAY_SIZING_GROW) mean Clay decided the size; a number is
-- CLAY_SIZING_FIXED, which means something else decided and Clay was told.
--
-- Fixed sizes name the drawin geometry, leaf preferences and forced sizes.
-- The four described leaves retain those sizes in the solved box readback.
--
-- Run: make test-one TEST=tests/test-clay-widget-sizing.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")

local s = screen[1]
local leaf_widget = capture.leaf_widget
local bar

-- The dump block for the bar: the drawin line and the tree nodes under it.
local function block()
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, nodes = nil, {}

    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if head then
            local indent, class, w, h = line:match(
                "^    %x+ ( *)([%w_.-]+).- w=(%S+) h=(%S+)")
            if not indent then
                break
            end
            nodes[#nodes + 1] = {
                depth = #indent / 2, class = class, w = w, h = h,
                line = line,
            }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, nodes
end

local steps = {
    function(count)
        if count == 1 then
            -- The bundled bar's shape, unshaped, plus one container with a
            -- forced size.
            bar = wibox {
                x = 0, y = 0, width = 400, height = 24, screen = s,
                bg = "#101010", visible = true,
            }
            bar:setup {
                layout = wibox.layout.stack,
                {
                    layout = wibox.layout.align.horizontal,
                    {
                        layout = wibox.layout.fixed.horizontal,
                        spacing = 6,
                        leaf_widget(40, nil, "#ff0000"),
                        {
                            leaf_widget(math.huge, nil, "#00ff00"),
                            forced_width = 100,
                            widget = wibox.container.margin,
                        },
                    },
                    { widget = wibox.container.background, bg = "#204080" },
                    {
                        layout = wibox.layout.fixed.horizontal,
                        leaf_widget(30, nil, "#0000ff"),
                    },
                },
                {
                    {
                        { leaf_widget(70, 16, "#00ffff"), margins = 4,
                            widget = wibox.container.margin },
                        bg = "#204080",
                        widget = wibox.container.background,
                    },
                    halign = "center",
                    widget = wibox.container.place,
                },
            }
            return nil
        end

        local head, nodes = block()

        if not head or (head:find("converted", 1, true) and #nodes == 0) then
            assert(count < 20, "the bar never reached the dump: "
                .. tostring(head))
            return nil
        end
        assert(head:find("converted", 1, true),
            "the bar did not convert: " .. head)

        local boxes = awesome._test_widget_boxes(bar.drawin)
        for i, want in ipairs {
            { index = 5, width = 40, height = 24 },
            { index = 7, width = 100, height = 24 },
            { index = 10, width = 30, height = 24 },
            { index = 14, width = 70, height = 16 },
        } do
            local box = boxes[want.index]
            assert(box and box.width == want.width and box.height == want.height,
                "unexpected leaf box " .. i)
        end
        io.stderr:write("[PASS] Clay sizes every node it can\n")
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
