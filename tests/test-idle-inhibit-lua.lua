---------------------------------------------------------------------------
--- Test: Lua-level idle inhibition (awesome.idle_inhibit)
---
--- Covers: setting/getting awesome.idle_inhibit, interaction with
--- awesome.idle_inhibited, and suppression of idle timeouts.
---------------------------------------------------------------------------

local runner = require("_runner")

local callback_fired = {}

runner.run_steps({
    -- Step 1: Verify idle_inhibit defaults to false
    function()
        assert(awesome.idle_inhibit == false,
            "idle_inhibit should default to false")
        assert(awesome.idle_inhibited == false,
            "idle_inhibited should be false with no inhibitors")
        return true
    end,

    -- Step 2: Set idle_inhibit = true, verify both properties
    function()
        awesome.idle_inhibit = true
        assert(awesome.idle_inhibit == true,
            "idle_inhibit should be true after setting")
        assert(awesome.idle_inhibited == true,
            "idle_inhibited should reflect Lua inhibition")
        return true
    end,

    -- Step 3: Set a short idle timeout - it should NOT fire while inhibited
    function()
        callback_fired = {}
        awesome.set_idle_timeout("inhibit_test", 1, function()
            table.insert(callback_fired, "inhibit_test")
        end)
        return true
    end,

    -- Step 4: Wait 1.5s, verify timeout did not fire
    function(count)
        if count < 15 then return end
        assert(#callback_fired == 0,
            "idle timeout should not fire while Lua-inhibited")
        return true
    end,

    -- Step 5: Clear inhibition, timeout should now fire
    function()
        callback_fired = {}
        awesome.idle_inhibit = false
        assert(awesome.idle_inhibit == false,
            "idle_inhibit should be false after clearing")

        awesome.clear_idle_timeout("inhibit_test")
        awesome.set_idle_timeout("uninhibit_test", 1, function()
            table.insert(callback_fired, "uninhibit_test")
        end)
        return true
    end,

    -- Step 6: Wait for the timeout to fire
    function()
        if #callback_fired == 0 then return end
        assert(callback_fired[1] == "uninhibit_test",
            "timeout should fire after Lua inhibition cleared")
        return true
    end,

    -- Cleanup
    function()
        awesome.idle_inhibit = false
        awesome.clear_all_idle_timeouts()
        root.fake_input("motion_notify", true, 1, 0)
        return true
    end,
}, { wait_per_step = 5, kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
