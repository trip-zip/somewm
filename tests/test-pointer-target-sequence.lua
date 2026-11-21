---------------------------------------------------------------------------
--- Pointer target scenarios: events that depend on the one before them.
---
--- 13. one motion and a click that arrive together (touch tap, tablet tip)
--- 14. press inside a window, drag outside it, release
--- 18. the pointer image while a button is held outside its window
--- 19. held pointer coordinates follow a window that moves
---
--- (tests/_pointer_probe.lua)
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local wibox  = require("wibox")
local probe  = require("_pointer_probe")

-- The name of the pointer image in the tree dump, "-" for a client's own.
local function pointer_image()
    for line in awesome._clay_tree(screen[1]):gmatch("[^\n]+") do
        local name = line:match("^  cursor (%S+) w=fixed")
        if name then return name end
    end
end

if probe.missing() then return end

runner.run_async(function()
    probe.bind_click_to_activate()

    probe.scenario(13, "motion and click that arrive together", function()
        local from = probe.wayland("s13_from", { x = 100, y = 100, width = 300, height = 300 })
        local to = probe.wayland("s13_to", { x = 600, y = 100, width = 300, height = 300 })
        async.sleep(0.2)
        local fx, fy = probe.center(from)
        probe.move(fx, fy)
        assert(probe.wait_for(from, "^enter "), "the first window never got the pointer")
        local x, y = probe.center(to)
        return probe.expect_press(function() probe.jumpclick(x, y) end, to)
    end)

    probe.scenario(14, "press inside, drag outside, release", function()
        local w = probe.wayland("s14_window", { x = 300, y = 200, width = 400, height = 300 })
        awful.titlebar(w.c, { size = 24, position = "top" })
        w.c.border_width = 3
        async.sleep(0.3)
        local g, bw = w.c:geometry(), w.c.border_width
        -- The content's origin: inside the border, below the titlebar.
        local ox, oy = g.x + bw, g.y + bw + 24
        local x2, y2 = g.x - 80, g.y - 60
        probe.drag(ox + 100, oy + 100, x2, y2, 300)
        assert(probe.wait_for(w, "^button %d+ 1$"), "the press did not reach the window")
        local released = probe.wait_for(w, "^button %d+ 0$", 5)
        -- The last position the client was told while the button was held.
        local sx, sy, held
        for _, line in ipairs(probe.lines(w)) do
            if line:match("^button %d+ 1$") then held = true end
            if line:match("^button %d+ 0$") then break end
            local kx, ky = line:match("^motion (%-?%d+) (%-?%d+)$")
            if held and kx then sx, sy = tonumber(kx), tonumber(ky) end
        end
        local at = sx and math.abs(sx - (x2 - ox)) <= 1 and math.abs(sy - (y2 - oy)) <= 1
        return released and at, string.format(
            "release %s, last held motion (%s, %s), expected (%d, %d)",
            released and "received" or "missing", tostring(sx), tostring(sy), x2 - ox, y2 - oy)
    end)

    probe.scenario(18, "held button outside the window keeps the pointer image", function()
        local w = probe.wayland("s18_window", { x = 300, y = 200, width = 400, height = 300 })
        local box = wibox { x = 100, y = 60, width = 120, height = 80, visible = true,
                            cursor = "crosshair", bg = "#444444" }
        async.sleep(0.3)
        local before = pointer_image()
        local x, y = probe.center(w)
        -- The window keeps the pointer while the button is held, so the
        -- wibox under the pointer must not set its image.
        probe.drag(x, y, 160, 100, 800)
        local pressed = probe.wait_for(w, "^button %d+ 1$")
        local outside = pressed and probe.wait_for(w, "^motion %-%d+ %-%d+$")
        async.sleep(0.1)
        local held = pointer_image()
        probe.wait_for(w, "^button %d+ 0$", 5)
        -- With the button up, the next motion over the wibox takes its image.
        probe.move(161, 101)
        local after = async.wait_for_condition(function()
            return pointer_image() == "crosshair"
        end, 3)
        box.visible = false
        return pressed and outside and after and held == before, string.format(
            "press %s, held motion outside %s, image before %s, held %s, wibox image after release %s",
            tostring(pressed), tostring(outside), tostring(before), tostring(held), tostring(after))
    end)

    probe.scenario(19, "held coordinates follow a moving decorated window", function()
        local w = probe.wayland("s19_window", { x = 300, y = 200, width = 400, height = 300 })
        awful.titlebar(w.c, { size = 24, position = "top" })
        w.c.border_width = 3
        async.sleep(0.3)
        local g, bw = w.c:geometry(), w.c.border_width
        local ox, oy = g.x + bw, g.y + bw + 24
        local x, y = g.x - 80, g.y - 60
        probe.drag(ox + 100, oy + 100, x, y, 2000)
        assert(probe.wait_for(w, "^button %d+ 1$"), "the press did not reach the window")
        assert(probe.wait_for(w, "^motion %-%d+ %-%d+$"), "the held pointer did not leave the window")

        w.c:geometry { x = g.x + 50, y = g.y + 50 }
        assert(async.wait_for_condition(function()
            local moved = w.c:geometry()
            return moved.x == g.x + 50 and moved.y == g.y + 50
        end, 1, 0.01), "the window did not move")

        local function motion_at(sx, sy)
            local pattern = string.format("^motion %d %d$", sx, sy):gsub("%-", "%%-")
            return probe.wait_for(w, pattern, 0.5)
        end
        -- A completed frame must update held coordinates even without input.
        local stationary = motion_at(x - ox - 50, y - oy - 50)
        probe.run("move", { x + 10, y + 10 })
        local moving = motion_at(x + 10 - ox - 50, y + 10 - oy - 50)
        local released = probe.wait_for(w, "^button %d+ 0$", 5)
        local leaves = probe.count(w, "^leave$")
        return stationary and moving and released and leaves == 0, string.format(
            "stationary coordinates updated %s, moving coordinates updated %s, release %s, leaves %d",
            tostring(stationary), tostring(moving), tostring(released), leaves)
    end)

    probe.finish()
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
