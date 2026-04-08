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

    -- Step 2: Verify inhibitors and inhibitor_count with no protocol inhibitors
    function()
        local inhibitors = awesome.inhibitors
        assert(type(inhibitors) == "table",
            "inhibitors should be a table")
        assert(#inhibitors == 0,
            "inhibitors should be empty with no protocol inhibitors")
        assert(awesome.inhibitor_count == 0,
            "inhibitor_count should be 0 with no protocol inhibitors")
        return true
    end,

    -- Step 3: Set idle_inhibit = true, verify signal fires
    function()
        local signal_count = 0
        local function on_inhibited()
            signal_count = signal_count + 1
        end
        awesome.connect_signal("property::idle_inhibited", on_inhibited)

        awesome.idle_inhibit = true
        assert(awesome.idle_inhibit == true,
            "idle_inhibit should be true after setting")
        assert(awesome.idle_inhibited == true,
            "idle_inhibited should reflect Lua inhibition")
        assert(signal_count == 1,
            "property::idle_inhibited signal should fire once, got " .. signal_count)

        -- Setting to same value should NOT fire signal again
        awesome.idle_inhibit = true
        assert(signal_count == 1,
            "signal should not fire when state unchanged, got " .. signal_count)

        awesome.disconnect_signal("property::idle_inhibited", on_inhibited)
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
