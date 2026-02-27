-- Test: api_level consistency.
--
-- Bug: awesome.api_level was set as a raw Lua table field with value 5, while
-- globalconf.api_level was initialized to 4 in C. AwesomeWM uses a single
-- source of truth (globalconf.api_level = 4) exposed dynamically via __index.
-- The mismatch caused Lua libraries to behave as if running under a future
-- API level, enabling features and deprecation paths not present in AwesomeWM.
--
-- Reproduction: read awesome.api_level and verify it matches the expected
-- AwesomeWM default of 4.

local runner = require("_runner")

local steps = {
    function()
        -- awesome.api_level must reflect globalconf.api_level (default: 4),
        -- not a stale raw table field.
        assert(awesome.api_level == 4,
            string.format("Expected api_level 4, got %s", tostring(awesome.api_level)))

        -- Verify it is served dynamically via __index, not as a raw field.
        -- rawget on the awesome table should return nil for api_level.
        assert(rawget(awesome, "api_level") == nil,
            "api_level should not be a raw table field (must come from __index)")

        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
