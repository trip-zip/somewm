---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2025 somewm contributors
--
-- Minimal test to debug test framework
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting simple test")

local steps = {
    -- Step 1: Just print and return true
    function()
        print("TEST: Step 1 - Hello from test!")
        return true
    end,
}

print("TEST: About to call run_steps")
runner.run_steps(steps)
print("TEST: run_steps called")

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
