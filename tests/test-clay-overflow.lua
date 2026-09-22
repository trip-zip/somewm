-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-overflow.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")
local gears = require("gears")
local awful = require("awful")

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

local function thumb_record(dump)
    local p = ov._private
    local record = { p.drawable:_clay_scroll_get(p.content.id) }
    return dump .. "\nscroll record: " .. table.concat(record, ", ")
end

local function check_thumb(dump, x, y, width, height)
    local ok, err = pcall(check_box,
        dump:match("[^\n]* wibox%.widget%.separator [^\n]*"), x, y, width, height)
    assert(ok, tostring(err) .. "\n" .. thumb_record(dump))
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
        if not separator or separator:match(" box %-?%d+,%-?%d+ 0x0$") then
            assert(count < 20, "the scrollbar never reached a nonzero box")
            return nil
        end
        check_thumb(dump, 195, 0, 5, 66)
        local bg = backgrounds(dump)
        check_box(dump:match("[^\n]* spacer scroll=y[^\n]*"), 0, 0, 195, 100)
        check_box(bg[1], 0, 0, 195, 30)
        check_box(bg[4], 0, 90, 195, 30)
        check_box(bg[5], 0, 120, 195, 30)
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
        check_thumb(dump, 195, 34, 5, 66)
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
        assert(dump:match(" spacer scroll=y scrolled=25 "), "the content did not scroll to 25")
        check_box(bg[2], 0, 5, 195, 30)
        check_thumb(dump, 195, 17, 5, 66)
        assert(pixel(100, 2, "#ff0000"), "the first child's visible strip is not red")
        assert(pixel(100, 7, "#00ff00"), "the second child is not green")
        io.stderr:write("[PASS] overflow scrolls halfway\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov.step = 15
            ov.scroll_factor = 0
            return nil
        elseif count == 3 then
            awful.spawn(string.format("./build-test/test-virtual-pointer-client scroll %d %d 1280 720 down",
                bar.x + 100, bar.y + 15))
            return nil
        elseif count < 6 then
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        assert(dump:match(" spacer scroll=y scrolled=30 "), "the wheel did not scroll to 30: " .. dump)
        assert(math.abs(ov.scroll_factor - 0.6) < 1e-9, "the wheel factor is not 0.6")
        check_box(bg[2], 0, 0, 195, 30)
        check_box(bg[3], 0, 30, 195, 30)
        check_thumb(dump, 195, 20, 5, 66)
        assert(pixel(100, 15, "#00ff00"), "the wheel did not leave green at the top")
        io.stderr:write("[PASS] the wheel moves the Clay scroll record by 30 pixels\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov:add(wibox.widget { bg = "#00ffff", forced_height = 30,
                widget = wibox.container.background })
            return nil
        elseif count < 3 then
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        assert(dump:match(" spacer scroll=y scrolled=30 "), "content growth lost the scroll offset: " .. dump)
        check_box(bg[6], 0, 120, 195, 30)
        check_thumb(dump, 195, 16, 5, 55)
        io.stderr:write("[PASS] content growth resizes the thumb and preserves the scroll offset\n")
        return true
    end,
    function(count)
        if count == 1 then
            ov:reset()
            for _, color in ipairs { "#ff0000", "#00ff00", "#0000ff" } do
                ov:add(wibox.widget { bg = color, forced_height = 30,
                    widget = wibox.container.background })
            end
            return nil
        elseif count < 3 then
            return nil
        end
        local _, dump = nodes()
        check_box(dump:match("[^\n]* spacer scroll=y[^\n]*"), 0, 0, 200, 100)
        local separator = dump:match("[^\n]* wibox%.widget%.separator [^\n]*")
        assert(separator and separator:match("box %-?%d+,%-?%d+ 0x"),
            "the scrollbar did not collapse: " .. thumb_record(dump))
        assert(dump:match(" spacer scroll=y scrolled=0 "), "reset did not clear the scroll offset: " .. dump)
        assert(pixel(197, 75, "#0000ff"), "the blue child did not fill the collapsed track")
        io.stderr:write("[PASS] fitting content collapses the track and takes its width\n")
        return true
    end,
    function(count)
        if count == 1 then
            for _, color in ipairs { "#ffff00", "#ff00ff" } do
                ov:add(wibox.widget { bg = color, forced_height = 30,
                    widget = wibox.container.background })
            end
            return nil
        elseif count == 3 then
            ov.scroll_factor = 0.6
            return nil
        elseif count < 5 then
            return nil
        end
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
    function(count)
        if count == 1 then
            ov:emit_signal("widget::layout_changed")
            return nil
        elseif count < 3 then
            return nil
        end
        local _, dump = nodes()
        assert(dump:match(" spacer scroll=y scrolled=30 "), "redeclaring lost the scroll offset")
        io.stderr:write("[PASS] the scroll record survives unchanged declarations\n")
        return true
    end,
    function(count)
        if count == 1 then
            bar.visible = false
            return nil
        elseif count == 3 then
            bar.visible = true
            return nil
        elseif count < 5 then
            return nil
        end
        local _, dump = nodes()
        -- Clay drops scroll records that remain undeclared across its updates.
        assert(dump:match(" spacer scroll=y scrolled=0 "), "the hidden scroll record survived: " .. dump)
        io.stderr:write("[PASS] hiding and showing starts a new scroll record at zero\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
