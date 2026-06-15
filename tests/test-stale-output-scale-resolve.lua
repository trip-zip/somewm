---------------------------------------------------------------------------
--- Test: an output scale change re-solves the screen, tree==scene intact.
---
--- updatemons marks a screen layout_stale when its output geometry / scale /
--- transform changes (#26), so the next drain re-solves at the new scale with no
--- explicit arrange. Run under SOMEWM_TREE_ASSERT=abort: a fractional scale gives
--- sub-pixel boxes, so a single tiled client must still land exactly on its
--- solved box or the C assert aborts. One client only (fills the workarea, no
--- thin columns that aspect/size-hint clients could clamp away from their box).
---
---   SOMEWM_TREE_ASSERT=abort make test-one TEST=tests/test-stale-output-scale-resolve.lua
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
local wa_before

-- Restore integer scale before bailing so a failure can't leave the screen at
-- 1.5 for the next (PERSISTENT-mode) test.
local function fail(msg) s.scale = 1.0; error(msg) end

local steps = {
    -- Baseline: one tiled client at the current scale.
    function(count)
        if count == 1 then
            tag:view_only()
            tag.layout = awful.layout.suit.tile
            tag.gap = 0
            test_client("stale_scale")
            return nil
        end
        local c = utils.find_client_by_class("stale_scale")
        if not c then
            if count >= 30 then fail("client never appeared") end
            return nil
        end
        if _somewm_clay.is_stale(s) then return nil end
        wa_before = s.workarea
        return true
    end,

    -- Fractional scale change; updatemons must mark the screen and the drain
    -- re-solve. Wait for the logical workarea to change and the drain to settle.
    function(count)
        if count == 1 then
            s.scale = 1.5
            return nil
        end
        if _somewm_clay.is_stale(s) then
            if count >= 30 then fail("scale change never drained") end
            return nil
        end
        local wa = s.workarea
        if wa.width == wa_before.width and wa.height == wa_before.height then
            if count >= 30 then
                fail("workarea unchanged after scale change: "
                    .. wa.width .. "x" .. wa.height)
            end
            return nil
        end
        return true
    end,

    -- The client re-tiled to the new workarea, and (under abort) tree==scene
    -- held through the fractional-scale solve (the compositor is still up).
    function(count)
        local c = utils.find_client_by_class("stale_scale")
        if not c then fail("client vanished") end
        if _somewm_clay.is_stale(s) then return nil end
        if utils.is_tiled_to_workarea(s, c) then
            io.stderr:write("[TEST] PASS: re-tiled at fractional scale, tree==scene held\n")
            return true
        end
        if count >= 30 then
            local wa, g = s.workarea, c:geometry()
            fail(string.format(
                "client not re-tiled after scale change: got %dx%d, workarea %dx%d",
                g.width, g.height, wa.width, wa.height))
        end
        return nil
    end,

    -- Restore integer scale (persistent-mode hygiene).
    function()
        s.scale = 1.0
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
