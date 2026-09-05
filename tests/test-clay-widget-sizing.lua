---------------------------------------------------------------------------
-- Test: Clay is the only solver of a converted tree
--
-- `somewm-client clay tree` prints a sizing column per node, one axis each
-- for w= and h=. `fit` and `grow` (Clay's CLAY_SIZING_FIT and
-- CLAY_SIZING_GROW) mean Clay decided the size; a number is
-- CLAY_SIZING_FIXED, which means something else decided and Clay was told.
--
-- A converted tree may carry a number only where Clay itself offers nothing
-- else: the drawin root, whose geometry rc.lua set; a raster leaf, whose
-- pixels Clay cannot measure (Clay_ImageElementConfig is a bare pointer,
-- clay.h), so it is declared at its own `:fit`; and a widget with a genuine
-- forced_width or forced_height.
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
                raster = line:find(" raster ", 1, true) ~= nil,
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

        local forced, rasters = 0, 0
        for _, node in ipairs(nodes) do
            local fixed_w, fixed_h = tonumber(node.w), tonumber(node.h)

            if node.depth == 0 then
                assert(fixed_w and fixed_h,
                    "the root is not the drawin's geometry: " .. node.line)
            elseif node.raster then
                -- Sized by its own fit, or growing where it takes all of it.
                rasters = rasters + 1
            elseif fixed_w == 100 and not fixed_h
                    and node.class == "wibox.container.margin" then
                forced = forced + 1
            else
                assert(not fixed_w and not fixed_h,
                    "a size Clay did not decide: " .. node.line)
            end
        end
        assert(rasters == 4, "expected four raster leaves, got " .. rasters)
        assert(forced == 1, "the forced width is not in the tree")
        io.stderr:write("[PASS] Clay sizes every node it can\n")
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
