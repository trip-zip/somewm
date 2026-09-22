-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-piechart.lua
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
                data_list = { { "a", 1 }, { "b", 1 } },
                colors = { "#ff0000", "#00ff00" },
                border_width = 2, display_labels = false,
                widget = wibox.widget.piechart,
            }
            -- The empty margin hands the piechart the whole wibox box.
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 100,
                screen = s, visible = true, bg = BG, fg = "#ffffff",
                widget = wibox.container.margin(chart) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the piechart never converted")
            return nil
        end
        local shapes = 0
        for line in awesome._clay_tree(s):gmatch("[^\n]* shape[^\n]*") do
            shapes = shapes + 1
            check_box(line, 0, 0, 200, 100)
        end
        assert(shapes == 2, "the piechart does not have two shape leaves")
        assert(pixel(100, 62, "#ff0000"), "the bottom sector is not red")
        assert(pixel(100, 38, "#00ff00"), "the top sector is not green")
        assert(pixel(112, 50, "#ffffff"), "the boundary border is not white")
        assert(pixel(140, 50, BG), "the pie paints outside its circle")
        io.stderr:write("[PASS] sectors fill the centred pie with a foreground border\n")
        return true
    end,
    function(count)
        if count == 1 then
            chart.colors = { "#0000ff" }
            return nil
        end
        assert(pixel(100, 62, "#0000ff"), "the bottom sector is not blue")
        assert(pixel(100, 38, "#0000ff"), "the top sector is not blue")
        io.stderr:write("[PASS] one colour cycles over both sectors\n")
        return true
    end,
    function(count)
        if count == 1 then
            chart.display_labels = true
            return nil
        end
        local shapes = 0
        for _ in awesome._clay_tree(s):gmatch("[^\n]* shape[^\n]*") do
            shapes = shapes + 1
        end
        assert(shapes == 6, "the labelled piechart does not have six shape leaves")
        assert(pixel(100, 80, "#ffffff"), "the bottom label line is not white")
        assert(pixel(94, 87, "#ffffff"), "the bottom label tick is not white")
        assert(pixel(87, 87, "#ffffff"), "the bottom label dot is not white")
        local glyph = false
        for y = 80, 95 do
            for x = 60, 78 do
                glyph = pixel(x, y, "#ffffff") or glyph
            end
        end
        assert(glyph, "the bottom label glyph is not white")
        assert(pixel(100, 20, "#ffffff"), "the top label line is not white")
        io.stderr:write("[PASS] labels paint lines, ticks, dots and glyphs\n")
        return true
    end,
    function(count)
        if count == 1 then
            chart.border_color = "#ffff00"
            return nil
        end
        assert(pixel(112, 50, "#ffff00"), "the boundary border is not yellow")
        assert(pixel(100, 80, "#ffffff"), "the label line is not still white")
        bar.visible = false
        io.stderr:write("[PASS] the border colour leaves labels in the foreground\n")
        return true
    end,
}

runner.run_steps(steps)
