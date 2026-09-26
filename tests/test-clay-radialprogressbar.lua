-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-radialprogressbar.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, progress
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
            progress = wibox.widget {
                value = 0.6, color = "#ff0000", border_color = "#0000ff",
                border_width = 4, paddings = 2,
                widget = wibox.container.radialprogressbar,
            }
            -- The empty margin hands the progressbar the whole wibox box.
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(progress) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the radialprogressbar never converted")
            return nil
        end
        local dump = awesome._clay_tree(s)
        local shapes = 0
        for line in dump:gmatch("[^\n]* shape[^\n]*") do
            shapes = shapes + 1
            check_box(line, 0, 0, 200, 40)
        end
        assert(shapes == 2, "the radialprogressbar does not have two shape leaves")
        assert(pixel(100, 2, "#0000ff"), "the top outline is not blue")
        assert(pixel(100, 38, "#ff0000"), "the bottom progress is not red")
        assert(pixel(198, 20, "#ff0000"), "the right arc is not red")
        assert(pixel(2, 20, "#0000ff"), "the left arc is not blue")
        io.stderr:write("[PASS] the arcs span the box\n")
        return true
    end,
    function(count)
        if count == 1 then
            progress.value = 1
            return nil
        end
        assert(pixel(100, 2, "#ff0000"), "the full top progress is not red")
        assert(pixel(2, 20, "#ff0000"), "the full left arc is not red")
        io.stderr:write("[PASS] full progress covers the top and left outline\n")
        return true
    end,
    function(count)
        if count == 1 then
            progress.value = 0
            return nil
        end
        assert(pixel(100, 38, "#0000ff"), "zero progress hides the bottom outline")
        assert(pixel(198, 20, "#0000ff"), "zero progress hides the right outline")
        io.stderr:write("[PASS] zero progress reveals the blue outline\n")
        return true
    end,
    function(count)
        if count == 1 then
            progress.widget = wibox.container.background(wibox.widget.textbox("x"), "#00ff00")
            return nil
        end
        -- The content spacer opens its clip scope once it has a child.
        check_box(awesome._clay_tree(s):match("[^\n]* spacer clip[^\n]*"), 4, 4, 192, 32)
        assert(pixel(100, 20, "#00ff00"), "the child centre is not green")
        assert(pixel(100, 2, "#0000ff"), "the child hides the blue outline")
        assert(pixel(5, 5, BG), "the child paints outside its pill")
        bar.visible = false
        io.stderr:write("[PASS] the child is clipped to its pill below the outline\n")
        return true
    end,
}

runner.run_steps(steps)
