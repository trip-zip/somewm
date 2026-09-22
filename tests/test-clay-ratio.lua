-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-ratio.lua
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

local steps = {
    function(count)
        if count == 1 then
            layout = wibox.layout.ratio.horizontal()
            assert(layout.fit == nil, "the ratio defines fit")
            layout:add(wibox.container.background(nil, "#ff0000"),
                wibox.container.background(nil, "#00ff00"),
                wibox.container.background(nil, "#0000ff"))
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(layout) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the ratio never converted")
            return nil
        end
        converted_boxes = #awesome._test_widget_boxes(bar.drawin)
        local shares = 0
        for _ in awesome._clay_tree(s):gmatch("[^\n]* w=percent%(0%.333333%)[^\n]*") do
            shares = shares + 1
        end
        assert(shares == 3, "the ratio does not have three equal shares")
        assert(pixel(33, 20, "#ff0000"), "the first share is not red")
        assert(pixel(100, 20, "#00ff00"), "the second share is not green")
        assert(pixel(166, 20, "#0000ff"), "the third share is not blue")
        io.stderr:write("[PASS] three equal shares paint red, green and blue\n")
        return true
    end,
    function(count)
        if count == 1 then
            layout:set_ratio(1, 0.5)
            return nil
        end
        assert(awesome._clay_tree(s):match(" w=percent%(0%.5%)"), "the ratio has no 50% share")
        assert(pixel(75, 20, "#ff0000"), "the first share is not red")
        assert(pixel(125, 20, "#00ff00"), "the second share is not green")
        assert(pixel(175, 20, "#0000ff"), "the third share is not blue")
        io.stderr:write("[PASS] set_ratio resizes the three shares\n")
        return true
    end,
    function(count)
        if count == 1 then
            layout.spacing = 5
            return nil
        end
        local line = awesome._clay_tree(s):match("[^\n]*wibox.layout.ratio[^\n]*")
        assert(line, "wibox.layout.ratio did not convert")
        assert(#awesome._test_widget_boxes(bar.drawin) == converted_boxes, "the converted box count changed")
        bar.visible = false
        io.stderr:write("[PASS] spacing is ignored in the ratio\n")
        return true
    end,
}

runner.run_steps(steps)
