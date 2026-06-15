---------------------------------------------------------------------------
--- Test: a paint-only change (widget color) does not re-solve the screen.
---
--- A wibox bg change emits widget::redraw_needed and repaints, but never
--- widget::layout_changed, so it must not reach awful.layout.arrange: no merged
--- solve, no compose_screen. Run on a Clay-managed tile screen with a tiled
--- client and a wibar in the merged tree (so a spurious re-solve would bump both
--- counters). A contrast step (an explicit arrange does move them) proves the
--- zero in the paint step is real and not a stuck counter. One plain tiled client
--- filling the workarea, so tree==scene holds under abort.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful  = require("awful")
local wibox  = require("wibox")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function counts() return _somewm_clay.get_solve_counts() end

local s = screen.primary
local tag = s.tags[1]
local wb, tb, c_tiled

local steps = {
    -- Clay-managed tile + one tiled client + a wibar with a textbox, at a known
    -- bg so the later change is a real one.
    function(count)
        if count == 1 then
            tag:view_only()
            tag.gap = 0
            tag.layout = require("awful.layout.clay").tile
            tb = wibox.widget.textbox("paint")
            wb = awful.wibar { position = "top", screen = s, height = 24 }
            wb.widget = tb
            wb.bg = "#101010"
            test_client("paint_tiled")
            return nil
        end
        c_tiled = utils.find_client_by_class("paint_tiled")
        if c_tiled and wb.visible and not _somewm_clay.is_stale(s) then return true end
        if count >= 15 then
            error("setup never settled (client=" .. tostring(c_tiled ~= nil)
                .. " stale=" .. tostring(_somewm_clay.is_stale(s)) .. ")")
        end
        return nil
    end,

    -- Paint-only mutation: change the wibox bg (two opaque colors so the
    -- redraw-on-move opacity branch stays off). Across several drained frames the
    -- counters must stay zero: a repaint never re-solves.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            wb.bg = "#202020"
            return nil
        end
        local c = counts()
        assert(c.merged == 0 and c.compose_screen == 0,
            string.format("paint-only change re-solved: merged=%d compose=%d",
                c.merged, c.compose_screen))
        if count >= 4 then return true end
        return nil
    end,

    -- Contrast: an explicit arrange does move the counters, so the zero above is
    -- a real "did not re-solve", not a stuck/broken counter.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(s)
            return nil
        end
        if counts().merged < 1 and count < 12 then return nil end
        assert(counts().merged >= 1,
            "sanity: an explicit arrange must move the counter")
        io.stderr:write("[TEST] PASS: paint-only change did not re-solve; arrange does\n")
        return true
    end,

    -- Cleanup: hide the wibar; the runner's kill step (kill_clients defaults to
    -- true) removes the client and escalates to kill -9 if needed.
    function()
        if wb then wb.visible = false; wb = nil end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
