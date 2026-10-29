-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-separator-line.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, separator
local BG = "#204080"

local function pixel(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), bar.x + x, bar.y + y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

local function check_box(pattern, dx, dy, width, height)
    local line = awesome._clay_tree(s):match(pattern)
    assert(line, "the dump has no matching line")
    local x, y, w, h = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    assert(x, "the child has no box: " .. line)
    assert(tonumber(x) + geo.x == bar.x + dx
        and tonumber(y) + geo.y == bar.y + dy
        and tonumber(w) == width and tonumber(h) == height,
        "unexpected child box: " .. line)
end

local function horizontal_pixels()
    assert(pixel(100, 20, "#ff0000"), "the centre is not red")
    assert(pixel(20, 20, BG), "the line extends beyond its horizontal span")
    assert(pixel(100, 14, BG), "the line extends above its thickness")
end

local function bordered_pixels()
    assert(pixel(100, 16, "#ffff00") and pixel(100, 23, "#ffff00"), "the top or bottom border is missing")
    assert(pixel(50, 20, "#ffff00") and pixel(149, 20, "#ffff00"), "the end borders are missing")
    assert(pixel(100, 20, "#ff0000"), "the fill is not red inside the border")
    assert(pixel(100, 14, BG) and pixel(100, 25, BG), "the border lies outside the line")
end

local steps = {
    function(count)
        if count == 1 then
            separator = wibox.widget.separator {
                orientation = "horizontal", span_ratio = 0.5,
                thickness = 4, color = "#ff0000",
            }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG, widget = separator }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the separator never converted")
            return nil
        end
        check_box("[^\n]* w=percent%(0%.5%)[^\n]*", 50, 18, 100, 4)
        horizontal_pixels()
        io.stderr:write("[PASS] horizontal line is centred with 50% width and red pixels\n")
        return true
    end,
    function(count)
        if count == 1 then
            separator.orientation = "vertical"
            return nil
        end
        check_box("[^\n]* h=percent%(0%.5%)[^\n]*", 98, 10, 4, 20)
        assert(pixel(100, 20, "#ff0000"), "the centre is not red")
        assert(pixel(94, 20, BG), "the line extends left of its thickness")
        assert(pixel(100, 4, BG), "the line extends beyond its vertical span")
        io.stderr:write("[PASS] vertical line is centred with 50% height and red pixels\n")
        return true
    end,
    function(count)
        if count == 1 then
            separator.orientation = "auto"
            return nil
        end
        check_box("[^\n]* shape [^\n]*", 0, 0, 200, 40)
        horizontal_pixels()
        io.stderr:write("[PASS] auto shape fills the wibox and draws a horizontal line\n")
        return true
    end,
    function(count)
        if count == 1 then
            separator.color = "#00ff00"
            return nil
        end
        if pixel(100, 20, "#00ff00") then
            bar.visible = false
            io.stderr:write("[PASS] changing line colour turns the centre green\n")
            return true
        end
        assert(count < 20, "the centre never turned green")
    end,
    -- The line is 100 wide from x 50; the gradient is in the line's box.
    function(count)
        if count == 1 then
            separator = wibox.widget.separator {
                orientation = "horizontal", span_ratio = 0.5,
                thickness = 4, color = capture.gradient(0, 100),
            }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG, widget = separator }
            return nil
        end
        local line = capture.dump_line(s, capture.gradient_record(0, 0, 100))
        if not (line and pixel(52, 20, "#ff0000") and pixel(147, 20, "#0000ff")) then
            assert(count < 20, "the gradient line never drew: " .. awesome._clay_tree(s))
            return nil
        end
        check_box("[^\n]* w=percent%(0%.5%)[^\n]*", 50, 18, 100, 4)
        assert(line:find(" w=percent", 1, true), "the gradient is not on the line: " .. line)
        bar.visible = false
        io.stderr:write("[PASS] a gradient colour draws red to blue along the line\n")
        return true
    end,
    -- The 8 px line spans x 50 to 150 and y 16 to 24; the 2 px border lies
    -- inside it, around a 4 px fill.
    function(count)
        if count == 1 then
            separator = wibox.widget.separator {
                orientation = "horizontal", span_ratio = 0.5, thickness = 8,
                color = "#ff0000", border_width = 2, border_color = "#ffff00",
            }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG, widget = separator }
            return nil
        end
        if not pixel(100, 20, "#ff0000") then
            assert(count < 20, "the bordered line never drew: " .. awesome._clay_tree(s))
            return nil
        end
        bordered_pixels()
        io.stderr:write("[PASS] a horizontal line draws its border inside the line\n")
        return true
    end,
    function(count)
        if count == 1 then
            separator.orientation = "auto"
            return nil
        end
        if not awesome._clay_tree(s):find(" shape ", 1, true) then
            assert(count < 20, "the auto line never drew as a shape: " .. awesome._clay_tree(s))
            return nil
        end
        bordered_pixels()
        bar.visible = false
        io.stderr:write("[PASS] an auto line draws its border inside the line\n")
        return true
    end,
}

runner.run_steps(steps)
