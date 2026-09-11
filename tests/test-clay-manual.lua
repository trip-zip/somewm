-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-manual.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, layout, converted_boxes
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
            local red = wibox.container.background(nil, "#ff0000")
            red.point = { x = 10, y = 5, width = 30, height = 20 }
            local green = wibox.container.background(nil, "#00ff00")
            green.forced_width, green.forced_height = 40, 20
            layout = wibox.layout.manual(red)
            layout:add_at(green, { x = 100, y = 10 })
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(layout) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the manual layout never converted")
            return nil
        end
        converted_boxes = #awesome._test_widget_boxes(bar.drawin)
        local wrappers = {}
        for line in awesome._clay_tree(s):gmatch("[^\n]* spacer[^\n]*") do
            wrappers[#wrappers + 1] = line
        end
        assert(#wrappers == 2, "the manual layout does not have two wrappers")
        check_box(wrappers[1], 10, 5, 30, 20)
        check_box(wrappers[2], 100, 10, 40, 20)
        assert(pixel(25, 15, "#ff0000"), "the first child is not red")
        assert(pixel(120, 20, "#00ff00"), "the second child is not green")
        assert(pixel(5, 15, BG) and pixel(95, 20, BG), "the children paint outside their points")
        io.stderr:write("[PASS] manual wrappers follow explicit and forced sizes\n")
        return true
    end,
    function(count)
        if count == 1 then
            layout:move(1, { x = 50, y = 5, width = 30, height = 20 })
            return nil
        end
        assert(pixel(65, 15, "#ff0000"), "the moved child is not red")
        assert(pixel(25, 15, BG), "the old point is not the wibox colour")
        io.stderr:write("[PASS] move updates the child's point\n")
        return true
    end,
    function(count)
        if count == 1 then
            layout:add_at(wibox.container.background(), function() return { x = 0, y = 0 } end)
            return nil
        end
        local line = awesome._clay_tree(s):match("[^\n]*wibox.layout.manual[^\n]*")
        assert(line, "wibox.layout.manual did not convert")
        assert(#awesome._test_widget_boxes(bar.drawin) == converted_boxes, "the converted box count changed")
        bar.visible = false
        io.stderr:write("[PASS] callable points skip their child in the manual layout\n")
        return true
    end,
}

runner.run_steps(steps)
