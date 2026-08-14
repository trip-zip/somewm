---------------------------------------------------------------------------
--- Test: idle timers recover when a protocol idle inhibitor is destroyed
--
-- A zwp_idle_inhibitor_v1 dying must re-enable awesome.set_idle_timeout()
-- timers. Two destroy orders, driven by test-idle-inhibit-client:
--
-- Mode B (SIGUSR2): surface destroyed first, inhibitor dies unmapped.
-- Mode A (SIGUSR1): inhibitor destroyed while the surface stays mapped
--   (mpv-on-pause order). Without the fix the compositor counts the dying
--   inhibitor during its destroy signal, latches idle timers off, and no
--   later event ever recomputes.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

local TEST_CLIENT = "./build-test/test-idle-inhibit-client"

local function is_test_client_available()
    local f = io.open(TEST_CLIENT, "r")
    if f then
        f:close()
        return true
    end
    return false
end

if not is_test_client_available() then
    io.stderr:write("SKIP: test-idle-inhibit-client not found (run make build-test)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local fired = {}
local proc_pid

-- Spawn a client (SIGTERMing the previous one first) and wait for its
-- inhibitor to take effect
local function spawn_and_wait(label)
    return function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning " .. label .. "\n")
            if proc_pid then
                awesome.kill(proc_pid, 15)
            end
            proc_pid = awful.spawn(TEST_CLIENT)
        end
        if awesome.inhibitor_count == 1 and awesome.idle_inhibited then
            return true
        end
        if count > 30 then
            error(label .. " inhibitor never registered")
        end
    end
end

-- Signal the client and wait for its inhibitor to go away
local function kill_and_wait_gone(sig, label)
    return function(count)
        if count == 1 then
            io.stderr:write("[TEST] " .. label .. "\n")
            awesome.kill(proc_pid, sig)
        end
        if awesome.inhibitor_count == 0 and not awesome.idle_inhibited then
            return true
        end
        if count > 30 then
            error("inhibitor never went away: " .. label)
        end
    end
end

-- Arm a 1s idle timeout and wait for it to fire
local function timers_alive(key, msg)
    return function(count)
        if count == 1 then
            awesome.set_idle_timeout(key, 1, function()
                fired[key] = true
            end)
        end
        if fired[key] then
            awesome.clear_idle_timeout(key)
            return true
        end
        if count > 30 then
            error("idle timeout dead " .. msg)
        end
    end
end

local steps = {
    -- Baseline separates "idle timers don't run in this environment" from a
    -- recompute regression in the failure log
    timers_alive("baseline", "with no inhibitor ever created"),

    spawn_and_wait("client #1"),
    kill_and_wait_gone(12, "mode B: SIGUSR2 (surface destroyed first)"),
    timers_alive("after_b", "after mode B (surface-first destroy)"),

    spawn_and_wait("client #2"),
    kill_and_wait_gone(10, "mode A: SIGUSR1 (inhibitor destroyed, client stays mapped)"),
    timers_alive("after_a", "after mode A (inhibitor destroyed while mapped)"),

    -- Cleanup
    function(count)
        if count == 1 then
            awesome.clear_all_idle_timeouts()
            if proc_pid then
                awesome.kill(proc_pid, 15)
            end
        end
        if #client.get() == 0 then
            return true
        end
        if count >= 10 then
            os.execute("pkill -9 test-idle-inhibit-client 2>/dev/null")
            return true
        end
    end,
}

runner.run_steps(steps, { wait_per_step = 5, kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
