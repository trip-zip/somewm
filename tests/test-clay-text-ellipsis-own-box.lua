-- luacheck: globals screen awesome
---------------------------------------------------------------------------
-- Test: a textbox ellipsizes only where its own box cuts its run. A scroll's
-- viewport moves the run through it, and a run whose box rounds past its
-- solved end at a fractional scale is whole.
--
-- Run: make test-one TEST=tests/test-clay-text-ellipsis-own-box.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local LONG = "A line of text much longer than the space it scrolls through"
local WORDS = { "Rotate", "Rotated", "Rotation", "Sideways", "Turned", "Column", "Vertical", "West" }
local boxes = {}

local function label(text, ellipsize)
    return wibox.widget { text = text, font = "sans 14", ellipsize = ellipsize,
        widget = wibox.widget.textbox }
end

local function box(x, y, width, height, widget)
    local w = wibox { x = geo.x + x, y = geo.y + y, width = width, height = height,
        screen = s, visible = true, bg = "#202020", fg = "#ffffff", widget = widget }
    boxes[#boxes + 1] = w
    return w
end

local function hide()
    for _, w in ipairs(boxes) do w.visible = false end
    boxes = {}
end

-- How many pixels of a shot are lit.
local function ink(cap, shot)
    local lit = 0
    for y = 0, cap.height - 1 do
        for x = 0, cap.width - 1 do
            if cap:pixel(shot, x, y) > 0x80 then lit = lit + 1 end
        end
    end
    return lit
end

-- Both regions lit and the same within rounding; an empty frame is equal too.
local function same(a, b)
    local sa, sb = a:shot(), b:shot()
    if ink(a, sa) <= 30 or ink(b, sb) <= 30 then return false end
    for i = 1, #sa do
        if math.abs(sa:byte(i) - sb:byte(i)) > 2 then return false end
    end
    return true
end

local steps = {
    -- The scroll never moves, so its viewport shows the run's first 200
    -- pixels. A wide wibox shows the same run uncut.
    function(count)
        if count == 1 then
            box(50, 50, 200, 30, wibox.container.scroll.horizontal(label(LONG), nil, 1, nil, nil, 200,
                function() return 0 end))
            box(50, 100, 800, 30, wibox.container.place(label(LONG), "left", "top"))
            return nil
        end
        if not same(capture.new(s, 50, 50, 200, 30), capture.new(s, 50, 100, 200, 30)) then
            assert(count < 20, "the scrolled run is cut at its viewport\n" .. awesome._clay_tree(s))
            return nil
        end
        hide()
        io.stderr:write("[PASS] a scrolled textbox draws its whole run through the viewport\n")
        return true
    end,
    -- At 1.5 an odd logical y is half a device pixel. A run whose device
    -- length is odd then ends a third of a logical pixel short of its box,
    -- which rounds past that end.
    function(count)
        if count == 1 then
            s.scale = 1.5
            for i, word in ipairs(WORDS) do
                for col, ellipsize in ipairs { "end", "none" } do
                    box(20 + (i - 1) * 50 + (col - 1) * 400, 41, 40, 140, wibox.container.place(
                        wibox.container.rotate(label(word, ellipsize), "west"), "left", "top"))
                end
            end
            return nil
        end
        for i in ipairs(WORDS) do
            local x = 20 + (i - 1) * 50
            if not same(capture.new(s, x, 41, 40, 140), capture.new(s, x + 400, 41, 40, 140)) then
                assert(count < 20, "the rotated " .. WORDS[i] .. " is ellipsized\n" .. awesome._clay_tree(s))
                return nil
            end
        end
        hide()
        io.stderr:write("[PASS] rotated words at scale 1.5 are drawn whole\n")
        return true
    end,
}

runner.run_steps(steps)
