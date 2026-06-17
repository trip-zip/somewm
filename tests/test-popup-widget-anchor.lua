---------------------------------------------------------------------------
--- Test: popup:move_next_to(widget) lands adjacent via the Clay attach path.
---
--- The public API (awful.popup + move_next_to with a find_widgets-style anchor)
--- resolves the anchor's box from the screen solve, attaches the popup to that
--- widget's Clay element, and one synchronous solve places it. Three cases:
---   1. Adjacency -- preferred "bottom" puts the popup flush under the widget.
---   2. Flip -- preferred "top" off a top-bar widget cannot fit, so the Lua
---      fit/flip selection falls through to "bottom" (Clay itself never flips).
---   3. Bottom-bar strut -- a widget in a bottom bar: a strut-ward popup
---      ("right") places flush beside it in the strip via element-attach,
---      not flipping into the workarea.
---
--- The anchors sit in margined bars (each box is inside its strip, outside the
--- workarea), so a popup flush to the widget edge attaches to the element only
--- when the fit is bound to the screen geometry rather than the workarea (#69);
--- otherwise it would decline and fall back to legacy next_to.
---
--- Runs in the compositor, headless for geometry. The popup is an in-tree drawin
--- so this also holds under SOMEWM_TREE_ASSERT=abort.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen.primary
local anchor, bar, pop, pop_flip
local anchor2, bar2, pop2

local function near(actual, expected, label)
    assert(math.abs(actual - expected) <= 1,
        string.format("%s: got %s, expected %s", label, tostring(actual), tostring(expected)))
end

-- Absolute anchor rect from the last solve (boxes are solve-local / 0-based).
local function anchor_rect(w)
    local g  = s.geometry
    local ab = s._clay_widget_boxes[w or anchor]
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
            -- Margined bar: the 3px inset puts the anchor's box bottom edge above
            -- the workarea boundary, inside the strip (the #69 condition).
            bar = awful.wibar { position = "top", screen = s, height = 24 }
            bar.widget = wibox.layout.fixed.horizontal(
                wibox.container.margin(anchor, 0, 0, 3, 3))
            awful.layout.arrange(s)
            return nil
        end
        if not (s._clay_widget_boxes and s._clay_widget_boxes[anchor]) then
            if count >= 40 then error("anchor never recorded in the screen solve") end
            return nil
        end
        return true
    end,

    -- 1. Adjacency: preferred "bottom"/"front" -> popup flush under the widget.
    function()
        pop = awful.popup {
            widget = wibox.widget.textbox("POPUP-CONTENT"),
            ontop = true, visible = false,
            preferred_positions = "bottom",
            preferred_anchors   = "front",
        }
        pop:move_next_to({ widget = anchor })

        local ax, ay, _, ah = anchor_rect()
        local pg = pop:geometry()
        near(pg.x, ax,      "popup x = anchor left edge")
        near(pg.y, ay + ah, "popup y = anchor bottom edge")
        assert(pop.current_position == "bottom",
            "current_position should be bottom, got " .. tostring(pop.current_position))
        assert(pop.current_anchor == "front",
            "current_anchor should be front, got " .. tostring(pop.current_anchor))
        -- #69: a margined-bar anchor places via element-attach, not next_to.
        assert(s._clay_popups[pop],
            "margined-bar anchor must place via element-attach, not fall back")
        -- #50: the placement is recorded and the stale marker cleared.
        assert(pop._private.clay_anchor_widget == anchor,
            "popup should remember its anchor widget for re-placement")
        assert(pop._private._clay_place_stale == false,
            "popup _clay_place_stale should be cleared after placement")
        io.stderr:write("[TEST] PASS: move_next_to(widget) lands adjacent (below-front)\n")
        return true
    end,

    -- 2. Flip: preferred "top" cannot fit above a top-bar widget, so the Lua
    --    selection flips to "bottom" (Clay attach has no fit/flip of its own).
    function()
        pop_flip = awful.popup {
            widget = wibox.widget.textbox("FLIP"),
            ontop = true, visible = false,
            preferred_positions = { "top", "bottom" },
            preferred_anchors   = "front",
        }
        pop_flip:move_next_to({ widget = anchor })

        local ax, ay, _, ah = anchor_rect()
        local pg = pop_flip:geometry()
        assert(pop_flip.current_position == "bottom",
            "preferred top must flip to bottom near the top edge, got "
            .. tostring(pop_flip.current_position))
        near(pg.x, ax,      "flipped popup x = anchor left edge")
        near(pg.y, ay + ah, "flipped popup y = anchor bottom edge")
        io.stderr:write("[TEST] PASS: move_next_to flips when the preferred side does not fit\n")
        return true
    end,

    -- Mount a bottom wibar with a margined anchor (its box sits in the bottom
    -- strut); wait for the solve to record it.
    function(count)
        if not bar2 then
            anchor2 = wibox.widget {
                markup = "ANCHOR2", forced_width = 80, forced_height = 18,
                widget = wibox.widget.textbox,
            }
            bar2 = awful.wibar { position = "bottom", screen = s, height = 24 }
            bar2.widget = wibox.layout.fixed.horizontal(
                wibox.container.margin(anchor2, 0, 0, 3, 3))
            awful.layout.arrange(s)
            return nil
        end
        if not (s._clay_widget_boxes and s._clay_widget_boxes[anchor2]) then
            if count >= 40 then error("bottom-bar anchor never recorded in the screen solve") end
            return nil
        end
        return true
    end,

    -- 3. Bottom-bar strut: a strut-ward popup ("right") off the bottom-bar widget
    --    places flush beside it in the strip via element-attach. Under s.workarea
    --    every side overlapped a strut and it fell back to next_to; s.geometry
    --    lets it attach (#69).
    function()
        pop2 = awful.popup {
            widget = wibox.widget {
                markup = "P2", forced_width = 60, forced_height = 18,
                widget = wibox.widget.textbox,
            },
            ontop = true, visible = false,
            preferred_positions = "right",
            preferred_anchors   = "front",
        }
        pop2:move_next_to({ widget = anchor2 })

        local ax, ay, aw = anchor_rect(anchor2)
        local pg = pop2:geometry()
        assert(s._clay_popups[pop2],
            "bottom-bar anchor must place via element-attach, not fall back")
        assert(pop2.current_position == "right",
            "bottom-bar popup must place strut-ward (right), not flip, got "
            .. tostring(pop2.current_position))
        near(pg.x, ax + aw, "bottom-bar popup x = anchor right edge")
        near(pg.y, ay,      "bottom-bar popup y = anchor top edge (front)")
        io.stderr:write("[TEST] PASS: bottom-bar anchor places flush in the strip via element-attach\n")
        return true
    end,

    -- 4. Re-anchoring a still-visible popup to a non-widget (a bare geometry)
    --    must NOT fall back to the remembered widget: it takes the legacy path
    --    and drops the Clay registration.
    function()
        pop:move_next_to({ x = 400, y = 400, width = 10, height = 10 })
        assert(not s._clay_popups[pop],
            "re-anchoring to a non-widget must unregister the popup")
        assert(pop._private.clay_anchor_widget == nil,
            "re-anchoring to a non-widget must clear the remembered anchor")
        io.stderr:write("[TEST] PASS: re-anchor to a non-widget drops the Clay anchor\n")
        return true
    end,

    -- 5. Hiding the popup drops it from the screen solve.
    function()
        pop_flip.visible = false
        assert(not s._clay_popups[pop_flip], "hidden popup must be unregistered")
        io.stderr:write("[TEST] PASS: hiding a popup unregisters it from the solve\n")
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
