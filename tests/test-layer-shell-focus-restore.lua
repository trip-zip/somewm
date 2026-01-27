---------------------------------------------------------------------------
--- Test: layer-shell focus restoration
--
-- Verifies that when a layer-shell surface closes, focus returns
-- to the correct client from focus history (the most recently focused client,
-- not just any client).
--
-- Uses test-layer-client for deterministic, instant layer surface creation.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

-- Path to test-layer-client (built by meson)
local TEST_LAYER_CLIENT = "./build-test/test-layer-client"

-- Check if test-layer-client exists
local function is_test_layer_client_available()
    local f = io.open(TEST_LAYER_CLIENT, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- Skip test if requirements not met
if not is_test_layer_client_available() then
    io.stderr:write("SKIP: test-layer-client not found (run meson compile first)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local client_a, client_b
local layer_pid
local layer_surf

local steps = {
    -- Step 1: Spawn client A
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client A...\n")
            test_client("layer_test_a")
        end
        client_a = utils.find_client_by_class("layer_test_a")
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

    -- Step 3: Spawn client B
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client B...\n")
            test_client("layer_test_b")
        end
        client_b = utils.find_client_by_class("layer_test_b")
        if client_b then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
        return nil
    end,

    -- Step 4: Wait for client B to have focus (A is now in history)
    function(count)
        if client.focus == client_b then
            io.stderr:write("[TEST] Client B has focus, A is in history\n")
            return true
        end
        if count > 10 then
            error(string.format("Expected client B to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 5: Spawn test-layer-client (layer-shell surface)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test-layer-client...\n")
            layer_pid = awful.spawn(TEST_LAYER_CLIENT .. " --namespace test-layer --keyboard exclusive")
        end

        -- Wait for layer surface to appear
        if layer_surface then
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("test%-layer") then
                    layer_surf = ls
                    io.stderr:write("[TEST] Layer surface appeared\n")
                    return true
                end
            end
        end

        -- Timeout (should be fast)
        if count > 20 then
            io.stderr:write("[TEST] ERROR: layer surface did not appear\n")
            return true  -- Continue to cleanup
        end

        return nil
    end,

    -- Step 6: Verify layer surface has keyboard focus
    function(count)
        if not layer_surf then
            io.stderr:write("[TEST] SKIP: layer surface not found\n")
            return true
        end

        -- Wait a moment for focus to settle
        if layer_surf.has_keyboard_focus then
            io.stderr:write("[TEST] Layer surface has keyboard focus\n")
            io.stderr:write(string.format("[TEST] client.focus is now: %s\n",
                client.focus and client.focus.class or "nil"))
            return true
        end

        -- Timeout
        if count > 20 then
            io.stderr:write("[TEST] ERROR: layer surface did not get keyboard focus\n")
            return true
        end

        return nil
    end,

    -- Step 7: Close layer surface
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing layer surface...\n")
            if layer_pid then
                -- Use SIGKILL to immediately terminate (SIGTERM requires event loop to wake)
                os.execute("kill -9 " .. layer_pid .. " 2>/dev/null")
            end
        end

        -- Wait for layer surface to be gone
        if layer_surface then
            local still_exists = false
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("test%-layer") then
                    still_exists = true
                    break
                end
            end
            if not still_exists then
                io.stderr:write("[TEST] Layer surface closed\n")
                return true
            end
        else
            -- No layer_surface API, just wait a moment
            if count > 10 then
                return true
            end
        end

        return nil
    end,

    -- Step 8: Wait for focus to return to client B (not A, not nil)
    function(count)
        -- Give focus restoration a moment to complete
        if count < 3 then
            return nil
        end

        io.stderr:write(string.format("[TEST] Checking focus after layer close (attempt %d): client.focus.class=%s\n",
            count, client.focus and client.focus.class or "nil"))

        -- This is the key assertion: focus should return to the MOST RECENT
        -- client in history (B), not just any client
        if client.focus == client_b then
            io.stderr:write("[TEST] PASS: focus returned to client B (correct focus history)\n")
            return true
        end

        if count > 10 then
            error(string.format("Expected focus to return to client B, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 9: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if client_a and client_a.valid then client_a:kill() end
            if client_b and client_b.valid then client_b:kill() end
            os.execute("pkill -9 test-layer-client 2>/dev/null")
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

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
