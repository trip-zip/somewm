-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-checkbox.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, checkbox
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
            checkbox = wibox.widget {
                checked = false, bg = "#00ff00", border_width = 2,
                border_color = "#0000ff", color = "#ff0000",
                widget = wibox.widget.checkbox,
            }
            assert(checkbox.fit == checkbox._clay.fit, "the checkbox fit identity differs")
            -- The empty margin hands the checkbox the whole wibox box.
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 40,
                screen = s, visible = true, bg = BG,
                widget = wibox.container.margin(checkbox) }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the checkbox never converted")
            return nil
        end
        local dump = awesome._clay_tree(s)
        local _, shapes = dump:gsub("[^\n]* shape[^\n]*", "")
        assert(shapes == 1, "the unchecked checkbox does not have one shape leaf")
        check_box(dump:match("[^\n]* shape[^\n]*"), 0, 0, 200, 40)
        assert(pixel(1, 20, "#0000ff"), "the left outline is not blue")
        assert(pixel(38, 20, "#0000ff"), "the right outline is not blue")
        assert(pixel(20, 20, "#00ff00"), "the outline fill is not green")
        assert(pixel(100, 20, BG), "the checkbox paints beyond its square")
        io.stderr:write("[PASS] the outline spans the box and paints its square\n")
        return true
    end,
    function(count)
        if count == 1 then
            checkbox.checked = true
            return nil
        end
        local _, shapes = awesome._clay_tree(s):gsub("[^\n]* shape[^\n]*", "")
        assert(shapes == 2, "the checked checkbox does not have two shape leaves")
        assert(pixel(20, 20, "#ff0000"), "the check is not red")
        assert(pixel(1, 20, "#0000ff"), "the check hides the blue outline")
        io.stderr:write("[PASS] the red check preserves the blue outline\n")
        return true
    end,
    function(count)
        if count == 1 then
            checkbox.check_shape = gshape.circle
            return nil
        end
        assert(pixel(20, 20, "#ff0000"), "the circular check centre is not red")
        assert(pixel(3, 3, "#00ff00"), "the circular check hides the green corner")
        io.stderr:write("[PASS] the circular check leaves the green corner visible\n")
        return true
    end,
    function(count)
        if count == 1 then
            checkbox.shape = gshape.circle
            return nil
        end
        assert(pixel(20, 1, "#0000ff"), "the circular outline top is not blue")
        assert(pixel(2, 2, BG), "the circular outline paints outside its circle")
        assert(pixel(20, 20, "#ff0000"), "the circular checkbox centre is not red")
        io.stderr:write("[PASS] the circular outline preserves the check and wibox corner\n")
        return true
    end,
    function(count)
        if count == 1 then
            checkbox.checked = false
            return nil
        end
        local _, shapes = awesome._clay_tree(s):gsub("[^\n]* shape[^\n]*", "")
        assert(shapes == 1, "unchecking does not leave one shape leaf")
        assert(pixel(20, 20, "#00ff00"), "unchecking does not reveal the green fill")
        bar.visible = false
        io.stderr:write("[PASS] unchecking removes the check and reveals the green fill\n")
        return true
    end,
}

runner.run_steps(steps)
