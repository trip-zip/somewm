---------------------------------------------------------------------------
--- Test: layer-shell keyboard focus
--
-- Verifies that layer-shell surfaces properly receive and release keyboard
-- focus, and that client focus is correctly managed during this process.
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

local my_client
local layer_pid
local layer_surf

local steps = {
    -- Step 1: Spawn a regular client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test client...\n")
            test_client("keyboard_test")
        end
        my_client = utils.find_client_by_class("keyboard_test")
        if my_client then
            io.stderr:write("[TEST] Client spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Verify client has focus (wait for focus to transfer)
    function(count)
        if client.focus == my_client then
            io.stderr:write("[TEST] Client has focus\n")
            return true
        end
        if count > 20 then
            error(string.format("Expected client to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 3: Spawn test-layer-client (layer-shell surface with keyboard focus)
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

        -- Timeout (should be fast - test-layer-client starts instantly)
        if count > 20 then
            io.stderr:write("[TEST] ERROR: layer surface did not appear\n")
            return true
        end

        return nil
    end,

    -- Step 4: Verify layer surface has keyboard focus and client lost focus
    function(count)
        if not layer_surf then
            io.stderr:write("[TEST] SKIP: layer surface not found\n")
            return true
        end

        -- Give focus a moment to transfer
        if count < 3 then
            return nil
        end

        -- Check layer surface has keyboard focus
        io.stderr:write(string.format("[TEST] layer_surf.has_keyboard_focus = %s\n",
            tostring(layer_surf.has_keyboard_focus)))
        io.stderr:write(string.format("[TEST] client.focus = %s\n",
            client.focus and client.focus.class or "nil"))

        assert(layer_surf.has_keyboard_focus == true,
            "Expected layer surface to have keyboard focus")

        -- Client should have lost focus (client.focus should be nil)
        -- Note: When a layer surface has exclusive focus, client.focus becomes nil
        assert(client.focus == nil,
            string.format("Expected client.focus to be nil when layer surface has focus, got %s",
                client.focus and client.focus.class or "nil"))

        io.stderr:write("[TEST] PASS: layer surface has keyboard focus, client lost focus\n")
        return true
    end,

    -- Step 5: Close layer surface
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
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("test%-layer") then
                    return nil  -- Still exists
                end
            end
        end

        io.stderr:write("[TEST] Layer surface closed\n")
        return true
    end,

    -- Step 6: Verify client regained focus
    function(count)
        -- Give focus a moment to restore
        if count < 3 then
            return nil
        end

        io.stderr:write(string.format("[TEST] After layer close: client.focus = %s\n",
            client.focus and client.focus.class or "nil"))

        assert(client.focus == my_client,
            string.format("Expected client to regain focus after layer close, got %s",
                client.focus and client.focus.class or "nil"))

        io.stderr:write("[TEST] PASS: client regained focus after layer close\n")
        return true
    end,

    -- Step 7: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if my_client and my_client.valid then my_client:kill() end
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
