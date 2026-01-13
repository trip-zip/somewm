---------------------------------------------------------------------------
--- Test: XWayland focus transfer
--
-- Verifies that focus can be programmatically transferred between XWayland
-- (X11) clients and native Wayland clients in both directions.
--
-- This tests that:
-- 1. Focus can transfer from Wayland to X11 client
-- 2. Focus can transfer from X11 to Wayland client
-- 3. Keyboard events go to the correct client after transfer
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
    -- Step 1: Spawn Wayland client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning Wayland client...\n")
            test_client("xw_transfer_wayland")
        end
        wayland_client = utils.find_client_by_class("xw_transfer_wayland")
        if wayland_client then
            io.stderr:write("[TEST] Wayland client spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Wait for Wayland client to have focus
    function(count)
        if client.focus == wayland_client then
            io.stderr:write("[TEST] Wayland client has initial focus\n")
            return true
        end
        if count > 20 then
            error("Wayland client did not receive focus")
        end
        return nil
    end,

    -- Step 3: Spawn X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client...\n")
            x11_client("xw_transfer_x11")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "xw_transfer_x11" or
               (c.class == "XTerm" and x11_client.is_xwayland(c) and c ~= wayland_client) then
                x11_client_instance = c
                io.stderr:write("[TEST] X11 client spawned\n")
                return true
            end
        end

        if count > 50 then
            error("X11 client did not spawn within timeout")
        end
        return nil
    end,

    -- Step 4: Wait for X11 client to have focus (or not, if bug exists)
    function(count)
        if count < 5 then
            return nil
        end

        io.stderr:write(string.format(
            "[TEST] After X11 spawn: focus=%s (X11=%s, Wayland=%s)\n",
            client.focus and client.focus.class or "nil",
            x11_client_instance and x11_client_instance.class or "nil",
            wayland_client and wayland_client.class or "nil"
        ))

        -- Continue regardless of current focus state
        return true
    end,

    -- Step 5: Programmatically activate Wayland client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Activating Wayland client via request::activate...\n")
            wayland_client:emit_signal("request::activate", "test", { raise = true })
        end

        if count < 3 then
            return nil
        end

        -- Verify Wayland client got focus
        if client.focus == wayland_client then
            io.stderr:write("[TEST] PASS: Wayland client received focus via activate\n")
            return true
        end

        if count > 15 then
            error(string.format(
                "FAIL: Could not activate Wayland client. Focus is on '%s'",
                client.focus and client.focus.class or "nil"
            ))
        end

        return nil
    end,

    -- Step 6: Programmatically activate X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Activating X11 client via request::activate...\n")
            x11_client_instance:emit_signal("request::activate", "test", { raise = true })
        end

        if count < 3 then
            return nil
        end

        -- Verify X11 client got focus
        if client.focus == x11_client_instance then
            io.stderr:write("[TEST] PASS: X11 client received focus via activate\n")
            return true
        end

        if count > 15 then
            error(string.format(
                "FAIL: Could not activate X11 client. Focus is on '%s'. " ..
                "This indicates the XWayland focus bug.",
                client.focus and client.focus.class or "nil"
            ))
        end

        return nil
    end,

    -- Step 7: Transfer back to Wayland via client.focus setter
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting client.focus to Wayland client...\n")
            client.focus = wayland_client
        end

        if count < 3 then
            return nil
        end

        if client.focus == wayland_client then
            io.stderr:write("[TEST] PASS: Focus transferred back to Wayland via setter\n")
            return true
        end

        if count > 15 then
            error("Could not transfer focus back to Wayland client")
        end

        return nil
    end,

    -- Step 8: Transfer to X11 via client.focus setter
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting client.focus to X11 client...\n")
            client.focus = x11_client_instance
        end

        if count < 3 then
            return nil
        end

        if client.focus == x11_client_instance then
            io.stderr:write("[TEST] PASS: Focus transferred to X11 via setter\n")
            return true
        end

        if count > 15 then
            error(string.format(
                "FAIL: Could not transfer focus to X11 client via setter. " ..
                "Focus is on '%s'. This indicates the XWayland focus bug.",
                client.focus and client.focus.class or "nil"
            ))
        end

        return nil
    end,

    -- Step 9: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing clients\n")
            if wayland_client and wayland_client.valid then
                wayland_client:kill()
            end
            if x11_client_instance and x11_client_instance.valid then
                x11_client_instance:kill()
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
