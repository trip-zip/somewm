-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-progressbar.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, progressbar, converted_boxes
local BG = "#204080"

local function pixel(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), bar.x + x, bar.y + y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

local function check_box(dx, dy, width, height)
    local line = awesome._clay_tree(s):match("[^\n]* w=percent%(0%.5%)[^\n]*")
    assert(line, "the dump has no 50% bar")
    local x, y, w, h = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    assert(x, "the bar has no box: " .. line)
    assert(tonumber(x) + geo.x == bar.x + dx
        and tonumber(y) + geo.y == bar.y + dy
        and tonumber(w) == width and tonumber(h) == height,
        "unexpected bar box: " .. line)
end

local steps = {
    function(count)
        if count == 1 then
            progressbar = wibox.widget {
                value = 0.5, color = "#ff0000", background_color = "#00ff00",
                margins = 4, paddings = 2, widget = wibox.widget.progressbar,
            }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(progressbar) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the progressbar never converted")
            return nil
        end
        converted_boxes = #awesome._test_widget_boxes(bar.drawin)
        check_box(6, 6, 94, 28)
        assert(pixel(53, 20, "#ff0000"), "the bar centre is not red")
        assert(pixel(104, 20, "#00ff00"), "the background is not green")
        assert(pixel(2, 2, BG), "the margin hides the wibox colour")
        io.stderr:write("[PASS] the 50% bar is 94 by 28 at 6,6 with red, green and margin pixels\n")
        return true
    end,
    function(count)
        if count == 1 then
            progressbar.border_width = 2
            progressbar.border_color = "#0000ff"
            return nil
        end
        check_box(8, 8, 92, 24)
        assert(pixel(5, 20, "#0000ff"), "the border ring is not blue")
        assert(pixel(54, 20, "#ff0000"), "the bordered bar centre is not red")
        io.stderr:write("[PASS] the bordered bar is 92 by 24 at 8,8 with a blue ring\n")
        return true
    end,
    function(count)
        if count == 1 then
            progressbar.shape = gshape.rounded_rect
            progressbar.border_width = 0
            return nil
        end
        check_box(6, 6, 94, 28)
        assert(pixel(4, 4, BG), "the rounded background corner hides the wibox colour")
        assert(pixel(6, 6, BG), "the rounded background does not clip the bar corner")
        assert(pixel(53, 20, "#ff0000"), "the rounded bar centre is not red")
        io.stderr:write("[PASS] the rounded background clips the 94 by 28 bar at 6,6\n")
        return true
    end,
    function(count)
        if count == 1 then
            progressbar.clip = false
            return nil
        end
        check_box(2, 2, 98, 36)
        assert(pixel(3, 20, "#ff0000"), "the unclipped bar does not reach under the margin")
        io.stderr:write("[PASS] the unclipped bar is 98 by 36 at 2,2 and reaches under the margin\n")
        return true
    end,
    function(count)
        if count == 1 then
            progressbar.value = 0
            return nil
        end
        assert(not awesome._clay_tree(s):match("[^\n]* w=percent%("),
            "the zero value still has a percent bar")
        assert(pixel(51, 20, "#00ff00"), "the old bar centre is not green")
        io.stderr:write("[PASS] zero value omits the percent bar and leaves a green centre\n")
        return true
    end,
    function(count)
        if count == 1 then
            progressbar.ticks = true
            return nil
        end
        local line = awesome._clay_tree(s):match("[^\n]*wibox.widget.progressbar[^\n]*")
        assert(line, "wibox.widget.progressbar did not convert")
        assert(#awesome._test_widget_boxes(bar.drawin) == converted_boxes, "ticks changed the widget boxes")
        assert(pixel(51, 20, "#00ff00"), "the centre is not green")
        bar.visible = false
        io.stderr:write("[PASS] ticks are ignored in the progressbar\n")
        return true
    end,
}

runner.run_steps(steps)
