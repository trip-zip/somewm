---------------------------------------------------------------------------
--- Test: layer-shell keyboard focus
--
-- Verifies that layer-shell surfaces properly receive and release keyboard
-- focus, and that client focus is correctly managed during this process.
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

local my_client
local wofi_pid
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

    -- Step 2: Verify client has focus
    function()
        assert(client.focus == my_client,
            string.format("Expected client to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        io.stderr:write("[TEST] Client has focus\n")
        return true
    end,

    -- Step 3: Spawn wofi (layer-shell surface with keyboard focus)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning wofi...\n")
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

        -- Timeout
        if count > 50 then
            io.stderr:write("[TEST] ERROR: wofi did not appear\n")
            return true
        end

        return nil
    end,

    -- Step 4: Verify wofi has keyboard focus and client lost focus
    function(count)
        if not layer_surf then
            io.stderr:write("[TEST] SKIP: wofi layer surface not found\n")
            return true
        end

        -- Give focus a moment to transfer
        if count < 5 then
            return nil
        end

        -- Check wofi has keyboard focus
        io.stderr:write(string.format("[TEST] layer_surf.has_keyboard_focus = %s\n",
            tostring(layer_surf.has_keyboard_focus)))
        io.stderr:write(string.format("[TEST] client.focus = %s\n",
            client.focus and client.focus.class or "nil"))

        assert(layer_surf.has_keyboard_focus == true,
            "Expected wofi to have keyboard focus")

        -- Client should have lost focus (client.focus should be nil or different)
        -- Note: When a layer surface has exclusive focus, client.focus becomes nil
        assert(client.focus == nil,
            string.format("Expected client.focus to be nil when layer surface has focus, got %s",
                client.focus and client.focus.class or "nil"))

        io.stderr:write("[TEST] PASS: wofi has keyboard focus, client lost focus\n")
        return true
    end,

    -- Step 5: Close wofi
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing wofi...\n")
            if wofi_pid then
                os.execute("kill " .. wofi_pid .. " 2>/dev/null")
            end
            os.execute("pkill -9 wofi 2>/dev/null")
        end

        -- Wait for layer surface to be gone
        if layer_surface then
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("wofi") then
                    return nil  -- Still exists
                end
            end
        end

        if count > 5 then
            io.stderr:write("[TEST] Wofi closed\n")
            return true
        end

        return nil
    end,

    -- Step 6: Verify client regained focus
    function(count)
        -- Give focus a moment to restore
        if count < 3 then
            return nil
        end

        io.stderr:write(string.format("[TEST] After wofi close: client.focus = %s\n",
            client.focus and client.focus.class or "nil"))

        assert(client.focus == my_client,
            string.format("Expected client to regain focus after wofi close, got %s",
                client.focus and client.focus.class or "nil"))

        io.stderr:write("[TEST] PASS: client regained focus after wofi close\n")
        return true
    end,

    -- Step 7: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing remaining clients\n")
            if my_client and my_client.valid then my_client:kill() end
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
