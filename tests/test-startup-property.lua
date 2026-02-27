-- Test: awesome.startup returns a boolean indicating whether rc.lua is
-- still being evaluated (true) or the event loop has started (false).
-- AwesomeWM returns globalconf.loop == NULL. Since tests run after startup,
-- awesome.startup must be false (not nil) at test time.

local runner = require("_runner")

local steps = {
    function()
        -- awesome.startup must be a boolean, not nil.
        assert(type(awesome.startup) == "boolean",
            string.format(
                "Expected awesome.startup to be boolean, got %s",
                type(awesome.startup)))

        -- Tests run after the event loop starts, so startup is over.
        assert(awesome.startup == false,
            "Expected awesome.startup == false after startup")

        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
