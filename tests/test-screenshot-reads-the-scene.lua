---------------------------------------------------------------------------
-- Test: screenshots read the scene and nothing else
--
-- root.content() and screen.content composite what the renderer drew:
-- every node of the reconciled Clay tree. A drawin's pixels come from its
-- described tree. A refused widget leaves the drawable background visible.
-- The wallpaper is the tree's wallpaper
-- leaf, root.content(true) leaves it out for a transparent capture, and a
-- translucent drawin captures at its opacity.
--
-- Run: make test-one TEST=tests/test-screenshot-reads-the-scene.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local gcolor = require("gears.color")
local gsurface = require("gears.surface")

local s = screen[1]
local geo = s.geometry
local w, cx, cy

-- R, G, B, A at a layout point, from both readers.
local function root_pixel(x, y, alpha)
    return capture.read(gsurface(root.content(alpha)), x, y)
end

local function screen_pixel(x, y)
    return capture.read(gsurface(s.content), x - geo.x, y - geo.y)
end

local function near(a, b)
    return math.abs(a - b) <= 12
end

-- Whether r, g, b (a reader's result, expanded as the last arguments) is hex.
local function is(hex, r, g, b)
    return near(r, tonumber(hex:sub(2, 3), 16)) and near(g, tonumber(hex:sub(4, 5), 16))
        and near(b, tonumber(hex:sub(6, 7), 16))
end



local steps = {
    -- A refused widget leaves the red drawable background visible.
    function(count)
        if count == 1 then
            local leaf = capture.leaf_widget(120, 40, "#ff0000")
            rawset(leaf, "draw", function() end)
            w = wibox({ x = geo.x + 300, y = geo.y + 200, width = 120, height = 40,
                bg = "#ff0000", visible = true,
                widget = leaf })
            cx, cy = geo.x + 360, geo.y + 220
            return nil
        end
        if is("#ff0000", screen_pixel(cx, cy)) and is("#ff0000", root_pixel(cx, cy)) then
            io.stderr:write("[PASS] a refused widget leaves the red background in the capture\n")
            return true
        end
        assert(count < 15, "the red wibox never reached the capture")
    end,

    -- Replacing the refused widget and background turns the capture blue.
    function(count)
        if count == 1 then
            w.widget = wibox.container.background(wibox.widget.textbox(""), "#0000ff")
            w.bg = "#0000ff"
            return nil
        end
        local r, g, b = screen_pixel(cx, cy)
        local rr, rg, rb = root_pixel(cx, cy)

        if is("#0000ff", r, g, b) and is("#0000ff", rr, rg, rb) then
            io.stderr:write("[PASS] the described wibox captures blue\n")
            return true
        end
        assert(count < 15, string.format(
            "the converted wibox captures #%02x%02x%02x (screen) #%02x%02x%02x (root)",
            r, g, b, rr, rg, rb))
    end,

    -- The wallpaper is the tree's leaf: both readers show it, and the
    -- alpha-preserving root capture leaves it out.
    function(count)
        if count == 1 then
            root.wallpaper(gcolor("#00ff00"))
            return nil
        end
        local x, y = geo.x + 10, geo.y + geo.height - 10

        if not is("#00ff00", screen_pixel(x, y)) or not is("#00ff00", root_pixel(x, y)) then
            assert(count < 15, "the wallpaper never reached the capture")
            return nil
        end
        local _, _, _, a = root_pixel(x, y, true)

        assert(a == 0, "root.content(true) painted the wallpaper: alpha " .. a)
        io.stderr:write("[PASS] the wallpaper is captured from its leaf, and skipped on request\n")
        return true
    end,

    -- A translucent drawin blends each node at its opacity, so the two blue
    -- fills at one half compound over green to blue 192 and green 63.
    function(count)
        if count == 1 then
            w.opacity = 0.5
            return nil
        end
        local r, g, b = screen_pixel(cx, cy)

        if near(r, 0) and near(g, 63) and near(b, 192) then
            io.stderr:write("[PASS] a translucent wibox captures at its opacity\n")
            return true
        end
        assert(count < 15, string.format(
            "the translucent wibox captures #%02x%02x%02x", r, g, b))
    end,
}

runner.run_steps(steps)
