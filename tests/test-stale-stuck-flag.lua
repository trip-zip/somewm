---------------------------------------------------------------------------
--- Test: a throwing layout cannot wedge the stale-flag drain.
---
--- The old arrange used a global lock that a mid-arrange error could leave
--- stuck. The drain has no lock: clay_drain_stale_screens clears each screen's
--- layout_stale flag BEFORE calling awful.layout._recompute_screen, whose body
--- is a protected call, and which clears _clay_arrange_pending and emits
--- "arrange" outside that protected call. So a layout whose arrange() errors
--- must keep the compositor up, leave layout_stale false and _clay_arrange_pending
--- nil, and not block the next (good) arrange from tiling.
---
--- Runs under the default warn mode: the boom layout leaves its screen with no
--- valid solve, which would (correctly) report under tree==scene abort.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

assert(_somewm_clay, "this test requires the Clay engine (_somewm_clay)")

local s = screen.primary
local tag = s.tags[1]

local steps = {
    -- Baseline: one client tiled by clay.tile.
    function(count)
        if count == 1 then
            tag:view_only()
            tag.layout = awful.layout.suit.tile
            tag.gap = 0
            test_client("stale_stuck")
            return nil
        end
        return utils.find_client_by_class("stale_stuck") and true or nil
    end,

    -- Switch to the throwing layout and arrange. The drain must catch the error
    -- and clear both flags; the compositor must stay up.
    function(count)
        if count == 1 then
            tag.layout = utils.boom_layout
            awful.layout.arrange(s)
            return nil
        end
        if _somewm_clay.is_stale(s) then
            if count >= 20 then
                error("layout_stale never cleared after a throwing recompute")
            end
            return nil
        end
        -- Reaching here means the compositor survived the throw and drained.
        assert(s._clay_arrange_pending == nil,
            "_clay_arrange_pending must clear even when arrange() throws")
        return true
    end,

    -- Recovery: a good layout arranges normally and the client tiles to the
    -- workarea, proving the throw did not wedge the mechanism.
    function(count)
        if count == 1 then
            tag.layout = awful.layout.suit.tile
            awful.layout.arrange(s)
            return nil
        end
        local c = utils.find_client_by_class("stale_stuck")
        if not c or _somewm_clay.is_stale(s) then return nil end
        if utils.is_tiled_to_workarea(s, c) then
            io.stderr:write("[TEST] PASS: recovered to tiled geometry after a throw\n")
            return true
        end
        if count >= 20 then
            local wa, g = s.workarea, c:geometry()
            error(string.format(
                "client did not recover to tiled geometry: got %dx%d, workarea %dx%d",
                g.width, g.height, wa.width, wa.height))
        end
        return nil
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
