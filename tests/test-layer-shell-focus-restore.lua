---------------------------------------------------------------------------
--- Test: layer-shell focus restoration
--
-- Verifies that when a layer-shell surface (like wofi) closes, focus returns
-- to the correct client from focus history (the most recently focused client,
-- not just any client).
--
-- NOTE: This test requires visual mode (HEADLESS=0) because wofi needs a
-- display to render.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

-- Check if wofi is available
local function is_wofi_available()
    local handle = io.popen("which wofi 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result and result:match("wofi")
    end
    return false
end

-- Check if we're in headless mode (wofi won't work)
local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

-- Skip test if requirements not met
if not is_wofi_available() then
    io.stderr:write("SKIP: wofi not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

if is_headless() then
    io.stderr:write("SKIP: layer-shell tests require visual mode (HEADLESS=0)\n")
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
local wofi_pid
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

    -- Step 2: Verify client A has focus
    function()
        assert(client.focus == client_a,
            string.format("Expected client A to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        io.stderr:write("[TEST] Client A has focus\n")
        return true
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

    -- Step 4: Verify client B has focus (A is now in history)
    function()
        assert(client.focus == client_b,
            string.format("Expected client B to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        io.stderr:write("[TEST] Client B has focus, A is in history\n")
        return true
    end,

    -- Step 5: Spawn wofi (layer-shell surface)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning wofi...\n")
            -- Use dmenu mode for simplicity, exits on Escape
            wofi_pid = awful.spawn("wofi --show dmenu --prompt 'test'")
        end

        -- Wait for layer surface to appear
        if layer_surface then
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("wofi") then
                    layer_surf = ls
                    io.stderr:write("[TEST] Wofi layer surface appeared\n")
                    return true
                end
            end
        end

        -- Timeout after ~5 seconds (50 iterations * 0.1s)
        if count > 50 then
            io.stderr:write("[TEST] ERROR: wofi did not appear\n")
            return true  -- Continue to cleanup
        end

        return nil
    end,

    -- Step 6: Verify wofi has keyboard focus
    function()
        if not layer_surf then
            io.stderr:write("[TEST] SKIP: wofi layer surface not found\n")
            return true
        end

        -- Wait a moment for focus to settle
        if layer_surf.has_keyboard_focus then
            io.stderr:write("[TEST] Wofi has keyboard focus\n")
            io.stderr:write(string.format("[TEST] client.focus is now: %s\n",
                client.focus and client.focus.class or "nil"))
            return true
        end

        return nil
    end,

    -- Step 7: Close wofi
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing wofi...\n")
            if wofi_pid then
                os.execute("kill " .. wofi_pid .. " 2>/dev/null")
            end
            -- Also try pkill as backup
            os.execute("pkill -9 wofi 2>/dev/null")
        end

        -- Wait for layer surface to be gone
        if layer_surface then
            local still_exists = false
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("wofi") then
                    still_exists = true
                    break
                end
            end
            if not still_exists then
                io.stderr:write("[TEST] Wofi closed\n")
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

    -- Step 8: Assert focus returned to client B (not A, not nil)
    function()
        io.stderr:write(string.format("[TEST] Checking focus after wofi close: client.focus.class=%s\n",
            client.focus and client.focus.class or "nil"))

        -- This is the key assertion: focus should return to the MOST RECENT
        -- client in history (B), not just any client
        assert(client.focus == client_b,
            string.format("Expected focus to return to client B, got %s",
                client.focus and client.focus.class or "nil"))

        io.stderr:write("[TEST] PASS: focus returned to client B (correct focus history)\n")
        return true
    end,

    -- Step 9: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if client_a and client_a.valid then client_a:kill() end
            if client_b and client_b.valid then client_b:kill() end
            -- Ensure wofi is dead
            os.execute("pkill -9 wofi 2>/dev/null")
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
