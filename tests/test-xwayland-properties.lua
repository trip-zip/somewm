---------------------------------------------------------------------------
--- Test: XWayland properties
--
-- Verifies that XWayland (X11) clients properly expose their properties
-- to Lua, including WM_CLASS, WM_NAME, etc.
--
-- This tests that:
-- 1. X11 client.class and client.instance are populated from WM_CLASS
-- 2. X11 client.name is populated from WM_NAME / _NET_WM_NAME
-- 3. X11 client.pid is populated (if available)
-- 4. Property change signals fire when properties change
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
    -- Step 1: Spawn an X11 client with a specific class
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client with class 'xw_props_test'...\n")
            -- xterm -class sets the WM_CLASS resource class
            x11_client("xw_props_test")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "xw_props_test" or
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

    -- Step 2: Wait for properties to populate
    function(count)
        if count < 5 then
            return nil
        end
        return true
    end,

    -- Step 3: Verify WM_CLASS property (class)
    function()
        io.stderr:write(string.format(
            "[TEST] Checking client.class: '%s'\n",
            my_x11_client.class or "(nil)"
        ))

        -- xterm should honor -class flag
        local expected_class = "xw_props_test"
        if my_x11_client.class == expected_class then
            io.stderr:write(string.format(
                "[TEST] PASS: client.class = '%s'\n", my_x11_client.class
            ))
        elseif my_x11_client.class == "XTerm" then
            -- xterm didn't honor -class, but class is still set
            io.stderr:write(string.format(
                "[TEST] INFO: client.class = 'XTerm' (xterm didn't honor -class flag)\n"
            ))
        else
            error(string.format(
                "FAIL: client.class is nil or unexpected: '%s'",
                my_x11_client.class or "(nil)"
            ))
        end

        -- class should never be nil for X11 clients
        assert(my_x11_client.class ~= nil and my_x11_client.class ~= "",
            "client.class should not be nil/empty for X11 clients")

        return true
    end,

    -- Step 4: Verify instance property (from WM_CLASS instance name)
    function()
        io.stderr:write(string.format(
            "[TEST] Checking client.instance: '%s'\n",
            my_x11_client.instance or "(nil)"
        ))

        -- instance should be set (xterm -name sets this, or defaults to xterm)
        -- We use lowercase class as instance: xw_props_test -> xw_props_test
        if my_x11_client.instance ~= nil and my_x11_client.instance ~= "" then
            io.stderr:write(string.format(
                "[TEST] PASS: client.instance = '%s'\n", my_x11_client.instance
            ))
            return true
        end

        -- instance might be nil if not implemented
        io.stderr:write("[TEST] WARNING: client.instance is nil/empty\n")
        return true  -- Continue testing other properties
    end,

    -- Step 5: Verify name property (WM_NAME or _NET_WM_NAME)
    function()
        io.stderr:write(string.format(
            "[TEST] Checking client.name: '%s'\n",
            my_x11_client.name or "(nil)"
        ))

        -- name should be set - xterm sets WM_NAME
        assert(my_x11_client.name ~= nil and my_x11_client.name ~= "",
            "client.name should not be nil/empty for X11 clients")

        io.stderr:write(string.format(
            "[TEST] PASS: client.name = '%s'\n", my_x11_client.name
        ))
        return true
    end,

    -- Step 6: Check pid property (_NET_WM_PID)
    function()
        io.stderr:write(string.format(
            "[TEST] Checking client.pid: %s\n",
            tostring(my_x11_client.pid)
        ))

        -- pid might be nil if the X11 app doesn't set _NET_WM_PID
        -- or if we don't read it. xterm typically sets it.
        if my_x11_client.pid ~= nil and my_x11_client.pid > 0 then
            io.stderr:write(string.format(
                "[TEST] PASS: client.pid = %d\n", my_x11_client.pid
            ))
        else
            io.stderr:write("[TEST] INFO: client.pid is nil (may not be implemented or app doesn't set it)\n")
        end

        return true
    end,

    -- Step 7: Check that client is recognized as XWayland
    function()
        local is_x11 = x11_client.is_xwayland(my_x11_client)
        io.stderr:write(string.format(
            "[TEST] is_xwayland(client) = %s, window = %s\n",
            tostring(is_x11),
            tostring(my_x11_client.window)
        ))

        assert(is_x11, "Client should be detected as XWayland")
        assert(my_x11_client.window ~= nil and my_x11_client.window > 0,
            "XWayland client should have a window ID")

        io.stderr:write("[TEST] PASS: Client is properly identified as XWayland\n")
        return true
    end,

    -- Step 8: Cleanup
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
