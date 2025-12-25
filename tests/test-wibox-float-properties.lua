-- Test that wibox/drawin accepts float property values (Lua 5.3+ compatibility)
-- This catches regressions of issue #105: "number has no integer representation"
local runner = require("_runner")
local wibox = require("wibox")

local w

runner.run_steps({
    -- Create wibox with float values (would crash on Lua 5.3+ before fix)
    function()
        w = wibox {
            x = 100.5,
            y = 200.7,
            width = 150.3,
            height = 175.9,
            visible = true,
        }
        assert(w, "Failed to create wibox with float properties")
        return true
    end,

    -- Verify properties are accessible
    function()
        assert(w.x ~= nil, "x property not accessible")
        assert(w.width >= 150, "width should be at least 150")
        return true
    end,

    -- Modify with float values
    function()
        w.x = 50.1
        w.width = 200.4
        return true
    end,

    -- Test geometry table with floats
    function()
        w:geometry({ x = 10.5, y = 20.5, width = 100.9, height = 100.9 })
        return true
    end,
})
