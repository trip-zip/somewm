-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-flex.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")
local cairo = require("lgi").cairo

local s = screen[1]
local geo = s.geometry
local bar
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

-- An imagebox holding a solid 24x24 image.
local function solid(r, g, b)
    local img = cairo.ImageSurface(cairo.Format.ARGB32, 24, 24)
    local cr = cairo.Context(img)
    cr:set_source_rgb(r, g, b)
    cr:paint()
    return wibox.widget.imagebox(img)
end

-- A fresh bar of `height` holding `layout`, in place of the last one.
local function show(height, layout)
    if bar then
        bar.visible = false
    end
    bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = height,
        screen = s, visible = true, bg = BG, widget = layout }
end

-- The bar's `n` image leaf lines once it is in the dump, or nil to wait.
local function images(count, n)
    local head, dump = nodes()
    if not head or (head:find("converted", 1, true) and dump == "") then
        assert(count < 20, "the bar never reached the dump")
        return nil
    end
    assert(head:find("converted", 1, true), "the bar did not convert: " .. head)
    local out = {}
    for line in dump:gmatch("[^\n]* image 24x24 [^\n]*") do
        out[#out + 1] = line
    end
    assert(#out == n, "unexpected image count: " .. dump)
    return out
end

local steps = {
    function(count)
        if count == 1 then
            show(48, wibox.layout.flex.vertical(solid(1, 0, 0), solid(0, 1, 0)))
            return nil
        end
        local im = images(count, 2)
        if not im then return nil end
        check_box(im[1], 0, 0, 24, 24)
        check_box(im[2], 0, 24, 24, 24)
        assert(pixel(12, 12, "#ff0000") and pixel(12, 36, "#00ff00"),
            "the rows are not 24 high")
        assert(pixel(40, 12, BG), "the image paints beyond its square")
        io.stderr:write("[PASS] the flex offers each row its share\n")
        return true
    end,
    function(count)
        if count == 1 then
            local layout = wibox.layout.flex.vertical(
                solid(1, 0, 0), solid(0, 1, 0), solid(0, 0, 1))
            layout.spacing = 5
            show(70, layout)
            return nil
        end
        local im = images(count, 3)
        if not im then return nil end
        check_box(im[1], 0, 0, 20, 20)
        check_box(im[2], 0, 25, 20, 20)
        check_box(im[3], 0, 50, 20, 20)
        assert(pixel(10, 10, "#ff0000") and pixel(10, 35, "#00ff00")
            and pixel(10, 60, "#0000ff"), "the rows are not 20 high")
        assert(pixel(10, 22, BG), "the gap is painted")
        io.stderr:write("[PASS] the share leaves out the gaps\n")
        return true
    end,
    function(count)
        if count == 1 then
            local layout = wibox.layout.flex.vertical(solid(1, 0, 0), solid(0, 1, 0))
            layout.max_widget_size = 20
            show(90, layout)
            return nil
        end
        local im = images(count, 2)
        if not im then return nil end
        check_box(im[1], 0, 0, 20, 20)
        check_box(im[2], 0, 20, 20, 20)
        assert(pixel(10, 10, "#ff0000") and pixel(10, 30, "#00ff00"),
            "the rows are not capped at 20")
        assert(pixel(10, 50, BG), "the column paints below its rows")
        io.stderr:write("[PASS] max_widget_size caps the share\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
