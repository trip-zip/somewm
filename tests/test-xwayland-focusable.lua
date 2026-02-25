---------------------------------------------------------------------------
--- Test: XWayland client focusable property
--
-- Verifies that XWayland clients report the correct `focusable` property
-- based on the ICCCM input model. The fix uses
-- wlr_xwayland_surface_icccm_input_model() instead of the broken
-- client_hasproto(WM_TAKE_FOCUS) path where the atom stub is always 0.
--
-- xterm uses the Passive input model (input hint = true, no WM_TAKE_FOCUS)
-- which should result in focusable = true.
---------------------------------------------------------------------------

local runner = require("_runner")
local x11_client = require("_x11_client")

local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

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

local my_client

local steps = {
    -- Spawn X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client...\n")
            x11_client("focusable_test")
        end
        for _, c in ipairs(client.get()) do
            if c.class == "focusable_test" or
               (c.class == "XTerm" and x11_client.is_xwayland(c)) then
                my_client = c
                io.stderr:write("[TEST] X11 client spawned\n")
                return true
            end
        end
        if count > 50 then error("X11 client did not spawn") end
        return nil
    end,

    -- Wait for focus to settle
    function(count)
        if count < 5 then return nil end
        return true
    end,

    -- Verify focusable property
    function()
        assert(x11_client.is_xwayland(my_client),
            "Client should be XWayland")

        -- xterm uses Passive input model (input hint = true), so focusable should be true.
        -- Before the ICCCM fix, client_hasproto(WM_TAKE_FOCUS) always returned false
        -- for XWayland clients because the WM_TAKE_FOCUS atom stub was 0, causing
        -- focusable to be false for nofocus clients that support WM_TAKE_FOCUS
        -- (Globally Active model). For xterm (Passive model, nofocus=false),
        -- focusable was already true, but this test ensures the code path works.
        local focusable = my_client.focusable
        io.stderr:write(string.format(
            "[TEST] XWayland client: focusable=%s, nofocus=%s\n",
            tostring(focusable), tostring(my_client.nofocus)
        ))

        assert(focusable == true,
            "XWayland client (xterm) should be focusable")
        io.stderr:write("[TEST] PASS: XWayland client reports focusable=true\n")
        return true
    end,

    -- Also verify that focused client has real keyboard focus
    function()
        if client.focus == my_client then
            assert(my_client:has_keyboard_focus(),
                "Focusable X11 client with Lua focus should have REAL keyboard focus")
            io.stderr:write("[TEST] PASS: Focusable X11 client has real keyboard focus\n")
        else
            io.stderr:write("[TEST] INFO: X11 client not focused, skipping seat focus check\n")
        end
        return true
    end,

    -- Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup\n")
            if my_client and my_client.valid then my_client:kill() end
            os.execute("pkill -9 xterm 2>/dev/null")
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(x11_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
