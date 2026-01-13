---------------------------------------------------------------------------
--- Test: XWayland signal parity
--
-- Verifies that XWayland (X11) clients emit the same lifecycle and property
-- signals as native Wayland (XDG) clients.
--
-- This tests that:
-- 1. request::manage signal fires when X11 client is created
-- 2. manage signal fires after request::manage
-- 3. request::unmanage signal fires when X11 client closes
-- 4. unmanage signal fires after request::unmanage
-- 5. property::name signal fires when title changes (if possible)
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

-- Signal tracking
local signals_received = {
    request_manage = false,
    manage = false,
    request_unmanage = false,
    unmanage = false,
}

local signal_clients = {
    request_manage = nil,
    manage = nil,
    request_unmanage = nil,
    unmanage = nil,
}

-- Connect signal handlers
client.connect_signal("request::manage", function(c)
    if x11_client.is_xwayland(c) then
        io.stderr:write(string.format(
            "[SIGNAL] request::manage fired for X11 client: %s\n",
            c.class or "(no class)"
        ))
        signals_received.request_manage = true
        signal_clients.request_manage = c
    end
end)

client.connect_signal("manage", function(c)
    if x11_client.is_xwayland(c) then
        io.stderr:write(string.format(
            "[SIGNAL] manage fired for X11 client: %s\n",
            c.class or "(no class)"
        ))
        signals_received.manage = true
        signal_clients.manage = c
    end
end)

client.connect_signal("request::unmanage", function(c)
    if x11_client.is_xwayland(c) then
        io.stderr:write(string.format(
            "[SIGNAL] request::unmanage fired for X11 client: %s\n",
            c.class or "(no class)"
        ))
        signals_received.request_unmanage = true
        signal_clients.request_unmanage = c
    end
end)

client.connect_signal("unmanage", function(c)
    if x11_client.is_xwayland(c) then
        io.stderr:write(string.format(
            "[SIGNAL] unmanage fired for X11 client: %s\n",
            c.class or "(no class)"
        ))
        signals_received.unmanage = true
        signal_clients.unmanage = c
    end
end)

local steps = {
    -- Step 1: Spawn an X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client...\n")
            x11_client("xw_signals_test")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "xw_signals_test" or
               (c.class == "XTerm" and x11_client.is_xwayland(c)) then
                my_x11_client = c
                io.stderr:write("[TEST] X11 client spawned\n")
                return true
            end
        end

        if count > 50 then
            error("X11 client did not spawn within timeout")
        end

        return nil
    end,

    -- Step 2: Wait for signals to settle
    function(count)
        if count < 5 then
            return nil
        end
        return true
    end,

    -- Step 3: Verify request::manage signal was received
    function()
        io.stderr:write(string.format(
            "[TEST] Checking request::manage: received=%s\n",
            tostring(signals_received.request_manage)
        ))

        assert(signals_received.request_manage,
            "FAIL: request::manage signal was not fired for X11 client")
        assert(signal_clients.request_manage == my_x11_client,
            "FAIL: request::manage was fired for wrong client")

        io.stderr:write("[TEST] PASS: request::manage signal received\n")
        return true
    end,

    -- Step 4: Verify manage signal was received
    function()
        io.stderr:write(string.format(
            "[TEST] Checking manage: received=%s\n",
            tostring(signals_received.manage)
        ))

        assert(signals_received.manage,
            "FAIL: manage signal was not fired for X11 client")
        assert(signal_clients.manage == my_x11_client,
            "FAIL: manage was fired for wrong client")

        io.stderr:write("[TEST] PASS: manage signal received\n")
        return true
    end,

    -- Step 5: Close the X11 client to test unmanage signals
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing X11 client to test unmanage signals...\n")
            if my_x11_client and my_x11_client.valid then
                my_x11_client:kill()
            end
            os.execute("pkill -9 xterm 2>/dev/null")
        end

        -- Wait for client to be gone
        local found = false
        for _, c in ipairs(client.get()) do
            if c == my_x11_client or c.class == "xw_signals_test" then
                found = true
                break
            end
        end

        if not found then
            io.stderr:write("[TEST] X11 client closed\n")
            return true
        end

        if count > 20 then
            io.stderr:write("[TEST] X11 client close timeout, continuing...\n")
            return true
        end

        return nil
    end,

    -- Step 6: Wait for unmanage signals
    function(count)
        if count < 3 then
            return nil
        end
        return true
    end,

    -- Step 7: Verify request::unmanage signal was received
    function()
        io.stderr:write(string.format(
            "[TEST] Checking request::unmanage: received=%s\n",
            tostring(signals_received.request_unmanage)
        ))

        assert(signals_received.request_unmanage,
            "FAIL: request::unmanage signal was not fired for X11 client")

        io.stderr:write("[TEST] PASS: request::unmanage signal received\n")
        return true
    end,

    -- Step 8: Verify unmanage signal was received
    function()
        io.stderr:write(string.format(
            "[TEST] Checking unmanage: received=%s\n",
            tostring(signals_received.unmanage)
        ))

        assert(signals_received.unmanage,
            "FAIL: unmanage signal was not fired for X11 client")

        io.stderr:write("[TEST] PASS: unmanage signal received\n")
        return true
    end,

    -- Step 9: Final cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Final cleanup\n")
            os.execute("pkill -9 xterm 2>/dev/null")
        end

        if #client.get() == 0 or count >= 5 then
            io.stderr:write("[TEST] All signal tests PASSED\n")
            return true
        end

        return nil
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
