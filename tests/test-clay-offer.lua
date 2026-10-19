-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-offer.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")
local cairo = require("lgi").cairo

local s = screen[1]
local geo = s.geometry
local bar, ib, margin
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

local steps = {
    function(count)
        if count == 1 then
            local red = cairo.ImageSurface(cairo.Format.ARGB32, 16, 16)
            local cr = cairo.Context(red)
            cr:set_source_rgb(1, 0, 0)
            cr:paint()
            ib = wibox.widget.imagebox(red)
            margin = wibox.container.margin(ib, 5, 5, 5, 5)
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.layout.fixed.horizontal(margin) }
            return nil
        end
        local head, dump = nodes()
        if not head or (head:find("converted", 1, true) and dump == "") then
            assert(count < 20, "the bar never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the bar did not convert: " .. head)
        check_box(dump:match("[^\n]* image 16x16 [^\n]*"), 5, 5, 30, 30)
        assert(pixel(20, 20, "#ff0000") and pixel(7, 7, "#ff0000"),
            "the image does not fill the inner height")
        assert(pixel(40, 20, BG), "the image paints beyond its square")
        io.stderr:write("[PASS] the margin offers the image its inner height\n")
        return true
    end,
    function(count)
        if count == 1 then
            ib.upscale = false
            return nil
        end
        local _, dump = nodes()
        check_box(dump:match("[^\n]* image 16x16 [^\n]*"), 5, 5, 16, 16)
        assert(pixel(13, 13, "#ff0000"), "the natural image is not red")
        assert(pixel(25, 25, BG), "the image upscales despite its cap")
        io.stderr:write("[PASS] upscale off caps the image at its natural size\n")
        return true
    end,
    function(count)
        if count == 1 then
            ib.upscale = nil
            ib.forced_height = 20
            return nil
        end
        local _, dump = nodes()
        check_box(dump:match("[^\n]* image 16x16 [^\n]*"), 5, 5, 20, 20)
        assert(pixel(15, 15, "#ff0000"), "the forced-height image is not red")
        -- x=26 is one pixel into the background from the image's edge at 25.
        assert(pixel(26, 15, BG) and pixel(15, 28, BG),
            "the image paints beyond the forced-height square")
        io.stderr:write("[PASS] forced height limits the image's offer\n")
        return true
    end,
    function(count)
        if count == 1 then
            ib.forced_height = nil
            margin.widget = wibox.container.constraint(ib, "max", nil, 20)
            return nil
        end
        local _, dump = nodes()
        check_box(dump:match("[^\n]* image 16x16 [^\n]*"), 5, 5, 20, 20)
        assert(pixel(15, 15, "#ff0000"), "the constrained image is not red")
        assert(pixel(27, 15, BG), "the image paints beyond the constraint's cap")
        io.stderr:write("[PASS] the constraint caps the image's offer\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
