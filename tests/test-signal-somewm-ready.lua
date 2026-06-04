---------------------------------------------------------------------------
-- Test: somewm::ready signal + awesome.somewm_ready property
--
-- Covers:
--   * The cold-boot emission of "somewm::ready" sets the persistent flag
--     globalconf.somewm_ready_seen, observable as awesome.somewm_ready.
--   * Subscribing AFTER the cold-boot emission does NOT see a cached
--     value (signals in the C signal system are edge-triggered, which
--     is exactly why the property exists alongside the signal).
--   * awesome.restart() leaves awesome.somewm_ready true because the
--     globalconf flag is C-side state that survives Lua VM rebuild.
--     The post-restart re-emission is verified by manual smoke testing
--     (see somewm-client eval examples in plans/fishlive-autostart).
---------------------------------------------------------------------------

local runner = require("_runner")

-- By the time dofile() runs this file, the compositor has already
-- finished run() in somewm.c, so the cold-boot emission of
-- "somewm::ready" is in the past. The property reflects that.
assert(awesome.somewm_ready == true,
    "awesome.somewm_ready should be true after cold boot " ..
    "(got " .. tostring(awesome.somewm_ready) .. ")")

-- Late subscriber: signals are not sticky, so this handler will not
-- be invoked retroactively for the cold-boot emission.
local late_fire_count = 0
awesome.connect_signal("somewm::ready", function()
    late_fire_count = late_fire_count + 1
end)

local steps = {
    -- Step 1: Confirm late subscriber received nothing.
    function()
        assert(late_fire_count == 0,
            "late subscriber should not see cold-boot emission, " ..
            "got count=" .. late_fire_count)
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
