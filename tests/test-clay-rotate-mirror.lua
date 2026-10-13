-- luacheck: globals screen awesome
---------------------------------------------------------------------------
-- Test: rotate and mirror convert. The compiler rotates the child's
-- description and the renderer rotates its image, text and shape rasters.
--
-- Run: make test-one TEST=tests/test-clay-rotate-mirror.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local gcolor = require("gears.color")
local cairo = require("lgi").cairo

local s = screen[1]
local geo = s.geometry
local X, Y = 100, 100
local cap = capture.new(s, X, Y, 100, 100)
local RED, BLUE = "#ff0000", "#0000ff"
local bar

-- Two halves, red then blue: left and right, or top and bottom.
local function halves(vertical)
    local img = cairo.ImageSurface(cairo.Format.ARGB32, 40, 10)
    local cr = cairo.Context(img)
    cr:set_source(gcolor(RED))
    cr:paint()
    cr:set_source(gcolor(BLUE))
    if vertical then cr:rectangle(0, 5, 40, 5) else cr:rectangle(20, 0, 20, 10) end
    cr:fill()
    return img
end
local strip, stack = halves(false), halves(true)

local function log_contents()
    io.stderr:flush()
    local file = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG")), "r"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function show(widget)
    bar.widget = wibox.container.place(widget, "left", "top")
end

local function box(line)
    local x, y, w, h = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    return tonumber(x) - X, tonumber(y) - Y, tonumber(w), tonumber(h)
end

local function line_with(text)
    return capture.dump_line(s, text)
end

-- Whether each {x, y, colour} is that colour, box-local to line's box.
local function colours(line, points)
    local bx, by = box(line)
    local shot = cap:shot()
    for _, p in ipairs(points) do
        if not cap:near(shot, bx + p[1], by + p[2], p[3]) then return false end
    end
    return true
end

-- Retry until ok() answers the matched dump lines or the 20 count
-- deadline, then fail with what.
local function settle(count, ok, what)
    local lines = ok()
    if lines then
        io.stderr:write("[PASS] " .. what .. "\n" .. lines .. "\n")
        return true
    end
    assert(count < 20, what .. "\n" .. awesome._clay_tree(s))
end

local function image_step(build, word, size, points)
    return function(count)
        if count == 1 then
            show(build())
            return nil
        end
        return settle(count, function()
            local line = line_with(" image image 40x10")
            if not line then return false end
            local has = line:find(" transform ", 1, true) ~= nil
            if word then has = line:find(" transform " .. word .. " ", 1, true) ~= nil
            else has = not has end
            return has and line:find(" " .. size .. "$") and colours(line, points) and line
        end, "image step " .. tostring(word))
    end
end

local function progressbar_step(direction, word, points)
    return function(count)
        if count == 1 then
            show(wibox.container.rotate(wibox.widget {
                value = 0.5, max_value = 1, color = RED, background_color = BLUE,
                forced_width = 40, forced_height = 10, widget = wibox.widget.progressbar,
            }, direction))
            return nil
        end
        return settle(count, function()
            local bar_line = line_with("h=percent(0.5) user")
            local outer = line_with("wibox.container.rotate")
            return bar_line and outer and bar_line:find(" transform " .. word .. " ", 1, true)
                and outer:find(" 10x40$") and colours(outer, points) and bar_line .. "\n" .. outer
        end, "progressbar " .. direction)
    end
end

local steps = {
    function()
        bar = wibox { x = geo.x + X, y = geo.y + Y, width = 100, height = 100,
            screen = s, visible = true, bg = "#202020", fg = RED }
        return true
    end,
    image_step(function() return wibox.container.rotate(wibox.widget.imagebox(strip, false), "east") end,
        "90", "10x40", { {5, 2, BLUE}, {5, 37, RED} }),
    image_step(function() return wibox.container.rotate(wibox.widget.imagebox(strip, false), "west") end,
        "270", "10x40", { {5, 2, RED}, {5, 37, BLUE} }),
    image_step(function() return wibox.container.rotate(wibox.widget.imagebox(strip, false), "south") end,
        "180", "40x10", { {2, 5, BLUE}, {37, 5, RED} }),
    image_step(function() return wibox.container.rotate(wibox.widget.imagebox(strip, false), "north") end,
        nil, "40x10", { {2, 5, RED}, {37, 5, BLUE} }),
    image_step(function()
        return wibox.container.mirror(wibox.widget.imagebox(strip, false), { horizontal = true })
    end, "flipped", "40x10", { {2, 5, BLUE}, {37, 5, RED} }),
    image_step(function()
        return wibox.container.mirror(wibox.widget.imagebox(stack, false), { vertical = true })
    end, "flipped-180", "40x10", { {5, 2, BLUE}, {5, 7, RED} }),
    function(count)
        if count == 1 then
            show(wibox.layout.fixed.vertical(wibox.widget.textbox("Mem 40%"),
                wibox.container.rotate(wibox.widget.textbox("Mem 40%"), "east")))
            return nil
        end
        return settle(count, function()
            local plain, turned
            for line in awesome._clay_tree(s):gmatch("[^\n]+") do
                if line:find('"Mem 40%"', 1, true) then
                    if line:find(" transform 90 ", 1, true) then turned = line else plain = line end
                end
            end
            if not (plain and turned) then return false end
            local _, _, pw, ph = box(plain)
            local bx, by, w, h = box(turned)
            if w ~= ph or h ~= pw then return false end
            local shot = cap:shot()
            for y = by, by + h - 1 do
                for x = bx, bx + w - 1 do
                    if cap:near(shot, x, y, RED) then return plain .. "\n" .. turned end
                end
            end
            return false
        end, "rotated text")
    end,
    progressbar_step("east", "90", { {5, 30, RED}, {5, 10, BLUE} }),
    progressbar_step("west", "270", { {5, 10, RED}, {5, 30, BLUE} }),
    function(count)
        if count == 1 then
            show(wibox.container.rotate(wibox.container.scroll.horizontal(
                wibox.widget.textbox("scrolling")), "east"))
            return nil
        end
        return settle(count, function()
            return log_contents():find("wibox.container.rotate widget holds a wibox.container.scroll", 1, true)
                and not awesome._clay_tree(s):find(" transform ", 1, true)
                and log_contents():match("[^\n]*holds a wibox.container.scroll[^\n]*")
        end, "rotated scroll")
    end,
    function(count)
        if count == 1 then
            bar.visible = false
            bar = wibox { x = geo.x + X, y = geo.y + Y, width = 20, height = 100,
                screen = s, visible = true, bg = "#202020",
                widget = wibox.container.rotate(wibox.widget.imagebox(strip), "east") }
            return nil
        end
        return settle(count, function()
            local line = line_with(" image image 40x10")
            return line and line:find(" transform 90 ", 1, true) and line:find(" 20x80$")
                and colours(line, { {10, 10, BLUE}, {10, 70, RED} }) and line
        end, "rotated image sized by the swapped offer")
    end,
    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)
