-- Input activity can reset idle timers without waking displays. Explicit DPMS
-- calls still work, and disabling the setting restores automatic wakeups.

local runner = require("_runner")
local wake_count = 0
local idle_stop_count = 0
local timeout_fired = false

awesome.connect_signal("dpms::on", function()
    wake_count = wake_count + 1
end)
awesome.connect_signal("idle::stop", function()
    idle_stop_count = idle_stop_count + 1
end)

local function assert_state(expected)
    local count = 0
    for name, state in pairs(awesome.dpms_state) do
        assert(state == expected, name .. " should be " .. expected .. ", got " .. state)
        count = count + 1
    end
    assert(count > 0, "DPMS needs at least one output")
end

runner.run_steps({
    function()
        assert(awesome.dpms_ignore_activity == false, "activity should wake displays by default")
        awesome._test_add_output(800, 600)
        return true
    end,

    function()
        awesome.dpms_off()
        assert_state("off")
        wake_count = 0
        mouse._fake_motion(1, 0)
        assert_state("on")
        return true
    end,

    -- Activity queues dpms::on, so inspect its count on the next step.
    function()
        assert(wake_count == 1, "default activity should emit one wake signal")
        awesome.dpms_ignore_activity = true
        assert(awesome.dpms_ignore_activity == true)
        awesome.dpms_off()
        wake_count = 0
        awesome.set_idle_timeout("dpms-ignore", 1, function()
            timeout_fired = true
        end)
        return true
    end,

    function()
        if not timeout_fired then return end
        assert(awesome.idle, "idle timeout should mark the user idle")
        idle_stop_count = 0
        mouse._fake_motion(1, 0)
        assert_state("off")
        assert(not awesome.idle, "ignored DPMS activity must still end idle state")
        assert(not awesome.idle_timeouts["dpms-ignore"].fired,
            "ignored DPMS activity must still reset idle timers")
        return true
    end,

    function()
        assert(wake_count == 0, "ignored activity must not emit dpms::on")
        assert(idle_stop_count == 1, "ignored DPMS activity must still emit idle::stop")
        assert_state("off")
        awesome.clear_idle_timeout("dpms-ignore")
        awesome.dpms_on()
        assert_state("on")
        assert(wake_count == 1, "explicit dpms_on should still emit a wake signal")
        awesome.dpms_on()
        assert(wake_count == 1, "explicit wake should remain idempotent")
        return true
    end,

    function()
        awesome.dpms_ignore_activity = false
        assert(awesome.dpms_ignore_activity == false)
        awesome.dpms_off()
        wake_count = 0
        mouse._fake_motion(1, 0)
        assert_state("on")
        return true
    end,

    function()
        assert(wake_count == 1, "clearing the setting should restore wake signals")
        return true
    end,
}, { wait_per_step = 5, kill_clients = false })
