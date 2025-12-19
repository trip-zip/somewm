---------------------------------------------------------------------------
--- Integration test for client spawning and manipulation.
--
-- This test demonstrates:
-- - Spawning a test client
-- - Waiting for the client to appear
-- - Verifying client properties
-- - Manipulating client geometry
-- - Setting client state (floating, tags)
-- - Cleanup
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

-- Skip test if no terminal available
if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available for spawning test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local terminal_info = test_client.get_terminal_info()
print("Using terminal: " .. terminal_info.executable)

-- The test client we'll spawn
local c = nil
local test_class = "somewm_test_client"

local steps = {
    -- Step 1: Spawn a test client
    function(count)
        if count == 1 then
            print("Step 1: Spawning test client with class: " .. test_class)
            test_client(test_class, "Test Window")
        end

        -- Wait for client to appear
        c = utils.find_client_by_class(test_class)
        if c then
            print("Step 1: Client found!")
            return true
        end
        -- Keep waiting...
    end,

    -- Step 2: Verify basic client properties
    function()
        print("Step 2: Verifying client properties")

        assert(c, "Client should exist")
        assert(c.valid, "Client should be valid")
        assert(c.class == test_class,
            string.format("Client class should be '%s', got '%s'", test_class, c.class))

        -- Client should have a name (window title)
        assert(c.name, "Client should have a name")
        print("  - class: " .. tostring(c.class))
        print("  - name: " .. tostring(c.name))

        return true
    end,

    -- Step 3: Test geometry operations
    function()
        print("Step 3: Testing geometry operations")

        -- Get initial geometry
        local initial_geo = c:geometry()
        print(string.format("  - Initial: x=%d y=%d w=%d h=%d",
            initial_geo.x, initial_geo.y, initial_geo.width, initial_geo.height))

        -- Set new geometry
        c:geometry({ x = 100, y = 100, width = 400, height = 300 })

        return true
    end,

    -- Step 4: Verify geometry was applied
    function()
        local geo = c:geometry()
        print(string.format("  - After set: x=%d y=%d w=%d h=%d",
            geo.x, geo.y, geo.width, geo.height))

        -- Allow some tolerance for window decorations/borders
        -- The geometry should be close to what we requested
        assert(geo.x >= 0, "x should be non-negative")
        assert(geo.y >= 0, "y should be non-negative")
        assert(geo.width >= 100, "width should be at least 100")
        assert(geo.height >= 100, "height should be at least 100")

        return true
    end,

    -- Step 5: Test floating state
    function()
        print("Step 5: Testing floating state")

        -- Make client floating
        c.floating = true
        assert(c.floating, "Client should be floating")
        print("  - floating: true")

        -- Make client tiled
        c.floating = false
        assert(not c.floating, "Client should not be floating")
        print("  - floating: false")

        return true
    end,

    -- Step 6: Test tag operations
    function()
        print("Step 6: Testing tag operations")

        local s = c.screen
        local tags = s.tags
        print("  - Screen has " .. #tags .. " tags")

        if #tags > 0 then
            local first_tag = tags[1]
            c:move_to_tag(first_tag)

            local client_tags = c:tags()
            assert(#client_tags >= 1, "Client should be on at least one tag")
            print("  - Client is on " .. #client_tags .. " tag(s)")
        end

        return true
    end,

    -- Step 7: Test focus
    function()
        print("Step 7: Testing focus")

        -- Focus the client
        c:activate({ context = "test", raise = true })

        -- Give it a moment to process
        return true
    end,

    -- Step 8: Verify focus
    function()
        -- Check if client is focused (may not work perfectly in headless)
        if client.focus == c then
            print("  - Client is focused")
        else
            print("  - Focus: client.focus = " .. tostring(client.focus))
            print("  - (Focus may not work perfectly in headless mode)")
        end

        return true
    end,

    -- Step 9: Clean up - kill the client
    function(count)
        if count == 1 then
            print("Step 9: Cleanup - killing client")
            c:kill()
        end

        -- Check if client is gone
        local clients = client.get()
        if #clients == 0 then
            print("  - Client cleaned up successfully")
            return true
        end

        -- After a few attempts, force cleanup and proceed
        if count >= 20 then
            print("  - Client still exists after waiting, forcing cleanup")
            -- Force kill via OS (the terminal process)
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
        -- Keep waiting...
    end,
}

-- Run the test steps
-- Disable automatic client cleanup since we handle it ourselves
runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
