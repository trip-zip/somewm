---------------------------------------------------------------------------
--- Test: XWayland keyboard focus
--
-- Verifies that XWayland (X11) clients properly receive keyboard focus
-- when they are spawned/activated, without requiring mouse hover.
--
-- This test validates the fix for the XWayland focus bug where X11 apps
-- wouldn't receive keyboard input until the user hovered over them.
--
-- NOTE: This test requires visual mode (HEADLESS=0) because XWayland
-- needs a display.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local x11_client = require("_x11_client")
local utils = require("_utils")

-- Check if we're in headless mode (XWayland won't work properly)
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
            x11_client("xwayland_focus_test")
        end

        -- Look for the X11 client
        -- Note: xterm sets WM_CLASS to what we specify
        for _, c in ipairs(client.get()) do
            if c.class == "xwayland_focus_test" or
               (c.class == "XTerm" and x11_client.is_xwayland(c)) then
                my_x11_client = c
                io.stderr:write(string.format(
                    "[TEST] X11 client spawned: class=%s, window=%s, is_x11=%s\n",
                    c.class, tostring(c.window), tostring(x11_client.is_xwayland(c))
                ))
                return true
            end
        end

        -- Timeout after ~5 seconds
        if count > 50 then
            io.stderr:write("[TEST] ERROR: X11 client did not appear\n")
            error("X11 client did not spawn within timeout")
        end

        return nil
    end,

    -- Step 2: Verify the X11 client is an XWayland client
    function()
        assert(x11_client.is_xwayland(my_x11_client),
            "Expected client to be XWayland (have X11 window ID)")
        io.stderr:write(string.format(
            "[TEST] Confirmed XWayland client: window=%d\n",
            my_x11_client.window or 0
        ))
        return true
    end,

    -- Step 3: Wait a moment for focus to settle, then verify X11 client has REAL keyboard focus
    function(count)
        -- Give focus a moment to be set (this is the bug we're testing!)
        if count < 5 then
            return nil
        end

        -- Check ACTUAL keyboard focus, not just client.focus (Lua bookkeeping)
        -- has_keyboard_focus() checks wlroots seat->keyboard_state.focused_surface
        local has_real_focus = my_x11_client:has_keyboard_focus()

        io.stderr:write(string.format(
            "[TEST] Checking focus (attempt %d): client.focus=%s, has_keyboard_focus=%s\n",
            count,
            client.focus and client.focus.class or "nil",
            tostring(has_real_focus)
        ))

        -- THE KEY ASSERTION: X11 client should have REAL keyboard focus immediately
        -- without requiring mouse hover. This is the actual wlroots seat focus,
        -- not just Lua bookkeeping.
        if has_real_focus then
            io.stderr:write("[TEST] PASS: X11 client has REAL keyboard focus\n")
            return true
        end

        -- Timeout - this is the failure case that indicates the bug
        if count > 20 then
            error(string.format(
                "FAIL: X11 client does not have REAL keyboard focus. " ..
                "client.focus=%s but has_keyboard_focus()=%s. " ..
                "This indicates the XWayland focus bug is present.",
                client.focus and client.focus.class or "nil",
                tostring(has_real_focus)
            ))
        end

        return nil
    end,

    -- Step 4: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing X11 client\n")
            if my_x11_client and my_x11_client.valid then
                my_x11_client:kill()
            end
            -- Also kill via pkill as backup
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
