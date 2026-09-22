-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-graph.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local shape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, graph
local BG = "#204080"

local function pixel(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), bar.x + x, bar.y + y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

local function check_shapes(expected)
    local shapes = 0
    for line in awesome._clay_tree(s):gmatch("[^\n]* shape[^\n]*") do
        shapes = shapes + 1
        local x, y, width, height = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
        assert(x, "the shape has no box: " .. line)
        assert(tonumber(x) + geo.x == bar.x and tonumber(y) + geo.y == bar.y
            and tonumber(width) == 200 and tonumber(height) == 40,
            "unexpected shape box: " .. line)
    end
    assert(shapes == expected, "unexpected graph shape count: " .. shapes)
end

local steps = {
    function(count)
        if count == 1 then
            graph = wibox.widget {
                step_width = 10, step_spacing = 0,
                color = "#ff0000", background_color = "#00ff00",
                min_value = 0, max_value = 1, nan_color = "#ffff00",
                widget = wibox.widget.graph,
            }
            graph:add_value(1)
            graph:add_value(0.5)
            -- The empty margin hands the graph the whole wibox box.
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(graph) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the graph never converted")
            return nil
        end
        check_shapes(1)
        assert(pixel(5, 30, "#ff0000"), "the recent half bar is not red")
        assert(pixel(5, 10, "#00ff00"), "the area above the half bar is not green")
        assert(pixel(15, 10, "#ff0000"), "the full bar is not red")
        assert(pixel(100, 20, "#00ff00"), "the unused values area is not green")
        io.stderr:write("[PASS] graph values fill the box in newest-first order\n")
        return true
    end,
    function(count)
        if count == 1 then
            graph.border_width = 2
            graph.border_color = "#0000ff"
            return nil
        end
        assert(pixel(1, 20, "#0000ff"), "the border is not blue")
        assert(pixel(5, 30, "#ff0000"), "the inset half bar is not red")
        assert(pixel(15, 10, "#ff0000"), "the inset full bar is not red")
        io.stderr:write("[PASS] the border insets the graph values\n")
        return true
    end,
    function(count)
        if count == 1 then
            graph:add_value(0 / 0)
            return nil
        end
        check_shapes(2)
        assert(pixel(5, 20, "#ffff00"), "the NaN indication is not yellow")
        assert(pixel(15, 30, "#ff0000"), "the shifted half bar is not red")
        assert(pixel(25, 10, "#ff0000"), "the shifted full bar is not red")
        assert(pixel(22, 2, "#ff0000"), "the full bar's square corner is not red")
        io.stderr:write("[PASS] the NaN leaf paints after the shifted values\n")
        return true
    end,
    function(count)
        if count == 1 then
            graph.step_shape = function(cr, width, height)
                shape.rounded_rect(cr, width, height, 3)
            end
            return nil
        end
        assert(pixel(25, 10, "#ff0000"), "the rounded full bar is not red")
        assert(pixel(15, 30, "#ff0000"), "the rounded half bar is not red")
        assert(not pixel(12, 2, "#ff0000"), "the area above the half bar is red")
        -- After the NaN insertion, the full bar starts at x=22, the half bar at x=12.
        assert(not pixel(22, 2, "#ff0000"), "the full bar's corner is not rounded away")
        bar.visible = false
        io.stderr:write("[PASS] step shapes record rounded bar paths\n")
        return true
    end,
}

runner.run_steps(steps)
