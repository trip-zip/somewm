---------------------------------------------------------------------------
--- Test: the popup provider machinery (registry -> provider_popups -> emit).
---
--- Stage 2 of the Clay-Way popup work, exercised below the public popup API: a
--- transient surface registered via clay.register_popup is emitted into the
--- screen solve as a Clay floating drawin attached to its anchor widget's
--- element, and clay_apply_all sets its geometry adjacent to that widget. The
--- public popup:move_next_to path (selection + signals) is tested separately.
---
--- Runs in the compositor (a real wibar widget anchor + a real drawin), headless
--- for geometry. Because the popup is now an in-tree drawin, this also passes
--- under SOMEWM_TREE_ASSERT=abort with no allow-list.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local base = require("wibox.widget.base")
local clay = require("awful.layout.clay")

local s = screen.primary
local anchor, bar, popup

local function near(actual, expected, label)
    assert(math.abs(actual - expected) <= 1,
        string.format("%s: got %s, expected %s", label, tostring(actual), tostring(expected)))
end

local steps = {
    -- Mount a top wibar whose only widget is a fixed-size anchor, and wait for
    -- the screen solve to record the anchor's box.
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
        local box = s._clay_widget_boxes and s._clay_widget_boxes[anchor]
        if not box then
            if count >= 40 then error("anchor never recorded in the screen solve") end
            return nil
        end
        return true
    end,

    -- Register a popup anchored below-front of the widget and solve synchronously.
    function()
        popup = wibox { ontop = true, visible = true, width = 120, height = 60 }
        popup.widget = wibox.widget.textbox("POP")

        clay.register_popup(s, popup, {
            anchor_ref    = base.widget_anchor_id(anchor),
            anchor_widget = anchor,
            attach_points = { parent = "left_bottom", element = "left_top" },
            offset        = { x = 0, y = 0 },
            width         = 120, height = 60, z = 100,
        })
        clay.compose_screen(s)

        -- The anchor box is solve-local (0-based); the popup drawin geometry is
        -- absolute (Clay box + screen offset). Rebase the anchor to absolute.
        local g  = s.geometry
        local ab = s._clay_widget_boxes[anchor]
        local ax, ay = ab.x + g.x, ab.y + g.y
        local pg = popup:geometry()

        near(pg.x, ax,                "popup x = anchor left (absolute)")
        near(pg.y, ay + ab.height,    "popup y = anchor bottom (absolute)")
        near(pg.width, 120,           "popup width from the floating config")
        near(pg.height, 60,           "popup height from the floating config")
        io.stderr:write("[TEST] PASS: registered popup lands adjacent to its anchor widget\n")
        return true
    end,

    -- Unregister and re-solve: the popup drops out of the screen solve.
    function()
        clay.unregister_popup(s, popup)
        clay.compose_screen(s)
        assert(s._clay_popups[popup] == nil, "popup must be deregistered")
        io.stderr:write("[TEST] PASS: unregister_popup drops the popup from the solve\n")
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
