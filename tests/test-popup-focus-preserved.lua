---------------------------------------------------------------------------
--- Test: Wayland popup focus preservation
--
-- Verifies that Lua-driven focus on an already-focused XDG client does not
-- disrupt its keyboard focus state. This is the regression test for the
-- popup menu click bug: when a user clicks on a popup menu (e.g. Firefox
-- right-click menu), the click binding re-sets client.focus to the same
-- client. If that re-focus triggers a clear→re-enter cycle, it disrupts
-- the XDG popup grab and the menu closes.
--
-- The fix: some_set_seat_keyboard_focus() early-returns for XDG clients
-- when the surface is already focused, preserving popup grabs.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")

if not test_client.is_available() then
    io.stderr:write("SKIP: no Wayland terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local client_a, client_b

local steps = {
    -- Step 1: Spawn a native Wayland client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning Wayland client A...\n")
            test_client("popup_focus_a")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "popup_focus_a" then
                client_a = c
                io.stderr:write("[TEST] Client A spawned\n")
                return true
            end
        end

        if count > 50 then error("Client A did not spawn within timeout") end
        return nil
    end,

    -- Step 2: Wait for focus to settle on client A
    function(count)
        if count < 3 then return nil end
        if client.focus == client_a then return true end
        if count > 20 then error("Client A did not receive initial focus") end
        return nil
    end,

    -- Step 3: Verify client A has real keyboard focus
    function()
        assert(client_a:has_keyboard_focus(),
            "Client A should have REAL keyboard focus initially")
        io.stderr:write("[TEST] PASS: Client A has initial keyboard focus\n")
        return true
    end,

    -- Step 4: Re-set focus to the SAME client (simulates click binding re-focus)
    -- This is the key action: if the compositor clears→re-enters, popup grabs break.
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Re-setting focus to same client (simulates popup click)...\n")
            client.focus = client_a
        end
        if count < 3 then return nil end
        return true
    end,

    -- Step 5: Verify client A STILL has real keyboard focus (not disrupted)
    function()
        assert(client.focus == client_a,
            "Lua focus should still be on Client A")
        assert(client_a:has_keyboard_focus(),
            "FAIL: Client A lost REAL keyboard focus after same-client re-focus. " ..
            "This indicates the XDG popup grab preservation fix is broken.")
        io.stderr:write("[TEST] PASS: Client A still has keyboard focus after re-focus\n")
        return true
    end,

    -- Step 6: Spawn a second client and transfer focus away
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning Wayland client B...\n")
            test_client("popup_focus_b")
        end

        for _, c in ipairs(client.get()) do
            if c.class == "popup_focus_b" then
                client_b = c
                io.stderr:write("[TEST] Client B spawned\n")
                return true
            end
        end

        if count > 50 then error("Client B did not spawn within timeout") end
        return nil
    end,

    -- Step 7: Wait for focus to settle on client B
    function(count)
        if count < 3 then return nil end
        if client.focus == client_b then return true end
        if count > 20 then error("Client B did not receive focus") end
        return nil
    end,

    -- Step 8: Transfer focus back to client A
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Transferring focus back to Client A...\n")
            client.focus = client_a
        end
        if count < 3 then return nil end
        if client.focus == client_a then return true end
        if count > 15 then error("Could not transfer focus back to Client A") end
        return nil
    end,

    -- Step 9: Verify client A regains real keyboard focus
    function()
        assert(client_a:has_keyboard_focus(),
            "FAIL: Client A did not regain REAL keyboard focus after transfer. " ..
            "Focus transfer between XDG clients is broken.")
        io.stderr:write("[TEST] PASS: Client A regained keyboard focus after transfer\n")
        return true
    end,

    -- Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup\n")
            if client_a and client_a.valid then client_a:kill() end
            if client_b and client_b.valid then client_b:kill() end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(test_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
