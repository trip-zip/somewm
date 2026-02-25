---------------------------------------------------------------------------
--- Test: XWayland focus re-delivery to same surface
--
-- Verifies that clearing and re-setting focus on the same XWayland client
-- correctly re-delivers keyboard focus. This tests the KWin MR !60 pattern
-- where wlr_seat_keyboard_enter() is cleared first to avoid the wlroots
-- same-surface skip.
--
-- Without the fix, wlroots silently drops the re-entry and the X11 client
-- never receives a second FocusIn event.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local x11_client = require("_x11_client")
local utils = require("_utils")

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

if not test_client.is_available() then
    io.stderr:write("SKIP: no Wayland terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local wayland_c
local x11_c

local steps = {
    -- Spawn a Wayland client first so we have something to transfer focus to
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning Wayland client...\n")
            test_client("redelivery_wayland")
        end
        wayland_c = utils.find_client_by_class("redelivery_wayland")
        if wayland_c then return true end
        return nil
    end,

    -- Spawn X11 client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 client...\n")
            x11_client("redelivery_x11")
        end
        for _, c in ipairs(client.get()) do
            if c.class == "redelivery_x11" or
               (c.class == "XTerm" and x11_client.is_xwayland(c) and c ~= wayland_c) then
                x11_c = c
                io.stderr:write("[TEST] X11 client spawned\n")
                return true
            end
        end
        if count > 50 then error("X11 client did not spawn") end
        return nil
    end,

    -- Wait for X11 client to have focus
    function(count)
        if count < 5 then return nil end
        if client.focus == x11_c then return true end
        if count > 20 then error("X11 client did not receive initial focus") end
        return nil
    end,

    -- Verify initial keyboard focus
    function()
        assert(x11_c:has_keyboard_focus(),
            "X11 client should have REAL keyboard focus initially")
        io.stderr:write("[TEST] PASS: X11 client has initial keyboard focus\n")
        return true
    end,

    -- Transfer focus away to Wayland client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Transferring focus to Wayland client...\n")
            client.focus = wayland_c
        end
        if count < 3 then return nil end
        if client.focus == wayland_c then return true end
        if count > 15 then error("Could not transfer focus to Wayland client") end
        return nil
    end,

    -- Re-deliver focus back to X11 client (same surface as before)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Re-delivering focus to X11 client...\n")
            client.focus = x11_c
        end
        if count < 3 then return nil end
        if client.focus == x11_c then return true end
        if count > 15 then error("Could not re-deliver focus to X11 client") end
        return nil
    end,

    -- THE KEY ASSERTION: after re-delivery, X11 client must have REAL keyboard focus
    function()
        assert(x11_c:has_keyboard_focus(),
            "FAIL: X11 client has Lua focus but not REAL keyboard focus after re-delivery. " ..
            "This indicates the KWin same-surface re-delivery pattern is broken.")
        io.stderr:write("[TEST] PASS: X11 client has REAL keyboard focus after re-delivery\n")
        return true
    end,

    -- Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup\n")
            if wayland_c and wayland_c.valid then wayland_c:kill() end
            if x11_c and x11_c.valid then x11_c:kill() end
            os.execute("pkill -9 xterm 2>/dev/null")
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(test_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            for _, pid in ipairs(x11_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
