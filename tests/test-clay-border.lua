-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-border.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gcolor = require("gears.color")
local wibox = require("wibox")
local cairo = require("lgi").cairo

local s = screen[1]
local geo = s.geometry
local bar, border, child, margin
local BG, CHILD = "#204080", "#102030"

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
    return table.concat(out, "\n")
end

local function images(dump, size)
    local out = {}
    for line in dump:gmatch("[^\n]+") do
        if line:find(" image " .. size .. " ", 1, true) then
            out[#out + 1] = line
        end
    end
    return out
end

local steps = {
    function(count)
        if count == 1 then
            local src = cairo.ImageSurface(cairo.Format.ARGB32, 30, 30)
            local cr = cairo.Context(src)
            local colors = { "#ff0000", "#00ff00", "#0000ff",
                "#ffff00", "#ff00ff", "#00ffff", "#ffffff", "#000000", "#808080" }

            for i, color in ipairs(colors) do
                cr:set_source(gcolor(color))
                cr:rectangle((i - 1) % 3 * 10, math.floor((i - 1) / 3) * 10, 10, 10)
                cr:fill()
            end
            child = wibox.container.background(nil, CHILD)
            border = wibox.container.border { widget = child, border_image = src, borders = 10 }
            margin = wibox.container.margin(border)
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 60,
                screen = s, visible = true, bg = BG, widget = margin }
            return nil
        end
        local dump = nodes()
        local cells = images(dump, "10x10")

        if #cells == 0 then
            assert(count < 20, "the border never converted")
            return nil
        end
        assert(#cells == 8, "expected eight border images")
        local boxes = { { 0, 0, 10, 10 }, { 10, 0, 180, 10 }, { 190, 0, 10, 10 },
            { 0, 10, 10, 40 }, { 190, 10, 10, 40 }, { 0, 50, 10, 10 },
            { 10, 50, 180, 10 }, { 190, 50, 10, 10 } }

        for i, box in ipairs(boxes) do
            check_box(cells[i], box[1], box[2], box[3], box[4])
        end
        check_box(dump:match("[^\n]*wibox.container.background[^\n]*"), 10, 10, 180, 40)
        assert(pixel(5, 5, "#ff0000"), "top left is not red")
        assert(pixel(100, 5, "#00ff00"), "top is not green")
        assert(pixel(195, 5, "#0000ff"), "top right is not blue")
        assert(pixel(5, 30, "#ffff00"), "left is not yellow")
        assert(pixel(195, 30, "#00ffff"), "right is not cyan")
        assert(pixel(5, 55, "#ffffff"), "bottom left is not white")
        assert(pixel(100, 55, "#000000"), "bottom is not black")
        assert(pixel(195, 55, "#808080"), "bottom right is not gray")
        assert(pixel(100, 30, CHILD), "the child colour is missing")
        io.stderr:write("[PASS] border images and child occupy the nine cells\n")
        return true
    end,
    function(count)
        if count == 1 then
            border.paddings = 5
            return nil
        end
        check_box(nodes():match("[^\n]*wibox.container.background[^\n]*"), 15, 15, 170, 30)
        assert(pixel(12, 30, BG), "padding is not the wibox colour")
        assert(pixel(100, 30, CHILD), "the padded child colour is missing")
        io.stderr:write("[PASS] border padding insets the child\n")
        return true
    end,
    function(count)
        if count == 1 then
            border.fill = true
            return nil
        end
        local cells = images(nodes(), "10x10")

        assert(#cells == 9, "expected nine border images with filling")
        check_box(cells[5], 10, 10, 180, 40)
        assert(cells[5]:find(" filter=nearest", 1, true), "the filling has no nearest filter")
        assert(pixel(12, 30, "#ff00ff") and pixel(12, 12, "#ff00ff"), "filling is not magenta")
        -- Pixels beside the fill's edge prove the nearest filter; cairo's default fades them.
        assert(pixel(11, 30, "#ff00ff") and pixel(11, 12, "#ff00ff"), "the filling's edge fades")
        assert(pixel(100, 30, CHILD), "the filling paints over the child")
        io.stderr:write("[PASS] the child paints over the filling\n")
        return true
    end,
    function(count)
        if count == 1 then
            child.forced_width = 40
            margin.widget = wibox.layout.fixed.horizontal(border)
            return nil
        end
        check_box(nodes():match("[^\n]*wibox.container.border[^\n]*"), 0, 0, 70, 60)
        assert(pixel(35, 30, CHILD), "the fitted child colour is missing")
        assert(pixel(65, 30, "#00ffff"), "the fitted right side is not cyan")
        assert(pixel(100, 30, BG), "the border paints beyond its fitted width")
        io.stderr:write("[PASS] the border fits its child and padding\n")
        return true
    end,
    function(count)
        if count == 1 then
            border.border_widgets = { left = wibox.container.background(nil, "#0000ff") }
            return nil
        end
        local dump = nodes()

        assert(#images(dump, "10x10") == 8, "the left widget did not replace an image")
        check_box(dump:match("[^\n]*wibox.container.background[^\n]*"), 0, 10, 10, 40)
        assert(pixel(5, 30, "#0000ff"), "the left widget is not blue")
        assert(pixel(5, 5, "#ff0000"), "the left widget paints over the corner")
        io.stderr:write("[PASS] a border widget takes precedence over its image\n")
        return true
    end,
    function(count)
        if count == 1 then
            border.slice = false
            return nil
        end
        local dump = nodes()
        local backgrounds = images(dump, "30x30")

        assert(#backgrounds == 1 and #images(dump, "10x10") == 0,
            "the unsliced border does not hold just the source image")
        check_box(backgrounds[1], 0, 0, 70, 60)
        assert(pixel(5, 5, "#ff0000"), "the unsliced corner is not red")
        assert(pixel(12, 30, "#ffff00"), "the unsliced source is not yellow at the left")
        assert(pixel(35, 30, CHILD), "the unsliced background paints over the child")
        assert(pixel(65, 30, "#00ffff"), "the unsliced right side is not cyan")
        io.stderr:write("[PASS] slice off stretches the source under the child\n")
        return true
    end,
    function(count)
        if count == 1 then
            border.honor_borders = false
            return nil
        end
        local line = nodes():match("[^\n]*wibox.container.border[^\n]*")

        assert(not line, "wibox.container.border was not refused")
        assert(#awesome._test_widget_boxes(bar.drawin) == 3, "the refused subtree still has boxes")
        bar.visible = false
        io.stderr:write("[PASS] honor_borders=false refuses the border\n")
        return true
    end,
}

runner.run_steps(steps)
