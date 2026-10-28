-- luacheck: globals screen root awesome
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local BLUE, GREEN, YELLOW = "#0000ff", "#00ff00", "#ffff00"
local failures, below_clicks, box_clicks = {}, 0, 0
local below, box, cut_rows
local function cut(cr, _, h) gshape.rectangle(cr, 60, h) end
local function check(ok, message)
    if not ok then
        failures[#failures + 1] = message
        io.stderr:write("[FAIL] " .. message .. "\n")
    end
end
local function matches(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), box.x + x, box.y + y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12, r, g, b
end
local function pixel(x, y, hex, label)
    local ok, r, g, b = matches(x, y, hex)
    check(ok, string.format("%s: expected %s, got (%d,%d,%d)", label, hex, r, g, b))
end
-- Rows 0 to 2 of the top border inside the path. At scale 1 the cut ring
-- and the uncut scene rect must draw them the same.
local function rows()
    local out = {}
    for y = 0, 2 do
        local _, r, g, b = matches(30, y, BLUE)
        out[#out + 1] = string.format("#%02x%02x%02x", r, g, b)
    end
    return out
end
local function same_rows(label)
    local got = rows()
    for i, hex in ipairs(cut_rows) do
        pixel(30, i - 1, hex, label .. " row " .. (i - 1) .. " matches the cut ring (" .. got[i] .. ")")
    end
end
local function click(x, y)
    local g = s.geometry
    awful.spawn { "./build-test/test-virtual-pointer-client", "click",
        tostring(box.x + x), tostring(box.y + y), tostring(g.width), tostring(g.height) }
end

runner.run_steps {
    function(count)
        if count == 1 then
            s.scale = 1
            local x, y = s.geometry.x + 100, s.geometry.y + 100
            below = wibox { screen = s, x = x - 10, y = y - 10, width = 220, height = 60,
                visible = true, bg = BLUE, shadow = false, border_width = 0 }
            box = wibox { screen = s, x = x, y = y, width = 200, height = 40,
                visible = true, ontop = true, bg = "#ff0000", shadow = false, shape = cut,
                widget = { widget = wibox.container.background, bg = GREEN,
                    border_width = 1, border_color = YELLOW,
                    shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 4) end } }
            below:buttons { awful.button({}, 1, function() below_clicks = below_clicks + 1 end) }
            box:buttons { awful.button({}, 1, function() box_clicks = box_clicks + 1 end) }
            return
        end
        if #awesome._test_widget_boxes(box.drawin) == 0 then
            assert(count < 20, "wibox never converted")
            return
        end
        pixel(30, 20, GREEN, "fill inside the path")
        pixel(30, 0, YELLOW, "top border inside the path")
        pixel(0, 20, YELLOW, "left border inside the path")
        pixel(100, 0, BLUE, "top border past the path")
        pixel(100, 39, BLUE, "bottom border past the path")
        pixel(199, 20, BLUE, "right border past the path")
        cut_rows = rows()
        click(100, 0)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(below_clicks == 1 and box_clicks == 0,
            "click on the border past the path reaches the wibox below")
        box.shape = gshape.rectangle
        return true
    end,
    function(count)
        if not matches(199, 20, YELLOW) and count < 20 then return end
        pixel(100, 0, YELLOW, "top border once the path no longer cuts it")
        pixel(199, 20, YELLOW, "right border once the path no longer cuts it")
        same_rows("scale 1")
        s.scale = 1.5
        box.shape = cut
        return true
    end,
    function(count)
        if not matches(100, 0, BLUE) and count < 20 then return end
        -- root.content scales the raster down to logical pixels. Row 0 is
        -- full yellow only if the hole starts on the device pixel wlroots
        -- rounds the cutout to.
        pixel(30, 0, YELLOW, "top border inside the path at scale 1.5")
        box.visible, below.visible = false, false
        s.scale = 1
        assert(#failures == 0, table.concat(failures, "\n"))
        return true
    end,
}
