---------------------------------------------------------------------------
--- Test: clay.compose_screen owns screen.workarea (Phase 4)
--
-- Verifies that adding/removing wibars at each edge updates screen.workarea
-- via the Clay compose_screen pass, replacing the legacy strut-based path.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

local s = screen.primary
local geo = s.geometry
local wibars = {}

local function eq(a, b, label)
    assert(a == b, string.format("%s: expected %d, got %d", label, b, a))
end

local steps = {
    -- Baseline: no wibars, workarea matches geometry.
    function()
        eq(s.workarea.x,      geo.x,      "baseline workarea.x")
        eq(s.workarea.y,      geo.y,      "baseline workarea.y")
        eq(s.workarea.width,  geo.width,  "baseline workarea.width")
        eq(s.workarea.height, geo.height, "baseline workarea.height")
        return true
    end,

    -- Top wibar: workarea shrinks from the top by wibar height.
    function()
        wibars.top = awful.wibar({ position = "top", screen = s, height = 24 })
        return true
    end,
    function(count)
        if count == 1 then return nil end
        eq(s.workarea.y,      geo.y + 24,         "top wibar workarea.y")
        eq(s.workarea.height, geo.height - 24,    "top wibar workarea.height")
        eq(s.workarea.width,  geo.width,          "top wibar workarea.width")
        wibars.top.visible = false
        wibars.top = nil
        return true
    end,

    -- Bottom wibar: workarea shrinks from the bottom.
    function(count)
        if count == 1 then
            wibars.bottom = awful.wibar({ position = "bottom", screen = s, height = 18 })
            return nil
        end
        if s.workarea.height ~= geo.height - 18 then return nil end
        eq(s.workarea.y,      geo.y,              "bottom wibar workarea.y")
        eq(s.workarea.height, geo.height - 18,    "bottom wibar workarea.height")
        wibars.bottom.visible = false
        wibars.bottom = nil
        return true
    end,

    -- Left + right wibars: workarea shrinks horizontally.
    function(count)
        if count == 1 then
            wibars.left  = awful.wibar({ position = "left",  screen = s, width = 30 })
            wibars.right = awful.wibar({ position = "right", screen = s, width = 40 })
            return nil
        end
        if s.workarea.width ~= geo.width - 70 then return nil end
        eq(s.workarea.x,     geo.x + 30,        "lr workarea.x")
        eq(s.workarea.width, geo.width - 70,    "lr workarea.width")
        eq(s.workarea.y,     geo.y,             "lr workarea.y")
        wibars.left.visible  = false
        wibars.right.visible = false
        wibars.left  = nil
        wibars.right = nil
        return true
    end,

    -- Mixed top + bottom + left wibars together.
    function(count)
        if count == 1 then
            wibars.top    = awful.wibar({ position = "top",    screen = s, height = 20 })
            wibars.bottom = awful.wibar({ position = "bottom", screen = s, height = 22 })
            wibars.left   = awful.wibar({ position = "left",   screen = s, width  = 16 })
            return nil
        end
        local expected_h = geo.height - 20 - 22
        if s.workarea.height ~= expected_h or s.workarea.width ~= geo.width - 16 then
            return nil
        end
        eq(s.workarea.x,      geo.x + 16,    "mixed workarea.x")
        eq(s.workarea.y,      geo.y + 20,    "mixed workarea.y")
        eq(s.workarea.width,  geo.width - 16, "mixed workarea.width")
        eq(s.workarea.height, expected_h,     "mixed workarea.height")

        wibars.top.visible    = false
        wibars.bottom.visible = false
        wibars.left.visible   = false
        return true
    end,

    -- After removing all wibars, workarea returns to geometry.
    function(count)
        if count == 1 then
            awful.layout.arrange(s)
            return nil
        end
        if s.workarea.width ~= geo.width then return nil end
        eq(s.workarea.x,      geo.x,      "cleanup workarea.x")
        eq(s.workarea.y,      geo.y,      "cleanup workarea.y")
        eq(s.workarea.width,  geo.width,  "cleanup workarea.width")
        eq(s.workarea.height, geo.height, "cleanup workarea.height")
        return true
    end,
}

runner.run_steps(steps)
