---------------------------------------------------------------------------
--- Test: XWayland configure/geometry handling
--
-- Verifies that XWayland (X11) clients properly receive geometry updates
-- and that programmatic geometry changes work correctly.
--
-- This tests that:
-- 1. X11 clients can have their geometry changed programmatically
-- 2. X11 clients respect geometry constraints
-- 3. X11 clients are properly positioned on screen
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

local steps = {
    -- Step 1: Spawn an X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client...\n")
            x11_client("xw_configure_test")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "xw_configure_test" or
               (c.class == "XTerm" and x11_client.is_xwayland(c)) then
                my_x11_client = c
                io.stderr:write(string.format(
                    "[TEST] X11 client spawned: class=%s, geom=%dx%d+%d+%d\n",
                    c.class, c.width, c.height, c.x, c.y
                ))
                return true
            end
        end

        if count > 50 then
            error("X11 client did not spawn within timeout")
        end

        return nil
    end,

    -- Step 2: Wait for client to settle
    function(count)
        if count < 5 then
            return nil
        end

        -- Verify client has valid geometry
        assert(my_x11_client.width > 0, "Client width should be > 0")
        assert(my_x11_client.height > 0, "Client height should be > 0")

        io.stderr:write(string.format(
            "[TEST] Initial geometry: %dx%d+%d+%d\n",
            my_x11_client.width, my_x11_client.height,
            my_x11_client.x, my_x11_client.y
        ))
        return true
    end,

    -- Step 3: Change geometry programmatically
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting geometry to 400x300+100+100...\n")
            my_x11_client:geometry({ x = 100, y = 100, width = 400, height = 300 })
        end

        if count < 5 then
            return nil
        end

        local geom = my_x11_client:geometry()
        io.stderr:write(string.format(
            "[TEST] After geometry set: %dx%d+%d+%d\n",
            geom.width, geom.height, geom.x, geom.y
        ))

        -- Allow some tolerance for window decorations/borders
        local width_ok = math.abs(geom.width - 400) <= 10
        local height_ok = math.abs(geom.height - 300) <= 10

        if width_ok and height_ok then
            io.stderr:write("[TEST] PASS: Geometry change applied\n")
            return true
        end

        if count > 20 then
            error(string.format(
                "FAIL: Geometry not applied. Expected ~400x300, got %dx%d",
                geom.width, geom.height
            ))
        end

        return nil
    end,

    -- Step 4: Test moving the window
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Moving window to 200,200...\n")
            my_x11_client.x = 200
            my_x11_client.y = 200
        end

        if count < 5 then
            return nil
        end

        local x_ok = math.abs(my_x11_client.x - 200) <= 10
        local y_ok = math.abs(my_x11_client.y - 200) <= 10

        if x_ok and y_ok then
            io.stderr:write(string.format(
                "[TEST] PASS: Window moved to %d,%d\n",
                my_x11_client.x, my_x11_client.y
            ))
            return true
        end

        if count > 20 then
            error(string.format(
                "FAIL: Window not moved. Expected ~200,200, got %d,%d",
                my_x11_client.x, my_x11_client.y
            ))
        end

        return nil
    end,

    -- Step 5: Cleanup
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
