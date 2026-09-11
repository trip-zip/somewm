-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-overflow.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")
local gears = require("gears")

local s = screen[1]
local geo = s.geometry
local bar, ov
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

-- Only the bar's drawin block contributes nodes.
local function nodes()
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, out = nil, {}

    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if head then
            if not line:match("^    %x+ ") then
                break
            end
            out[#out + 1] = line
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, table.concat(out, "\n")
end

local function backgrounds(dump)
    local out = {}
    for line in dump:gmatch("[^\n]* wibox%.container%.background [^\n]*") do
        out[#out + 1] = line
    end
    return out
end

local steps = {
    function(count)
        if count == 1 then
            ov = wibox.layout.overflow.vertical()
            for _, color in ipairs { "#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff" } do
                ov:add(wibox.widget { bg = color, forced_height = 30,
                    widget = wibox.container.background })
            end
            ov.scrollbar_widget = wibox.widget.separator {
                shape = gears.shape.rectangle, color = "#ffffff" }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 100,
                screen = s, visible = true, bg = BG, widget = ov }
            return nil
        end
        local head, dump = nodes()
        if head then
            assert(head:find("converted", 1, true), "the bar did not convert: " .. head)
        end
        local separator = dump:match("[^\n]* wibox%.widget%.separator [^\n]*")
        if not separator then
            assert(count < 20, "the scrollbar never reached the dump")
            return nil
        end
        local bg = backgrounds(dump)
        check_box(dump:match("[^\n]* spacer scroll=y[^\n]*"), 0, 0, 195, 100)
        check_box(bg[1], 0, 0, 195, 30)
        check_box(bg[4], 0, 90, 195, 30)
        check_box(bg[5], 0, 120, 195, 30)
        check_box(separator, 195, 0, 5, 66)
        assert(pixel(100, 15, "#ff0000"), "the first child is not red")
        assert(pixel(100, 45, "#00ff00"), "the second child is not green")
        assert(pixel(100, 95, "#ffff00"), "the fourth child is not yellow")
        assert(pixel(197, 30, "#ffffff"), "the scrollbar is not white")
        assert(pixel(197, 80, BG), "the track below the scrollbar is not background")
        io.stderr:write("[PASS] overflow clips its content and sizes the scrollbar\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov.scroll_factor = 1
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        assert(dump:match(" spacer scroll=y scrolled=50 "), "the content did not scroll to 50")
        check_box(bg[1], 0, -50, 195, 30)
        check_box(bg[5], 0, 70, 195, 30)
        check_box(dump:match("[^\n]* wibox%.widget%.separator [^\n]*"), 195, 34, 5, 66)
        assert(pixel(100, 5, "#00ff00"), "the top visible child is not green")
        assert(pixel(100, 95, "#ff00ff"), "the last child is not magenta")
        assert(pixel(197, 20, BG), "the track above the scrollbar is not background")
        assert(pixel(197, 50, "#ffffff"), "the scrollbar did not reach the bottom")
        io.stderr:write("[PASS] overflow scrolls to the end\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov.scroll_factor = 0.5
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        check_box(bg[2], 0, 5, 195, 30)
        check_box(dump:match("[^\n]* wibox%.widget%.separator [^\n]*"), 195, 17, 5, 66)
        assert(pixel(100, 2, "#ff0000"), "the first child's visible strip is not red")
        assert(pixel(100, 7, "#00ff00"), "the second child is not green")
        io.stderr:write("[PASS] overflow scrolls halfway\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov.step = 15
            ov:emit_signal("button::press", 10, 10, 5)
            assert(math.abs(ov.scroll_factor - 0.6) < 1e-9, "the wheel factor is not 0.6")
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        assert(dump:match(" spacer scroll=y scrolled=30 "), "the wheel did not scroll to 30")
        check_box(bg[2], 0, 0, 195, 30)
        check_box(bg[3], 0, 30, 195, 30)
        check_box(dump:match("[^\n]* wibox%.widget%.separator [^\n]*"), 195, 20, 5, 66)
        assert(pixel(100, 15, "#00ff00"), "the wheel did not leave green at the top")
        io.stderr:write("[PASS] the wheel handler advances the scroll factor\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov.scrollbar_enabled = false
            return nil
        end
        local _, dump = nodes()
        assert(not dump:find("wibox.widget.separator", 1, true), "the scrollbar is still present")
        local bg = backgrounds(dump)
        check_box(bg[3], 0, 30, 200, 30)
        assert(pixel(197, 50, "#0000ff"), "the content did not fill the scrollbar's width")
        io.stderr:write("[PASS] hiding the scrollbar gives its width to the content\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
