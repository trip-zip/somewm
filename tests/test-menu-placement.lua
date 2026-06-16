---------------------------------------------------------------------------
--- Test: awful.menu placement is unchanged and clean under the tree==scene abort.
---
--- Menu stays a bespoke leaf (#53): set_coords still does direct x/y placement
--- off s.workarea (it never becomes a Clay result, so the C assert never sees
--- it). This guards that:
---   1. A root menu lands at the requested coords (golden value).
---   2. A submenu opens to the right of its parent (the bespoke cascade math).
--- Run under SOMEWM_TREE_ASSERT=abort to confirm the menu drawins never trip the
--- assertion.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

local m

local function near(actual, expected, label)
    assert(math.abs(actual - expected) <= 1,
        string.format("%s: got %s, expected %s", label, tostring(actual), tostring(expected)))
end

local steps = {
    -- Root menu lands at the requested coords; the stale marker is cleared.
    function()
        m = awful.menu({ items = {
            { "one", function() end },
            { "sub", { { "a", function() end }, { "b", function() end } } },
        } })
        m:show({ coords = { x = 100, y = 100 } })

        near(m.wibox.x, 100, "root menu x = requested coord")
        near(m.wibox.y, 100, "root menu y = requested coord")
        io.stderr:write("[TEST] PASS: root menu lands at coords\n")
        return true
    end,

    -- Submenu cascades to the right of its parent (bespoke leaf math, unchanged).
    function(count)
        if not m.active_child then
            m:exec(2)
            return nil
        end
        if not m.active_child.wibox.visible then
            if count >= 40 then error("submenu never shown") end
            return nil
        end
        local sub = m.active_child
        assert(sub.wibox.x > m.wibox.x,
            string.format("submenu should open right of parent: sub.x=%d parent.x=%d",
                sub.wibox.x, m.wibox.x))
        io.stderr:write("[TEST] PASS: submenu cascades right of its parent\n")
        return true
    end,

    function()
        m:hide()
        io.stderr:write("Test finished successfully.\n")
        awesome.quit()
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
