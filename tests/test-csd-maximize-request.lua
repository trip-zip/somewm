---------------------------------------------------------------------------
-- Test: xdg-shell CSD maximize/minimize requests reach Lua and the client.
--
-- GTK and Chromium draw their own titlebar buttons and drive window state
-- with xdg_toplevel.set_maximized / unset_maximized / set_minimized.
--
-- c.xdg_maximized reads the state scheduled on the toplevel, which is what
-- separates "Lua thinks it is maximized" from "the client was told".
---------------------------------------------------------------------------

local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")

local TEST_CSD_CLIENT = "./build-test/test-csd-state-client"

local function is_test_client_available()
    local f = io.open(TEST_CSD_CLIENT, "r")
    if f then
        f:close()
        return true
    end
    return false
end

if not is_test_client_available() then
    io.stderr:write("SKIP: test-csd-state-client not found (run make build-test)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local SIGUSR1, SIGUSR2, SIGHUP = 10, 12, 1

local c_test
local proc_pid
local floating_geo

local steps = {
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test-csd-state-client\n")
            proc_pid = awful.spawn(TEST_CSD_CLIENT)
        end
        c_test = utils.find_client_by_class("csd_test")
        if c_test then
            io.stderr:write("[TEST] Client appeared\n")
            return true
        end
    end,

    -- Let placement settle, then record the pre-maximize rect.
    function(count)
        if count < 5 then return nil end
        assert(not c_test.maximized, "client should start unmaximized")
        assert(not c_test.xdg_maximized, "toplevel should start unmaximized")
        floating_geo = c_test:geometry()
        io.stderr:write(string.format("[TEST] Floating geometry %dx%d+%d+%d\n",
            floating_geo.width, floating_geo.height, floating_geo.x, floating_geo.y))
        return true
    end,

    -- CSD maximize button.
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGUSR1 (xdg set_maximized)\n")
            awesome.kill(proc_pid, SIGUSR1)
        end
        if not c_test.maximized then return nil end
        if count < 5 then return nil end

        assert(c_test.xdg_maximized,
            "toplevel must be told it is maximized (wlr_xdg_toplevel_set_maximized)")

        local wa = utils.get_workarea()
        utils.assert_geometry(c_test:geometry(),
            { width = wa.width, height = wa.height }, 2 * c_test.border_width)

        io.stderr:write("[TEST] PASS: CSD maximize applied and acked\n")
        return true
    end,

    -- CSD restore button.
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGUSR2 (xdg unset_maximized)\n")
            awesome.kill(proc_pid, SIGUSR2)
        end
        if c_test.maximized then return nil end
        if count < 5 then return nil end

        assert(not c_test.xdg_maximized,
            "toplevel must be told it is no longer maximized")
        utils.assert_geometry(c_test:geometry(), floating_geo, 2)

        io.stderr:write("[TEST] PASS: CSD unmaximize restored the floating rect\n")
        return true
    end,

    -- CSD minimize button. xdg-shell has no unset_minimized, so this is
    -- one-way; unminimize is a Lua-side concern.
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGHUP (xdg set_minimized)\n")
            awesome.kill(proc_pid, SIGHUP)
        end
        if not c_test.minimized then return nil end
        io.stderr:write("[TEST] PASS: CSD minimize applied\n")
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
            os.execute("pkill -9 test-csd-state-client 2>/dev/null")
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
