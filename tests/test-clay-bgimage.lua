-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-bgimage.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")
local cairo = require("lgi").cairo

local s = screen[1]
local geo = s.geometry
local bar, bgb

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
    return table.concat(out, "\n"), head
end


local steps = {
    function(count)
        if count == 1 then
            local src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 20)
            local cr = cairo.Context(src)
            cr:set_source_rgb(1, 0, 0)
            cr:paint()
            bgb = wibox.widget {
                bg = "#00ff00", bgimage = src, widget = wibox.container.background,
                {
                    margins = 10, widget = wibox.container.margin,
                    { bg = "#0000ff", widget = wibox.container.background },
                },
            }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 100, height = 60,
                screen = s, visible = true, bg = "#204080", widget = bgb }
            return nil
        end
        local dump, head = nodes()

        if not head or not head:find("converted:", 1, true) then
            assert(count < 20, "the background never converted")
            return nil
        end
        assert(head:find("converted: 5 nodes, 1 images", 1, true), head)
        check_box(dump:match("[^\n]* image 20x20 natural [^\n]*"), 0, 0, 100, 60)
        local backgrounds = dump:gmatch("[^\n]*wibox.container.background[^\n]*")
        backgrounds()
        check_box(backgrounds(), 10, 10, 80, 40)
        assert(pixel(2, 2, "#ff0000"), "the image does not paint over the fill")
        assert(pixel(15, 15, "#0000ff"), "the child does not paint over the image")
        assert(pixel(5, 30, "#00ff00"), "the image stretches below its height")
        assert(pixel(30, 5, "#00ff00"), "the image stretches beyond its width")
        assert(pixel(95, 55, "#00ff00"), "the fill is missing at the far corner")
        io.stderr:write("[PASS] the natural background image paints under the child\n")
        return true
    end,
    function(count)
        if count == 1 then
            bgb.bgimage = nil
            return nil
        end
        local dump, head = nodes()

        assert(head and head:find("converted: 4 nodes, 0 images", 1, true), head)
        assert(not dump:find(" image ", 1, true), "the cleared background still has an image")
        assert(pixel(2, 2, "#00ff00"), "the cleared image hides the fill")
        assert(pixel(15, 15, "#0000ff"), "the child colour is missing")
        io.stderr:write("[PASS] clearing bgimage removes the image leaf\n")
        return true
    end,
    function(count)
        if count == 1 then
            bgb.bgimage = function(_, cr)
                cr:set_source_rgb(1, 0, 0)
                cr:paint()
            end
            return nil
        end
        local dump, head = nodes()

        assert(head and head:find("converted", 1, true), "the drawin has no tree")
        assert(not dump:find(" image ", 1, true), "the refused painter has an image node")
        io.stderr:write("[PASS] a function bgimage leaves out its container\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
