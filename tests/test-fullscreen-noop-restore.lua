---------------------------------------------------------------------------
-- Test: unset_fullscreen on a client that was never fullscreen is a no-op.
--
-- c->prev is the pre-fullscreen restore point. It used to hold the map-time
-- rect for every client, so a redundant unset_fullscreen threw away every
-- geometry change made since.
--
-- The client must move after map for this to be visible: if the map-time
-- rect and the current rect are the same, restoring to the stale memento
-- looks like a no-op.
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

local SIGUSR2 = 12

local MOVED = { x = 120, y = 90, width = 640, height = 480 }

local c_test
local proc_pid

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

    -- Move away from the map-time rect so a stale-memento restore is visible.
    function(count)
        if count == 1 then
            assert(not c_test.fullscreen, "client should start non-fullscreen")
            c_test.floating = true
            c_test:geometry(MOVED)
            io.stderr:write("[TEST] Moved client off its map-time rect\n")
        end
        if count < 5 then return nil end

        utils.assert_geometry(c_test:geometry(), MOVED, 2)
        io.stderr:write("[TEST] Client sits on its new rect\n")
        return true
    end,

    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGUSR2 (redundant unset_fullscreen)\n")
            awesome.kill(proc_pid, SIGUSR2)
        end
        if count < 5 then return nil end

        assert(not c_test.fullscreen, "client must still be non-fullscreen")
        utils.assert_geometry(c_test:geometry(), MOVED, 2)

        io.stderr:write("[TEST] PASS: redundant unset_fullscreen left geometry alone\n")
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
            os.execute("pkill -9 test-fullscreen-client 2>/dev/null")
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
