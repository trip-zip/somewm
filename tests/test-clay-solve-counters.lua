---------------------------------------------------------------------------
--- Test: solve-counting instrumentation.
---
--- Each Clay_BeginLayout call increments a counter keyed on its source
--- ("compose_screen", "preset", "wibox", "magnifier", "placement",
--- "decoration", "layer_surface", "unknown"). This exercises the API
--- and verifies the counts move with the layout actions we trigger.
---
--- Numbers don't need to be exact -- the counters fire alongside
--- delayed_call coalescing, so several solves of the same source can
--- collapse or fire repeatedly during a tag/screen update. The test
--- pins ranges instead.
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

local clay = require("awful.layout.clay")

local function counts()
    return _somewm_clay.get_solve_counts()
end

local steps = {
    function()
        -- Reset and inspect: every counter starts at zero.
        _somewm_clay.reset_solve_counts()
        local c = counts()
        for _, k in ipairs({
            "compose_screen", "preset", "wibox", "magnifier",
            "placement", "decoration", "layer_surface", "unknown", "total",
        }) do
            assert(c[k] == 0,
                string.format("after reset, %s should be 0, got %s",
                    k, tostring(c[k])))
        end
        io.stderr:write("[TEST] PASS: counters reset cleanly\n")
        return true
    end,

    function()
        local tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = clay.tile
        return true
    end,

    function(count)
        if count == 1 then test_client("count_a") end
        return utils.find_client_by_class("count_a") and true or nil
    end,

    -- Reset, arrange, observe.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        local c = counts()
        io.stderr:write(string.format(
            "[TEST] after arrange: compose=%d preset=%d wibox=%d total=%d\n",
            c.compose_screen, c.preset, c.wibox, c.total))
        -- compose_screen runs once per arrange; preset (the tile body)
        -- runs once per arrange. wibox can fire from any drawable that
        -- needs a relayout in this tick (taglist, tasklist, etc.).
        assert(c.compose_screen >= 1,
            "compose_screen should have fired at least once")
        assert(c.preset >= 1,
            "preset (tile body) should have fired at least once")
        assert(c.total >= c.compose_screen + c.preset,
            "total should sum at least compose_screen + preset")
        io.stderr:write("[TEST] PASS: arrange bumps compose_screen + preset\n")
        return true
    end,

    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then return true end
    end,
}

runner.run_steps(steps, { kill_clients = false })
