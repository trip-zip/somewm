---------------------------------------------------------------------------
--- Test: a freshly mapped client tiles through the cold-start manage drain.
---
--- awful.layout.arrange only marks a screen stale; the per-client manage path
--- (window.c) drains synchronously after the manage signals so c:geometry()
--- holds the tiled box before the configure is flushed, instead of the client's
--- requested terminal size (otherwise the client renders once at the wrong size,
--- the issue #10 flash). The pre-flush instant is not observable from Lua, but a
--- client spawned cold onto a tile layout ending up tiled to the workarea
--- exercises that same drain path (#24).
---
--- Safe under SOMEWM_TREE_ASSERT=abort: one tiled client fills the workarea (no
--- thin columns), so tree==scene holds.
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

local s = screen.primary
local tag = s.tags[1]

local steps = {
    function(count)
        if count == 1 then
            tag:view_only()
            tag.layout = awful.layout.suit.tile
            tag.gap = 0
            test_client("stale_cold")
            return nil
        end
        local c = utils.find_client_by_class("stale_cold")
        if not c then
            if count >= 30 then error("client never appeared") end
            return nil
        end
        if utils.is_tiled_to_workarea(s, c) then
            io.stderr:write("[TEST] PASS: cold-start client is tiled to the workarea\n")
            return true
        end
        if count >= 30 then
            local wa, g = s.workarea, c:geometry()
            error(string.format(
                "cold-start client not tiled: got %dx%d, workarea %dx%d",
                g.width, g.height, wa.width, wa.height))
        end
        return nil
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
