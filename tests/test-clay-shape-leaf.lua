-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-shape-leaf.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, other, separator, box
local errors = {}
local BG = "#204080"

local function on_error(err)
    errors[#errors + 1] = tostring(err)
end

local function pixel(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), x, y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

local function centre(hex)
    return pixel(box.x + box.w / 2, box.y + box.h / 2, hex)
end

local function saw_error(message)
    for _, err in ipairs(errors) do
        if err:find(message, 1, true) then
            return true
        end
    end
    return false
end

local steps = {
    function(count)
        if count == 1 then
            separator = wibox.widget.separator { shape = gshape.circle, color = "#ff0000" }
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 80, height = 80,
                screen = s, visible = true, bg = BG, widget = separator }
            return nil
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            assert(count < 20, "the separator never converted")
            return nil
        end
        local line = awesome._clay_tree(s):match("[^\n]* shape [^\n]*")
        assert(line, "the dump has no shape leaf")
        local x, y, w, h = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
        assert(x, "the shape leaf has no box: " .. line)
        box = { x = geo.x + tonumber(x), y = geo.y + tonumber(y),
            w = tonumber(w), h = tonumber(h) }
        assert(centre("#ff0000"), "the circle centre is not red")
        assert(pixel(box.x + 1, box.y + 1, BG), "the circle corner hides the background")
        io.stderr:write("[PASS] the shape leaf draws a red circle with clear corners\n")
        return true
    end,
    function(count)
        if count == 1 then
            separator.color = "#00ff00"
            return nil
        end
        if centre("#00ff00") then
            io.stderr:write("[PASS] changing fill turns the centre green\n")
            return true
        end
        assert(count < 20, "the centre never turned green")
    end,
    function(count)
        if count == 1 then
            separator.shape = gshape.rectangle
            return nil
        end
        if pixel(box.x + 1, box.y + 1, "#00ff00") then
            io.stderr:write("[PASS] changing shape turns the corner green\n")
            return true
        end
        assert(count < 20, "the rectangle never filled the corner")
    end,
    function(count)
        if count == 1 then
            separator.border_width = 4
            separator.border_color = "#0000ff"
            return nil
        end
        if pixel(box.x + 1, box.y + box.h / 2, "#0000ff") then
            io.stderr:write("[PASS] the shape stroke paints the edge blue\n")
            return true
        end
        assert(count < 20, "the stroke never painted the edge blue")
    end,
    function(count)
        if count == 1 then
            awesome.connect_signal("debug::error", on_error)
            separator.shape = function() bar.opacity = 0.5 end
            return nil
        end
        if saw_error("widget tree changed from inside a frame") and centre(BG) then
            io.stderr:write("[PASS] opacity reentry raises and the leaf draws nothing\n")
            bar.opacity = 1
            separator.shape = gshape.rectangle
            return true
        end
        assert(count < 20, "opacity reentry did not raise and leave an empty leaf")
    end,
    function(count)
        if not centre("#00ff00") then
            assert(count < 20, "the shape did not recover after opacity reentry")
            return nil
        end
        other = wibox { x = geo.x + 220, y = geo.y + 100, width = 40, height = 40,
            screen = s, visible = true, bg = BG, widget = wibox.widget.separator {
                shape = gshape.rectangle, color = "#ff0000" } }
        return true
    end,
    function(count)
        if #awesome._test_widget_boxes(other.drawin) == 0 then
            assert(count < 20, "the second wibox never converted")
            return nil
        end
        separator.shape = function() other.visible = false end
        return true
    end,
    function(count)
        if saw_error("drawin visibility changed from inside a frame") and centre(BG) then
            assert(other.visible, "the callback hid the second wibox")
            assert(pixel(other.x + 20, other.y + 20, "#ff0000"),
                "the second wibox did not finish rendering")
            io.stderr:write("[PASS] visibility reentry raises and both drawins survive the frame\n")
            separator.shape = gshape.rectangle
            return true
        end
        assert(count < 20, "visibility reentry did not raise and leave an empty leaf")
    end,
    function(count)
        if centre("#00ff00") then
            assert(pixel(box.x + 1, box.y + box.h / 2, "#0000ff"),
                "the stroke did not recover after reentry")
            awesome.disconnect_signal("debug::error", on_error)
            bar.visible = false
            other.visible = false
            io.stderr:write("[PASS] shape rendering recovers after rejected mutations\n")
            return true
        end
        assert(count < 20, "the shape did not recover after visibility reentry")
    end,
}

runner.run_steps(steps)
