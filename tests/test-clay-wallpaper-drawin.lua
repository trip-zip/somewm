-- luacheck: globals screen root awesome mouse
-- Run: make test-one TEST=tests/test-clay-wallpaper-drawin.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local W, H = geo.width, geo.height
local wall, other

local function pixel(x, y, hex)
    local r, g, b = capture.read(gsurface(root.content()), x, y)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

runner.run_steps {
    function(count)
        if count == 1 then
            wall = awful.wallpaper {
                screen = s,
                bg = { type = "linear", from = { 0, 0 }, to = { W, H },
                    stops = { { 0, "#ff0000" }, { 1, "#0000ff" } } },
                widget = {
                    { bg = "#00ff00", forced_width = 40, forced_height = 40,
                        widget = wibox.container.background },
                    halign = "left", valign = "top", widget = wibox.container.place,
                },
            }
            return nil
        end
        local header = string.format("  drawin screen %d %dx%d+%d+%d converted",
            s.index, W, H, geo.x, geo.y)
        local inside, shape_indent, place = false, nil, false
        for line in awesome._clay_tree(s):gmatch("[^\n]+") do
            if line:sub(1, #header) == header then
                inside = true
            elseif line:match("^  %S") or line:match("^%S") then
                inside = false
            elseif inside then
                if line:find(" shape ", 1, true) then
                    shape_indent = #line:match("^%s+%x+(%s+)")
                elseif shape_indent and #line:match("^%s+%x+(%s+)") > shape_indent
                        and line:match("%S*place w=") then
                    place = true
                end
            end
        end
        if not place then
            assert(count < 20, "the wallpaper never converted with a shape holding place: " .. awesome._clay_tree(s))
            return nil
        end
        local surface = gsurface(root.content())
        local r1, g1, b1 = capture.read(surface, geo.x + 20, geo.y + 20)
        local r2, g2, b2 = capture.read(surface, geo.x + W - 10, geo.y + H - 10)
        local r3, g3, b3 = capture.read(surface, geo.x + 60, geo.y + 60)
        if not (math.abs(r1) <= 12 and math.abs(g1 - 0xff) <= 12 and math.abs(b1) <= 12
                and b2 > 0xc0 and r2 < 0x40 and r3 > 0xc0 and b3 < 0x40) then
            local current = s.geometry
            assert(count < 20, string.format(
                "wallpaper pixels: green (%d,%d) = %d %d %d; bottom (%d,%d) = %d %d %d; "
                    .. "diagonal (%d,%d) = %d %d %d; s.geometry = %dx%d+%d+%d",
                geo.x + 20, geo.y + 20, r1, g1, b1,
                geo.x + W - 10, geo.y + H - 10, r2, g2, b2,
                geo.x + 60, geo.y + 60, r3, g3, b3,
                current.width, current.height, current.x, current.y))
            return nil
        end
        io.stderr:write("[PASS] wallpaper shape holds its widget above the gradient\n")
        return true
    end,
    function()
        mouse.coords({ x = geo.x + W / 2, y = geo.y + H / 2 })
        mouse.coords({ x = geo.x + W / 2, y = geo.y + H / 2 })
        assert(mouse.object_under_pointer() ~= wall._private.wibox.drawin,
            "the wallpaper takes pointer input")
        mouse.coords({ x = geo.x + 100, y = geo.y + 100 })
        io.stderr:write("[PASS] wallpaper passes pointer input through\n")
        return true
    end,
    function(count)
        if count == 1 then
            other = awful.wallpaper { screen = s, bg = "#123456" }
            return nil
        end
        if not pixel(geo.x + 20, geo.y + 20, "#123456") then
            assert(count < 20, "the replacement wallpaper never painted")
            return nil
        end
        assert(wall._private.wibox.visible == false, "the evicted wallpaper is visible")
        assert(other._private.wibox.visible == true, "the replacement wallpaper is hidden")
        io.stderr:write("[PASS] replacement hides the evicted wallpaper\n")
        other:detach()
        return true
    end,
    function(count)
        if other._private.wibox.visible then
            assert(count < 20, "the detached wallpaper is visible")
            return nil
        end
        io.stderr:write("[PASS] detach hides the wallpaper\n")
        return true
    end,
}
