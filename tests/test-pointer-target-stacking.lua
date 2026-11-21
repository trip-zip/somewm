---------------------------------------------------------------------------
--- Pointer target scenarios: what is on top at the point gets the event.
---
---  6. xdg popup over a window that is not its parent
---  7. layer surface over a window
---  8. wibox over a window
---  9. window with an input hole over another window
--- 15. a click at a known offset in a window with a titlebar and a border
---
--- Each scenario injects a real click and reads which client received the
--- press, and where (tests/_pointer_probe.lua).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local wibox  = require("wibox")
local probe  = require("_pointer_probe")

if probe.missing() then return end

local BIG, SMALL = probe.BIG, probe.SMALL

runner.run_async(function()
    probe.bind_click_to_activate()

    probe.scenario(6, "xdg popup over a window that is not its parent", function()
        local parent, popup = probe.popup_client({ x = 100, y = 100, width = 200, height = 200 })
        local neighbor = probe.wayland("s6_neighbor", { x = 250, y = 250, width = 300, height = 300 })
        probe.raise_over(neighbor, parent)
        probe.open_popup(parent)
        -- The popup is 120 by 120 and hangs off the parent's bottom-right
        -- content corner, over the neighbor.
        local g, bw = parent.c:geometry(), parent.c.border_width
        local x, y = g.x + bw + g.width + 60, g.y + bw + g.height + 60
        probe.move(x, y)
        assert(probe.wait_for(popup, "^enter popup$"), "the popup never got the pointer")
        return probe.expect_press(function() probe.click(x, y) end, popup)
    end)

    probe.scenario(7, "layer surface over a window", function()
        local window = probe.wayland("s7_window", { x = 20, y = 20, width = 400, height = 300 })
        local layer = probe.layer("s7_layer", "--keyboard none --layer top --anchor top,left --size 200,150")
        local x, y = probe.center(layer)
        local wg = window.c:geometry()
        assert(x > wg.x and x < wg.x + wg.width and y > wg.y and y < wg.y + wg.height,
            "the layer surface is not over the window")
        local ok, detail = probe.expect_press(function() probe.run("click", { x, y }) end, nil)
        local entered = probe.count(layer, "^entered$") > 0
        return ok and entered, detail .. (entered and ", layer got the pointer"
            or ", layer never got the pointer")
    end)

    probe.scenario(8, "wibox over a window", function()
        probe.wayland("s8_window", BIG)
        local box = wibox { x = SMALL.x, y = SMALL.y, width = SMALL.width,
            height = SMALL.height, ontop = true, visible = true, bg = "#aa3333" }
        local presses = 0
        box:connect_signal("button::press", function() presses = presses + 1 end)
        async.sleep(0.2)
        local ok, detail = probe.expect_press(function()
            probe.run("click", { SMALL.x + SMALL.width / 2, SMALL.y + SMALL.height / 2 })
        end, nil)
        box.visible = false
        return ok and presses == 1, detail .. ", wibox presses: " .. presses
    end)

    probe.scenario(9, "window with an input hole over another window", function()
        local below = probe.wayland("s9_below", BIG)
        -- Only the top-left 40 by 40 of the upper window accepts input.
        local top = probe.wayland("s9_hole", SMALL, "--input-region 40x40+0+0")
        probe.raise_over(top, below)
        local x, y = probe.center(top)
        return probe.expect_press(function() probe.click(x, y) end, below)
    end)

    probe.scenario(15, "click at a known offset in a window with a titlebar", function()
        local w = probe.wayland("s15_window", { x = 200, y = 100, width = 600, height = 400 })
        awful.titlebar(w.c, { size = 24, position = "top" })
        async.sleep(0.3)
        local g, bw = w.c:geometry(), w.c.border_width
        local x, y = g.x + bw + 100, g.y + bw + 24 + 70
        local ok, detail = probe.expect_press(function() probe.click(x, y) end, w)
        -- The last position the client was told before the press.
        local sx, sy
        for _, line in ipairs(probe.lines(w)) do
            if line:match("^button %d+ 1$") then break end
            local kx, ky = line:match("^%a+ (%-?%d+) (%-?%d+)$")
            if kx then sx, sy = tonumber(kx), tonumber(ky) end
        end
        local at = sx and math.abs(sx - 100) <= 1 and math.abs(sy - 70) <= 1
        return ok and at, string.format("%s, pressed at (%s, %s), expected (100, 70)",
            detail, tostring(sx), tostring(sy))
    end)

    probe.finish()
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
