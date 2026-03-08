---------------------------------------------------------------------------
-- Test: DPMS API
--
-- Covers: BEH-13, BEH-14, BEH-15, DPMS signals
--
-- Note: In headless mode, monitor sleep/wake may be no-ops at the hardware
-- level, but the signal emission and state tracking are still exercised.
---------------------------------------------------------------------------

local runner = require("_runner")

local dpms_off_count = 0
local dpms_on_count = 0

awesome.connect_signal("dpms::off", function()
    dpms_off_count = dpms_off_count + 1
end)
awesome.connect_signal("dpms::on", function()
    dpms_on_count = dpms_on_count + 1
end)

runner.run_steps({
    -- Step 0: Create a test output so DPMS has a monitor to work with
    function()
        awesome._test_add_output(800, 600)
        return true
    end,

    -- Step 1: dpms_off fires signal
    function()
        dpms_off_count = 0
        dpms_on_count = 0
        awesome.dpms_off()
        assert(dpms_off_count == 1, "dpms::off should fire once, got " .. dpms_off_count)
        return true
    end,

    -- Step 2: dpms_off again - idempotent (no signal when already off)
    function()
        dpms_off_count = 0
        awesome.dpms_off()
        assert(dpms_off_count == 0, "dpms::off should not fire when already off, got " .. dpms_off_count)
        return true
    end,

    -- Step 3: dpms_on wakes displays
    function()
        dpms_on_count = 0
        awesome.dpms_on()
        assert(dpms_on_count == 1, "dpms::on should fire once, got " .. dpms_on_count)
        return true
    end,

    -- Step 4: dpms_on again - idempotent (no signal when already on)
    function()
        dpms_on_count = 0
        awesome.dpms_on()
        assert(dpms_on_count == 0, "dpms::on should not fire when already on, got " .. dpms_on_count)
        return true
    end,

    -- BEH-15 (auto-wake on activity) cannot be tested from Lua because
    -- root.fake_input("motion_notify") calls motionnotify() directly,
    -- which does not go through some_notify_activity(). The auto-wake
    -- path is verified by code review of the real input handlers
    -- (motionrelative, motionabsolute, buttonpress, keypress) in somewm.c.
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
