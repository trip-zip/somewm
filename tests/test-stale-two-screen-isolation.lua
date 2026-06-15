---------------------------------------------------------------------------
--- Test: a throwing recompute on one screen does not block another.
---
--- clay_drain_stale_screens clears each screen's flag and recomputes it under
--- its own protected call, so an error solving the first screen cannot abort the
--- drain loop or leave the next screen stale. The drain walks screens in index
--- order, so a boom layout on the primary (drained first) throws before the
--- second screen is reached; if the throw broke the loop the second screen would
--- stay stale. Both flags clearing proves per-screen isolation.
---
--- Default warn mode (the boom screen has no valid solve).
---------------------------------------------------------------------------

local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")

assert(_somewm_clay, "this test requires the Clay engine (_somewm_clay)")

local sa = screen.primary   -- drained first; boom -> throws
local sb                    -- fake second screen; tile -> must still drain
local ta, ta_layout

-- Idempotent teardown so a failing step never leaks the fake screen or leaves
-- the primary on the throwing layout into the next (PERSISTENT-mode) test.
local function cleanup()
    if ta and ta.valid and ta_layout then ta.layout = ta_layout end
    if sb and sb.valid then sb:fake_remove() end
    sb = nil
end
local function fail(msg) cleanup(); error(msg) end

local steps = {
    -- Add a second screen, put boom on the primary and tile on the second, and
    -- mark both stale.
    function()
        local g = sa.geometry
        sb = screen.fake_add(g.x + g.width, g.y, 800, 600)
        if not (sb and sb.valid) then fail("fake_add failed") end

        ta = sa.tags[1]
        ta_layout = ta.layout
        local tb = awful.tag.add("iso_b",
            { screen = sb, layout = awful.layout.suit.tile })
        if not tb then fail("could not create a tag on the second screen") end
        tb:view_only()

        ta.layout = utils.boom_layout
        awful.layout.arrange(sa)
        awful.layout.arrange(sb)
        return true
    end,

    -- One drain pass must clear both flags. Teardown runs before the asserts so a
    -- failure cannot leak the fake screen.
    function(count)
        if _somewm_clay.is_stale(sa) or _somewm_clay.is_stale(sb) then
            if count >= 20 then
                fail(string.format("drain stuck: primary stale=%s second stale=%s",
                    tostring(_somewm_clay.is_stale(sa)),
                    tostring(_somewm_clay.is_stale(sb))))
            end
            return nil
        end
        local ok_a = sa._clay_arrange_pending == nil
        local ok_b = sb._clay_arrange_pending == nil
        local ok_valid = sb.valid
        cleanup()
        assert(ok_a, "primary pending flag stuck")
        assert(ok_b, "second-screen pending flag stuck")
        assert(ok_valid, "second screen went away unexpectedly")
        io.stderr:write("[TEST] PASS: a throwing screen did not block the other\n")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
