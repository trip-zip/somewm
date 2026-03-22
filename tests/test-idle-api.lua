---------------------------------------------------------------------------
-- Test: Idle timeout API
--
-- Covers: idle timeout lifecycle, idle::start, idle::stop, timer reset
--
-- Uses longer wait_per_step since idle timeouts need real time to elapse.
---------------------------------------------------------------------------

local runner = require("_runner")

local idle_start_count = 0
local idle_stop_count = 0
local callback_fired = {}

awesome.connect_signal("idle::start", function()
    idle_start_count = idle_start_count + 1
end)
awesome.connect_signal("idle::stop", function()
    idle_stop_count = idle_stop_count + 1
end)

runner.run_steps({
    -- Step 1: Set 1s idle timeout, wait for it to fire
    function()
        idle_start_count = 0
        callback_fired = {}
        awesome.set_idle_timeout("test1", 1, function()
            table.insert(callback_fired, "test1")
        end)
        return true
    end,

    -- Step 2: Wait for callback + signal
    function(count)
        if #callback_fired == 0 then return end
        assert(callback_fired[1] == "test1", "callback should have fired")
        assert(idle_start_count >= 1, "idle::start should have fired")
        assert(awesome.idle, "awesome.idle should be true")
        return true
    end,

    -- Step 3: Inject motion to trigger activity - idle::stop should fire
    function()
        idle_stop_count = 0
        root.fake_input("motion_notify", true, 1, 0)
        return true
    end,

    function(count)
        if count < 2 then return end
        assert(idle_stop_count >= 1, "idle::stop should fire on activity")
        assert(not awesome.idle, "awesome.idle should be false after activity")

        -- Cleanup
        awesome.clear_all_idle_timeouts()
        return true
    end,

    -- Step 4: Set two timeouts (1s, 2s), verify short fires first
    function()
        callback_fired = {}
        awesome.set_idle_timeout("short", 1, function()
            table.insert(callback_fired, "short")
        end)
        awesome.set_idle_timeout("long", 2, function()
            table.insert(callback_fired, "long")
        end)
        return true
    end,

    -- Wait for both
    function()
        if #callback_fired < 2 then return end
        assert(callback_fired[1] == "short", "short should fire first, got " .. callback_fired[1])
        assert(callback_fired[2] == "long", "long should fire second")
        awesome.clear_all_idle_timeouts()
        -- Reset idle state
        root.fake_input("motion_notify", true, 1, 0)
        return true
    end,

    function(count)
        if count < 2 then return end
        return true
    end,

    -- Step 5: clear_idle_timeout - set timeout, clear it, verify it doesn't fire
    function()
        callback_fired = {}
        awesome.set_idle_timeout("cleared", 1, function()
            table.insert(callback_fired, "cleared")
        end)
        awesome.clear_idle_timeout("cleared")
        return true
    end,

    -- Wait 1.5s to confirm it didn't fire
    function(count)
        -- wait_per_step is 5s, each retry is 0.1s, so 15 retries = 1.5s
        if count < 15 then return end
        assert(#callback_fired == 0, "cleared timeout should not fire")
        return true
    end,

    -- Step 6: clear_all_idle_timeouts - set two, clear all, verify neither fires
    function()
        callback_fired = {}
        awesome.set_idle_timeout("a", 1, function()
            table.insert(callback_fired, "a")
        end)
        awesome.set_idle_timeout("b", 1, function()
            table.insert(callback_fired, "b")
        end)
        awesome.clear_all_idle_timeouts()
        return true
    end,

    function(count)
        if count < 15 then return end
        assert(#callback_fired == 0, "cleared timeouts should not fire")
        return true
    end,

    -- Step 7: Replace by name - set "foo" at 1s, replace with 2s, verify only v2 fires
    function()
        callback_fired = {}
        awesome.set_idle_timeout("foo", 1, function()
            table.insert(callback_fired, "foo_v1")
        end)
        awesome.set_idle_timeout("foo", 2, function()
            table.insert(callback_fired, "foo_v2")
        end)
        return true
    end,

    function()
        if #callback_fired == 0 then return end
        assert(callback_fired[1] == "foo_v2",
            "replaced timeout should fire v2, got " .. callback_fired[1])
        -- Make sure v1 never fires
        for _, v in ipairs(callback_fired) do
            assert(v ~= "foo_v1", "v1 callback should never fire")
        end
        return true
    end,

    -- Cleanup
    function()
        awesome.clear_all_idle_timeouts()
        root.fake_input("motion_notify", true, 1, 0)
        return true
    end,
}, { wait_per_step = 5, kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
