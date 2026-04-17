---------------------------------------------------------------------------
--- Test: XWayland override_redirect popup stacking
--
-- Bug: Override_redirect X11 surfaces (Wine menus, Steam popups, tooltips)
-- appeared BELOW their parent window instead of above it.
--
-- Root cause: stack_refresh() called client_layer_translator() on
-- override_redirect clients, which returned WINDOW_LAYER_NORMAL (LyrTile)
-- by default because unmanaged clients have no stacking attributes. This
-- reparented popups out of mapnotify()'s placement and dropped them
-- below floating parent windows.
--
-- Fix: stack_refresh() skips unmanaged (override_redirect) clients
-- entirely; mapnotify() places them in LyrOverlay so they display above
-- all managed windows (LyrBlock still covers them under session lock).
--
-- This test:
-- 1. Spawns a managed X11 client (parent window)
-- 2. Makes it floating (LyrFloat)
-- 3. Spawns an override_redirect X11 window (simulates popup menu)
-- 4. Triggers multiple stack_refresh() cycles via property toggles
-- 5. Verifies the compositor does not crash
--
-- Relates to: trip-zip/somewm#415
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local x11_client = require("_x11_client")
local utils = require("_utils")
local awful = require("awful")

-- Check if we're in headless mode
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

local managed_client
local override_redirect_pid
local initial_client_count

local steps = {
    -- Step 1: Spawn a managed X11 client (simulates parent window)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning managed X11 client...\n")
            x11_client("or_stacking_parent")
            initial_client_count = #client.get()
        end

        for _, c in ipairs(client.get()) do
            if c.class == "or_stacking_parent" or
               (c.class == "XTerm" and x11_client.is_xwayland(c) and not managed_client) then
                managed_client = c
                io.stderr:write(string.format(
                    "[TEST] Managed X11 client spawned: class=%s\n", c.class
                ))
                return true
            end
        end

        if count > 50 then
            error("Managed X11 client did not spawn within timeout")
        end
    end,

    -- Step 2: Make the managed client floating (moves to LyrFloat)
    function(count)
        if count < 3 then return nil end

        managed_client.floating = true
        assert(managed_client.floating, "Client should be floating")
        io.stderr:write("[TEST] Managed client set to floating (LyrFloat)\n")
        return true
    end,

    -- Step 3: Spawn an override_redirect window (simulates popup/menu)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning override_redirect X11 window...\n")
            -- Use the helper to create an override_redirect window
            local display = os.getenv("DISPLAY") or ":0"
            override_redirect_pid = awful.spawn({
                "python3", "tests/helpers/x11_override_redirect.py",
                "or_stacking_popup", "50", "50", "200", "150"
            })
        end

        -- Wait for the override_redirect window to appear.
        -- Override_redirect windows are unmanaged but still in client.get()
        if count > 5 then
            -- Give time for the window to map
            io.stderr:write(string.format(
                "[TEST] Client count: %d (was %d before managed spawn)\n",
                #client.get(), initial_client_count
            ))
            return true
        end
    end,

    -- Step 4: Trigger multiple stack_refresh() cycles.
    -- This is the critical test: before the fix, stack_refresh() would
    -- reparent the override_redirect window from LyrOverlay to LyrTile,
    -- placing it below the floating parent window.
    function()
        io.stderr:write("[TEST] Triggering stack_refresh cycles via property toggles...\n")

        -- Toggle ontop on managed client (triggers stack_refresh)
        managed_client.ontop = true
        assert(managed_client.ontop, "ontop should be true")

        managed_client.ontop = false
        assert(not managed_client.ontop, "ontop should be false")

        -- Toggle above (triggers stack_refresh)
        managed_client.above = true
        managed_client.above = false

        -- Toggle floating (triggers arrange + stack_refresh)
        managed_client.floating = false
        managed_client.floating = true

        -- Toggle fullscreen (triggers stack_refresh)
        managed_client.fullscreen = true
        managed_client.fullscreen = false

        io.stderr:write("[TEST] PASS: stack_refresh survived all toggles with override_redirect present\n")
        return true
    end,

    -- Step 5: Verify managed client is still accessible and valid
    function()
        assert(managed_client.valid, "Managed client should still be valid")
        assert(managed_client.floating, "Managed client should still be floating")

        io.stderr:write("[TEST] PASS: managed client still valid after stacking cycles\n")
        return true
    end,

    -- Step 6: Cleanup
    function()
        if override_redirect_pid then
            os.execute("kill " .. override_redirect_pid .. " 2>/dev/null")
        end
        os.execute("pkill -f x11_override_redirect.py 2>/dev/null")
        managed_client:kill()

        -- Wait a frame for cleanup
        io.stderr:write("Test finished successfully.\n")
        awesome.quit()
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
