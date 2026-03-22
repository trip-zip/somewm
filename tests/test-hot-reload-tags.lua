---------------------------------------------------------------------------
--- Integration test for hot-reload tag preservation.
--
-- Verifies that awesome.restart() doesn't crash when tags and clients
-- exist. Tag-client associations are snapshotted and restored.
---------------------------------------------------------------------------

local runner = require("_runner")

local steps = {
    -- Step 1: Verify tags exist
    function()
        print("Step 1: Checking tags")
        local s = screen.primary
        assert(s, "Should have a primary screen")
        local tags = s.tags
        assert(#tags >= 1, "Should have at least 1 tag")
        print("  - Tags: " .. #tags)
        for i, t in ipairs(tags) do
            print(string.format("    tag %d: '%s' selected=%s",
                i, t.name, tostring(t.selected)))
        end
        return true
    end,

    -- Step 2: Trigger hot-reload
    function(count)
        if count == 1 then
            print("Step 2: Calling awesome.restart()")
            awesome.restart()
        end
        -- Test passes if compositor doesn't crash
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
