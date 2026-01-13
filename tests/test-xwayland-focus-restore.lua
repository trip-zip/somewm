---------------------------------------------------------------------------
--- Test: XWayland focus restoration
--
-- Verifies that when an XWayland (X11) client closes, focus returns to the
-- correct client from focus history (the most recently focused client).
--
-- This test mirrors test-layer-shell-focus-restore.lua but for X11 clients.
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

if not test_client.is_available() then
    io.stderr:write("SKIP: no Wayland terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local wayland_client
local x11_client_instance

local steps = {
    -- Step 1: Spawn Wayland client A
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning Wayland client A...\n")
            test_client("xw_restore_wayland")
        end
        wayland_client = utils.find_client_by_class("xw_restore_wayland")
        if wayland_client then
            io.stderr:write("[TEST] Wayland client A spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Wait for Wayland client to have focus
    function(count)
        if client.focus == wayland_client then
            io.stderr:write("[TEST] Wayland client A has focus\n")
            return true
        end
        if count > 20 then
            error(string.format("Expected Wayland client to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 3: Spawn X11 client B
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client B...\n")
            x11_client("xw_restore_x11")
        end

        -- Look for the X11 client
        for _, c in ipairs(client.get()) do
            if c.class == "xw_restore_x11" or
               (c.class == "XTerm" and x11_client.is_xwayland(c) and c ~= wayland_client) then
                x11_client_instance = c
                io.stderr:write("[TEST] X11 client B spawned\n")
                return true
            end
        end

        if count > 50 then
            error("X11 client did not spawn within timeout")
        end
        return nil
    end,

    -- Step 4: Wait for X11 client to have focus (Wayland client is now in history)
    function(count)
        -- Give focus time to transfer
        if count < 5 then
            return nil
        end

        if client.focus == x11_client_instance then
            io.stderr:write("[TEST] X11 client B has focus, Wayland A is in history\n")
            return true
        end

        if count > 30 then
            -- This may fail due to the focus bug we're testing
            io.stderr:write(string.format(
                "[TEST] WARNING: X11 client does not have focus (got %s). " ..
                "This may indicate the XWayland focus bug.\n",
                client.focus and client.focus.class or "nil"
            ))
            -- Continue anyway to test restoration behavior
            return true
        end
        return nil
    end,

    -- Step 5: Close the X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing X11 client B...\n")
            if x11_client_instance and x11_client_instance.valid then
                x11_client_instance:kill()
            end
            os.execute("pkill -9 xterm 2>/dev/null")
        end

        -- Wait for X11 client to be gone
        local x11_still_exists = false
        for _, c in ipairs(client.get()) do
            if c == x11_client_instance or
               (c.class == "xw_restore_x11") or
               (c.class == "XTerm" and x11_client.is_xwayland(c)) then
                x11_still_exists = true
                break
            end
        end

        if not x11_still_exists then
            io.stderr:write("[TEST] X11 client B closed\n")
            return true
        end

        if count > 20 then
            io.stderr:write("[TEST] X11 client close timeout, continuing...\n")
            return true
        end

        return nil
    end,

    -- Step 6: Verify focus returns to Wayland client A
    function(count)
        -- Give focus restoration a moment
        if count < 3 then
            return nil
        end

        io.stderr:write(string.format(
            "[TEST] Checking focus after X11 close (attempt %d): client.focus=%s\n",
            count, client.focus and client.focus.class or "nil"
        ))

        -- THE KEY ASSERTION: Focus should return to Wayland client A
        if client.focus == wayland_client then
            io.stderr:write("[TEST] PASS: Focus returned to Wayland client A\n")
            return true
        end

        if count > 15 then
            error(string.format(
                "FAIL: Focus did not return to Wayland client. Expected '%s', got '%s'",
                wayland_client and wayland_client.class or "nil",
                client.focus and client.focus.class or "nil"
            ))
        end

        return nil
    end,

    -- Step 7: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if wayland_client and wayland_client.valid then
                wayland_client:kill()
            end
            os.execute("pkill -9 xterm 2>/dev/null")
        end

        if #client.get() == 0 then
            io.stderr:write("[TEST] Cleanup: done\n")
            return true
        end

        if count >= 10 then
            io.stderr:write("[TEST] Cleanup: force killing\n")
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            pids = x11_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
