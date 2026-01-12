---------------------------------------------------------------------------
--- Test: focus history when client is killed
--
-- Verifies that when the focused client is killed, focus moves to the
-- previous client in focus history (not just any client).
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local client_a, client_b, client_c

local steps = {
    -- Step 1: Spawn client A
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client A...\n")
            test_client("focus_test_a")
        end
        client_a = utils.find_client_by_class("focus_test_a")
        if client_a then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Spawn client B
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client B...\n")
            test_client("focus_test_b")
        end
        client_b = utils.find_client_by_class("focus_test_b")
        if client_b then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
        return nil
    end,

    -- Step 3: Spawn client C
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client C...\n")
            test_client("focus_test_c")
        end
        client_c = utils.find_client_by_class("focus_test_c")
        if client_c then
            io.stderr:write("[TEST] Client C spawned\n")
            return true
        end
        return nil
    end,

    -- Step 4: Wait for client C to have focus
    function(count)
        io.stderr:write(string.format("[TEST] Checking focus (attempt %d): client.focus.class=%s\n",
            count, client.focus and client.focus.class or "nil"))

        if client.focus == client_c then
            io.stderr:write("[TEST] PASS: client C has focus\n")
            return true
        end

        if count > 10 then
            error(string.format("Expected client C to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 5: Kill client C (force kill to avoid confirmation dialogs)
    function(count)
        if count == 1 then
            io.stderr:write(string.format("[TEST] Force killing client C (pid=%s)...\n",
                tostring(client_c.pid)))
            if client_c.pid then
                os.execute("kill -9 " .. client_c.pid .. " 2>/dev/null")
            else
                client_c:kill()
            end
        end

        -- Wait for client C to be gone
        if not client_c.valid or not utils.find_client_by_class("focus_test_c") then
            io.stderr:write("[TEST] Client C is gone\n")
            return true
        end
        return nil
    end,

    -- Step 6: Wait for focus to move to client B
    function(count)
        io.stderr:write(string.format("[TEST] Checking focus after kill (attempt %d): client.focus.class=%s\n",
            count, client.focus and client.focus.class or "nil"))

        if client.focus == client_b then
            io.stderr:write("[TEST] PASS: focus moved to client B (correct focus history)\n")
            return true
        end

        if count > 10 then
            error(string.format("Expected focus to move to client B, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 7: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if client_a and client_a.valid then client_a:kill() end
            if client_b and client_b.valid then client_b:kill() end
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
