-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-arcchart.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, chart
local BG = "#204080"

local function pixel(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), bar.x + x, bar.y + y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

local function check_box(line, dx, dy, width, height)
    assert(line, "the dump has no matching node")
    local x, y, w, h = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    assert(x, "the node has no box: " .. line)
    assert(tonumber(x) + geo.x == bar.x + dx
        and tonumber(y) + geo.y == bar.y + dy
        and tonumber(w) == width and tonumber(h) == height,
        "unexpected node box: " .. line)
end

local steps = {
    function(count)
        if count == 1 then
            chart = wibox.widget {
                values = { 1, 1 }, colors = { "#ff0000", "#00ff00" },
                thickness = 6, bg = "#0000ff",
                widget = wibox.container.arcchart,
            }
            -- The empty margin hands the arcchart the whole wibox box.
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(chart) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the arcchart never converted")
            return nil
        end
        local dump = awesome._clay_tree(s)
        local shapes = 0
        for line in dump:gmatch("[^\n]* shape[^\n]*") do
            shapes = shapes + 1
            check_box(line, 0, 0, 200, 40)
        end
        assert(shapes == 3, "the arcchart does not have three shape leaves")
        assert(pixel(100, 3, "#ff0000"), "the top arc is not red")
        assert(pixel(100, 37, "#00ff00"), "the bottom arc is not green")
        assert(pixel(88, 8, "#ff0000"), "the upper left arc is not red")
        assert(pixel(112, 32, "#00ff00"), "the lower right arc is not green")
        assert(pixel(100, 20, BG), "the hole is not the wibox colour")
        assert(pixel(40, 20, BG), "the arc paints outside its square")
        io.stderr:write("[PASS] the arcs fill the centred ring\n")
        return true
    end,
    function(count)
        if count == 1 then
            chart.max_value = 2
            chart.values = { 1 }
            return nil
        end
        assert(pixel(100, 3, "#ff0000"), "the half top arc is not red")
        assert(pixel(100, 37, "#0000ff"), "the uncovered bottom ring is not blue")
        io.stderr:write("[PASS] partial values reveal the background ring\n")
        return true
    end,
    function(count)
        if count == 1 then
            chart.border_width = 2
            chart.border_color = "#ffffff"
            return nil
        end
        assert(pixel(100, 1, "#ffffff"), "the outer border is not white")
        assert(pixel(100, 5, "#ff0000"), "the bordered arc is not red")
        io.stderr:write("[PASS] the border outlines the value arc\n")
        return true
    end,
    function(count)
        if count == 1 then
            chart.border_width = 0
            chart.thickness = 4
            chart.widget = wibox.container.background(wibox.widget.textbox("x"), "#ffff00")
            return nil
        end
        check_box(awesome._clay_tree(s):match("[^\n]* spacer clip[^\n]*"), 84, 4, 32, 32)
        assert(pixel(100, 20, "#ffff00"), "the child centre is not yellow")
        assert(pixel(85, 5, BG), "the child paints outside its circle")
        bar.visible = false
        io.stderr:write("[PASS] the square content clips the child to its circle\n")
        return true
    end,
}

runner.run_steps(steps)
