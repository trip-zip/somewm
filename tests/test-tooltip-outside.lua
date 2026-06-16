---------------------------------------------------------------------------
--- Test: an outside-mode tooltip anchored to a widget lands adjacent via Clay.
---
--- A tooltip in mode="outside" shown over a widget resolves the widget's box
--- from the screen solve, attaches the tooltip wibox to that widget's Clay
--- element, and one synchronous solve places it. The fit/flip selection stays in
--- Lua (Clay attach has no flip); hiding the tooltip drops it from the solve.
---
--- Runs in the compositor, headless for geometry.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen.primary
local anchor, bar, tt

local function near(actual, expected, label)
    assert(math.abs(actual - expected) <= 1,
        string.format("%s: got %s, expected %s", label, tostring(actual), tostring(expected)))
end

local function anchor_rect()
    local g  = s.geometry
    local ab = s._clay_widget_boxes[anchor]
    return ab.x + g.x, ab.y + g.y, ab.width, ab.height
end

local steps = {
    -- Mount a top wibar whose only widget is a fixed-size anchor; wait for solve.
    function(count)
        if not bar then
            anchor = wibox.widget {
                markup = "ANCHOR", forced_width = 80, forced_height = 18,
                widget = wibox.widget.textbox,
            }
            bar = awful.wibar { position = "top", screen = s, height = 18 }
            bar.widget = wibox.layout.fixed.horizontal(anchor)
            awful.layout.arrange(s)
            return nil
        end
        if not (s._clay_widget_boxes and s._clay_widget_boxes[anchor]) then
            if count >= 40 then error("anchor never recorded in the screen solve") end
            return nil
        end
        return true
    end,

    -- Outside-mode tooltip over the widget lands flush under it.
    function()
        tt = awful.tooltip { text = "TIP", mode = "outside" }
        tt.preferred_positions  = "bottom"
        tt.preferred_alignments = "front"

        local ax, ay, aw, ah = anchor_rect()
        -- Mirror the mouse::enter handler: other = the widget, geo = its rect.
        tt.show(anchor, { x = ax, y = ay, width = aw, height = ah })

        local pg = tt.wibox:geometry()
        near(pg.x, ax,      "tooltip x = anchor left edge")
        near(pg.y, ay + ah, "tooltip y = anchor bottom edge")
        assert(tt.current_position == "bottom",
            "current_position should be bottom, got " .. tostring(tt.current_position))
        io.stderr:write("[TEST] PASS: outside-mode tooltip lands adjacent to its widget anchor\n")
        return true
    end,

    -- Hiding the tooltip drops it from the screen solve.
    function()
        tt.hide()
        assert(not s._clay_popups[tt.wibox], "hidden tooltip must be unregistered")
        io.stderr:write("[TEST] PASS: hiding the tooltip unregisters it from the solve\n")
        return true
    end,

    function()
        io.stderr:write("Test finished successfully.\n")
        awesome.quit()
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
