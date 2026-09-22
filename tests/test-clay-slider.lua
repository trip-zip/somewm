-- luacheck: globals screen root awesome mousegrabber
-- Run: make test-one TEST=tests/test-clay-slider.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, slider
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
            slider = wibox.widget {
                value = 50, minimum = 0, maximum = 100,
                bar_color = "#00ff00", handle_color = "#ff0000",
                handle_width = 20, bar_height = 10, widget = wibox.widget.slider,
            }
            -- The empty margin keeps the tree inspectable when the slider is refused.
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(slider) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the slider never converted")
            return nil
        end
        local dump = awesome._clay_tree(s)
        check_box(dump:match("[^\n]*spacer[^\n]* h=fixed%(10%)[^\n]*"), 0, 15, 200, 10)
        check_box(dump:match("[^\n]* shape[^\n]*"), 0, 0, 200, 40)
        assert(pixel(100, 20, "#ff0000"), "the handle centre is not red")
        assert(pixel(50, 20, "#00ff00"), "the bar is not green")
        assert(pixel(50, 5, BG), "the bar hides the wibox colour above it")
        assert(pixel(95, 5, "#ff0000"), "the handle does not reach above the bar")
        io.stderr:write("[PASS] the centred bar and full-height handle have the expected boxes and pixels\n")
        return true
    end,
    function(count)
        if count == 1 then
            slider.bar_active_color = "#0000ff"
            return nil
        end
        local _, shapes = awesome._clay_tree(s):gsub("[^\n]* shape[^\n]*", "")
        assert(shapes == 2, "the active slider does not have two shape leaves")
        assert(pixel(50, 20, "#0000ff"), "the active bar is not blue")
        assert(pixel(150, 20, "#00ff00"), "the remaining bar is not green")
        io.stderr:write("[PASS] the active bar is blue and the remaining bar is green\n")
        return true
    end,
    function(count)
        if count == 1 then
            slider.value = 100
            return nil
        end
        assert(pixel(190, 20, "#ff0000"), "the handle did not move to the maximum")
        assert(pixel(150, 20, "#0000ff"), "the active bar did not grow")
        assert(pixel(170, 5, BG), "the handle paints outside its box")
        io.stderr:write("[PASS] the maximum value moves the handle and extends the active bar\n")
        return true
    end,
    function(count)
        if count == 1 then
            slider.bar_shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 4) end
            return nil
        end
        assert(pixel(0, 15, BG), "the rounded bar does not clip the active corner")
        assert(pixel(100, 20, "#0000ff"), "the rounded active bar is not blue")
        io.stderr:write("[PASS] the rounded bar clips the active corner\n")
        return true
    end,
    function(count)
        if count == 1 then
            slider.handle_shape = gshape.circle
            return nil
        end
        assert(pixel(190, 20, "#ff0000"), "the circular handle centre is not red")
        assert(pixel(181, 1, BG), "the circular handle paints outside its circle")
        io.stderr:write("[PASS] the handle shape is a circle\n")
        return true
    end,
    function()
        bar.drawin.drawable:emit_signal("button::press", 30, 20, 1, {})
        assert(slider.value == 15, "the press did not set the slider value to 15")
        if mousegrabber.isrunning() then
            mousegrabber.stop()
        end
        bar.visible = false
        io.stderr:write("[PASS] a press sets the converted slider value to 15\n")
        return true
    end,
}

runner.run_steps(steps)
