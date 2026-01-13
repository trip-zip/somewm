---------------------------------------------------------------------------
--- Test: XWayland state handling (fullscreen, maximized)
--
-- Verifies that XWayland (X11) clients properly handle state changes
-- like fullscreen and maximized modes.
--
-- This tests that:
-- 1. X11 clients can be set to fullscreen programmatically
-- 2. X11 clients can be set to maximized programmatically
-- 3. State changes are reflected in client properties
--
-- NOTE: This test requires visual mode (HEADLESS=0) because XWayland
-- needs a display.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local x11_client = require("_x11_client")
local utils = require("_utils")

-- Check if we're in headless mode
local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

-- Skip test if requirements not met
if is_headless() then
    io.stderr:write("SKIP: XWayland tests require visual mode (HEADLESS=0)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

if not x11_client.is_available() then
    io.stderr:write("SKIP: no X11 application available (install xterm)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local my_x11_client
local initial_geom

local steps = {
    -- Step 1: Spawn an X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client...\n")
            x11_client("xw_state_test")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "xw_state_test" or
               (c.class == "XTerm" and x11_client.is_xwayland(c)) then
                my_x11_client = c
                io.stderr:write(string.format(
                    "[TEST] X11 client spawned: class=%s\n", c.class
                ))
                return true
            end
        end

        if count > 50 then
            error("X11 client did not spawn within timeout")
        end

        return nil
    end,

    -- Step 2: Wait for client to settle and record initial geometry
    function(count)
        if count < 5 then
            return nil
        end

        initial_geom = my_x11_client:geometry()
        io.stderr:write(string.format(
            "[TEST] Initial geometry: %dx%d+%d+%d, fullscreen=%s, maximized=%s\n",
            initial_geom.width, initial_geom.height,
            initial_geom.x, initial_geom.y,
            tostring(my_x11_client.fullscreen),
            tostring(my_x11_client.maximized)
        ))

        -- Verify client is not fullscreen/maximized initially
        assert(not my_x11_client.fullscreen, "Client should not start fullscreen")
        assert(not my_x11_client.maximized, "Client should not start maximized")

        return true
    end,

    -- Step 3: Set client to maximized
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting maximized = true...\n")
            my_x11_client.maximized = true
        end

        if count < 5 then
            return nil
        end

        if my_x11_client.maximized then
            local geom = my_x11_client:geometry()
            io.stderr:write(string.format(
                "[TEST] PASS: Client is maximized, geometry: %dx%d+%d+%d\n",
                geom.width, geom.height, geom.x, geom.y
            ))
            -- Maximized window should be larger than initial
            assert(geom.width >= initial_geom.width,
                "Maximized width should be >= initial")
            assert(geom.height >= initial_geom.height,
                "Maximized height should be >= initial")
            return true
        end

        if count > 15 then
            error(string.format(
                "FAIL: maximized property not set. maximized=%s",
                tostring(my_x11_client.maximized)
            ))
        end

        return nil
    end,

    -- Step 4: Unmaximize
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting maximized = false...\n")
            my_x11_client.maximized = false
        end

        if count < 5 then
            return nil
        end

        if not my_x11_client.maximized then
            io.stderr:write("[TEST] PASS: Client unmaximized\n")
            return true
        end

        if count > 15 then
            error("FAIL: Could not unmaximize client")
        end

        return nil
    end,

    -- Step 5: Set client to fullscreen
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting fullscreen = true...\n")
            my_x11_client.fullscreen = true
        end

        if count < 5 then
            return nil
        end

        if my_x11_client.fullscreen then
            local geom = my_x11_client:geometry()
            local screen_geom = screen[1].geometry
            io.stderr:write(string.format(
                "[TEST] PASS: Client is fullscreen, geometry: %dx%d (screen: %dx%d)\n",
                geom.width, geom.height,
                screen_geom.width, screen_geom.height
            ))
            return true
        end

        if count > 15 then
            error(string.format(
                "FAIL: fullscreen property not set. fullscreen=%s",
                tostring(my_x11_client.fullscreen)
            ))
        end

        return nil
    end,

    -- Step 6: Exit fullscreen
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting fullscreen = false...\n")
            my_x11_client.fullscreen = false
        end

        if count < 5 then
            return nil
        end

        if not my_x11_client.fullscreen then
            io.stderr:write("[TEST] PASS: Client exited fullscreen\n")
            return true
        end

        if count > 15 then
            error("FAIL: Could not exit fullscreen")
        end

        return nil
    end,

    -- Step 7: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing X11 client\n")
            if my_x11_client and my_x11_client.valid then
                my_x11_client:kill()
            end
            os.execute("pkill -9 xterm 2>/dev/null")
        end

        if #client.get() == 0 then
            io.stderr:write("[TEST] Cleanup: done\n")
            return true
        end

        if count >= 10 then
            io.stderr:write("[TEST] Cleanup: force killing\n")
            local pids = x11_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
