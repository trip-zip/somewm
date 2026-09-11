-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-grid.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, g
local BG = "#204080"

local function pixel(x, y, hex)
    local r, green, b = capture.read(gsurface(root.content()), bar.x + x, bar.y + y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(green - tonumber(hex:sub(4, 5), 16)) <= 12
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
            g = wibox.layout.grid()
            g.spacing = 5
            local a = wibox.widget { bg = "#ff0000", forced_width = 20, forced_height = 10,
                widget = wibox.container.background }
            local b = wibox.widget { bg = "#00ff00", forced_width = 40, forced_height = 10,
                widget = wibox.container.background }
            local c = wibox.widget { bg = "#0000ff", forced_width = 20, forced_height = 20,
                widget = wibox.container.background }
            local d = wibox.widget { bg = "#ffff00", forced_width = 30, forced_height = 10,
                widget = wibox.container.background }
            g:add_widget_at(a, 1, 1)
            g:add_widget_at(b, 1, 2)
            g:add_widget_at(c, 2, 1)
            g:add_widget_at(d, 3, 1, 1, 2)
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 100,
                screen = s, visible = true, bg = BG, widget = g }
            return nil
        end
        local head, dump = nodes()
        if not head or not head:find("converted:", 1, true) then
            assert(count < 20, "the grid never converted: " .. (head or "no drawin"))
            return nil
        end
        local bg = backgrounds(dump)
        check_box(bg[1], 0, 0, 40, 20)
        check_box(bg[2], 45, 0, 40, 20)
        check_box(bg[3], 0, 25, 40, 20)
        check_box(bg[4], 0, 50, 85, 20)
        assert(pixel(10, 10, "#ff0000"), "A is not red")
        assert(pixel(50, 10, "#00ff00"), "B is not green")
        assert(pixel(42, 10, BG), "the gap is not background")
        assert(pixel(10, 35, "#0000ff"), "C is not blue")
        assert(pixel(50, 35, BG), "the hole is not background")
        assert(pixel(60, 60, "#ffff00"), "D is not yellow")
        assert(pixel(100, 10, BG), "the grid paints beyond its columns")
        io.stderr:write("[PASS] homogeneous grid aligns cells, holes and a column span\n")
        return true
    end,
    function(count)
        if count == 1 then
            g.expand = true
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        check_box(bg[1], 0, 0, 97, 30)
        check_box(bg[2], 102, 0, 97, 30)
        check_box(bg[3], 0, 35, 97, 30)
        check_box(bg[4], 0, 70, 199, 30)
        assert(pixel(150, 10, "#00ff00"), "expanded B is not green")
        assert(pixel(10, 50, "#0000ff"), "expanded C is not blue")
        assert(pixel(150, 80, "#ffff00"), "expanded D is not yellow")
        io.stderr:write("[PASS] expanded grid shares the drawin's width and height\n")
        return true
    end,
    function(count)
        if count == 1 then
            g.expand = false
            g.homogeneous = false
            return nil
        end
        local _, dump = nodes()
        local bg = backgrounds(dump)
        check_box(bg[1], 0, 0, 20, 10)
        check_box(bg[2], 25, 0, 40, 10)
        check_box(bg[3], 0, 15, 20, 20)
        check_box(bg[4], 0, 40, 65, 10)
        assert(pixel(30, 5, "#00ff00"), "measured B is not green")
        assert(pixel(22, 5, BG), "the measured gap is not background")
        assert(pixel(5, 25, "#0000ff"), "measured C is not blue")
        assert(pixel(30, 45, "#ffff00"), "measured D is not yellow")
        io.stderr:write("[PASS] non-homogeneous grid keeps measured columns and rows\n")
        return true
    end,
    function(count)
        if count == 1 then
            bar.visible = false
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 300, height = 220,
                screen = s, visible = true, bg = BG,
                widget = wibox.widget.calendar.month(os.date("*t")) }
            return nil
        end
        local head, dump = nodes()
        if not head or not head:find("converted:", 1, true) then
            assert(count < 20, "the calendar never converted: " .. (head or "no drawin"))
            return nil
        end
        assert(head:match("converted: %d+ nodes, 0 images"), "the calendar has image nodes: " .. head)
        local textboxes = {}
        for line in dump:gmatch("[^\n]* wibox%.widget%.textbox [^\n]*") do
            textboxes[#textboxes + 1] = line
        end
        assert(#textboxes >= 36, "the calendar has fewer than 36 textboxes")
        local header_width = textboxes[1]:match("box %-?%d+,%-?%d+ (%d+)x%d+")
        local first_x = textboxes[2]:match("box (%-?%d+),")
        local last_x, last_width = textboxes[8]:match("box (%-?%d+),%-?%d+ (%d+)x%d+")
        assert(tonumber(header_width) == tonumber(last_x) + tonumber(last_width) - tonumber(first_x),
            "the header does not span the weekday row")
        io.stderr:write("[PASS] calendar converts its textboxes and spans the weekday row\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
