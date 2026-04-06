---------------------------------------------------------------------------
--- Test: compositor survives focus transfer when focused client unmaps
--
-- Regression test for #386: when the focused XDG client is killed, the
-- compositor must not crash while deactivating its surface during focus
-- restoration. The bug was that seat keyboard focus still pointed at the
-- dying surface (already uninitialized by wlroots) when focusclient()
-- tried to send it a deactivate configure event.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local client_a, client_b

local steps = {
    -- Step 1: Spawn client A
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client A...\n")
            test_client("unmap_test_a")
        end
        client_a = utils.find_client_by_class("unmap_test_a")
        if client_a then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Wait for client A to have focus
    function(count)
        if client.focus == client_a then
            io.stderr:write("[TEST] Client A has focus\n")
            return true
        end
        if count > 10 then
            error(string.format("Expected client A to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 3: Spawn client B (takes focus)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client B...\n")
            test_client("unmap_test_b")
        end
        client_b = utils.find_client_by_class("unmap_test_b")
        if client_b then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
        return nil
    end,

    -- Step 4: Ensure client B has focus and keyboard focus
    function(count)
        if client.focus == client_b then
            assert(client_b:has_keyboard_focus(),
                "Client B has focus but not keyboard focus")
            io.stderr:write("[TEST] Client B has focus + keyboard focus\n")
            return true
        end
        if count > 10 then
            error(string.format("Expected client B to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 5: Kill client B. Before the fix, this would crash the compositor
    -- because focusclient() would try to deactivate B's uninitialized surface.
    function(count)
        if count == 1 then
            io.stderr:write(string.format("[TEST] Killing client B (pid=%s)...\n",
                tostring(client_b.pid)))
            if client_b.pid then
                os.execute("kill -9 " .. client_b.pid .. " 2>/dev/null")
            else
                client_b:kill()
            end
        end

        if not client_b.valid or not utils.find_client_by_class("unmap_test_b") then
            io.stderr:write("[TEST] Client B is gone\n")
            return true
        end
        return nil
    end,

    -- Step 6: Verify compositor survived and focus moved to client A
    function(count)
        if client.focus == client_a then
            assert(client_a:has_keyboard_focus(),
                "Client A regained focus but NOT keyboard focus")
            io.stderr:write("[TEST] PASS: compositor survived, focus moved to client A\n")
            return true
        end

        if count > 10 then
            error(string.format("Expected focus to move to client A, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 7: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if client_a and client_a.valid then client_a:kill() end
        end

        if #client.get() == 0 then
            io.stderr:write("[TEST] Cleanup: done\n")
            return true
        end

        if count >= 10 then
            io.stderr:write("[TEST] Cleanup: force killing via SIGKILL\n")
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
