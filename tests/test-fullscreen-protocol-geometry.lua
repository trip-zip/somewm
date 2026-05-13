---------------------------------------------------------------------------
-- Test: xdg-shell request_fullscreen emits property::geometry and
-- property::fullscreen to per-client subscribers, in the same order the
-- Lua-side client_set_fullscreen path uses (fullscreen before geometry).
--
-- Before the fix, setfullscreen() in somewm.c emitted only
-- property::fullscreen for the C protocol path. The Lua path
-- (client_set_fullscreen -> client_resize_do) emitted both, leaving
-- subscribers to property::geometry blind to client-initiated transitions
-- (e.g. mpv pressing F).
---------------------------------------------------------------------------

local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")

local TEST_FULLSCREEN_CLIENT = "./build-test/test-fullscreen-client"

local function is_test_client_available()
    local f = io.open(TEST_FULLSCREEN_CLIENT, "r")
    if f then
        f:close()
        return true
    end
    return false
end

if not is_test_client_available() then
    io.stderr:write("SKIP: test-fullscreen-client not found (run make build-test)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local c_test
local proc_pid
local events = {}

local function record(signal_name)
    return function()
        table.insert(events, signal_name)
        io.stderr:write(string.format("[TEST] saw %s (event #%d)\n",
            signal_name, #events))
    end
end

local function event_count(name)
    local n = 0
    for _, e in ipairs(events) do
        if e == name then n = n + 1 end
    end
    return n
end

local function first_index(name)
    for i, e in ipairs(events) do
        if e == name then return i end
    end
    return nil
end

local steps = {
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test-fullscreen-client\n")
            proc_pid = awful.spawn(TEST_FULLSCREEN_CLIENT)
        end
        c_test = utils.find_client_by_class("fullscreen_test")
        if c_test then
            io.stderr:write("[TEST] Client appeared\n")
            return true
        end
    end,

    function(count)
        if count == 1 then
            c_test:connect_signal("property::fullscreen", record("property::fullscreen"))
            c_test:connect_signal("property::geometry",   record("property::geometry"))
            c_test:connect_signal("property::position",   record("property::position"))
            c_test:connect_signal("property::size",       record("property::size"))
            io.stderr:write("[TEST] Signal recorders attached\n")
        end
        if count < 5 then return nil end
        assert(not c_test.fullscreen, "client should start non-fullscreen")
        return true
    end,

    function(count)
        if count == 1 then
            events = {}
            io.stderr:write("[TEST] Sending SIGUSR1 (xdg request_fullscreen)\n")
            awesome.kill(proc_pid, 10) -- SIGUSR1
        end
        if not c_test.fullscreen then
            if count > 30 then
                error("Timed out waiting for c.fullscreen = true after SIGUSR1")
            end
            return nil
        end
        if count < 5 then return nil end -- one extra tick for queued signals

        local fc = event_count("property::fullscreen")
        local gc = event_count("property::geometry")
        assert(fc >= 1, string.format(
            "property::fullscreen should fire on enter, got %d", fc))
        assert(gc >= 1, string.format(
            "property::geometry should fire on enter, got %d", gc))

        local f_idx = first_index("property::fullscreen")
        local g_idx = first_index("property::geometry")
        assert(f_idx < g_idx, string.format(
            "property::fullscreen (idx %d) must fire before property::geometry (idx %d)",
            f_idx, g_idx))

        io.stderr:write("[TEST] PASS: enter-fullscreen signals fired in order\n")
        return true
    end,

    function(count)
        if count == 1 then
            events = {}
            io.stderr:write("[TEST] Sending SIGUSR2 (xdg unset_fullscreen)\n")
            awesome.kill(proc_pid, 12) -- SIGUSR2
        end
        if c_test.fullscreen then
            if count > 30 then
                error("Timed out waiting for c.fullscreen = false after SIGUSR2")
            end
            return nil
        end
        if count < 5 then return nil end

        local fc = event_count("property::fullscreen")
        local gc = event_count("property::geometry")
        assert(fc >= 1, string.format(
            "property::fullscreen should fire on exit, got %d", fc))
        assert(gc >= 1, string.format(
            "property::geometry should fire on exit, got %d", gc))

        local f_idx = first_index("property::fullscreen")
        local g_idx = first_index("property::geometry")
        assert(f_idx < g_idx, string.format(
            "property::fullscreen (idx %d) must fire before property::geometry (idx %d) on exit",
            f_idx, g_idx))

        io.stderr:write("[TEST] PASS: exit-fullscreen signals fired in order\n")
        return true
    end,

    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup\n")
            if proc_pid then
                awful.spawn("kill " .. proc_pid)
            end
        end

        if #client.get() == 0 then
            io.stderr:write("[TEST] Cleanup: done\n")
            return true
        end

        if count >= 10 then
            io.stderr:write("[TEST] Cleanup: force killing\n")
            if proc_pid then
                os.execute("kill -9 " .. proc_pid .. " 2>/dev/null")
            end
            os.execute("pkill -9 test-fullscreen 2>/dev/null")
            for _, c in ipairs(client.get()) do
                c:kill()
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
