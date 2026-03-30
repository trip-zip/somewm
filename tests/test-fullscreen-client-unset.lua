---------------------------------------------------------------------------
--- Test: geometry restore when client unfullscreens after Lua-set fullscreen
--
-- Reproduces the bug where:
-- 1. Lua sets c.fullscreen = true (via client_set_fullscreen)
-- 2. Client sends xdg_toplevel_unset_fullscreen (via fullscreennotify)
-- 3. Geometry should restore to pre-fullscreen state
--
-- Without the fix, c->prev is never saved in the Lua path, so
-- setfullscreen(c, false) restores a stale/wrong geometry.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

local TEST_FULLSCREEN_CLIENT = "./build-test/test-fullscreen-client"

local function is_test_client_available()
    local f = io.open(TEST_FULLSCREEN_CLIENT, "r")
    if f then
        f:close()
        return true
    end
    return false
end

if not is_test_client_available() then
    io.stderr:write("SKIP: test-fullscreen-client not found (run make build-test)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local my_client
local proc_pid
local initial_geo

local steps = {
    -- Step 1: Spawn the C test client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test-fullscreen-client...\n")
            proc_pid = awful.spawn(TEST_FULLSCREEN_CLIENT)
        end

        my_client = utils.find_client_by_class("fullscreen_test")
        if my_client then
            io.stderr:write("[TEST] Client appeared\n")
            return true
        end
    end,

    -- Step 2: Record initial geometry (let client settle first)
    function(count)
        if count < 3 then return nil end

        initial_geo = {
            x = my_client.x,
            y = my_client.y,
            width = my_client.width,
            height = my_client.height,
        }
        io.stderr:write(string.format(
            "[TEST] Initial geometry: %dx%d+%d+%d\n",
            initial_geo.width, initial_geo.height,
            initial_geo.x, initial_geo.y))

        assert(not my_client.fullscreen, "Should not be fullscreen initially")
        return true
    end,

    -- Step 3: Set fullscreen via Lua
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting c.fullscreen = true from Lua\n")
            my_client.fullscreen = true
        end
        if count < 3 then return nil end

        assert(my_client.fullscreen, "c.fullscreen should be true")
        assert(my_client.xdg_fullscreen, "c.xdg_fullscreen should be true")

        io.stderr:write("[TEST] PASS: client is fullscreen\n")
        return true
    end,

    -- Step 4: Client requests unfullscreen via protocol (SIGUSR2)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGUSR2 (client requests unfullscreen)\n")
            awesome.kill(proc_pid, 12) -- SIGUSR2 = 12
        end

        -- Wait for the compositor to process the unfullscreen request
        if my_client.fullscreen then return nil end
        if count > 30 then
            error("Timed out waiting for unfullscreen")
        end

        io.stderr:write("[TEST] Client is no longer fullscreen\n")
        return true
    end,

    -- Step 5: Verify geometry was restored
    function(count)
        if count < 3 then return nil end

        local geo = {
            x = my_client.x,
            y = my_client.y,
            width = my_client.width,
            height = my_client.height,
        }
        io.stderr:write(string.format(
            "[TEST] Restored geometry: %dx%d+%d+%d\n",
            geo.width, geo.height, geo.x, geo.y))

        assert(geo.width == initial_geo.width,
            string.format("Width mismatch: got %d, expected %d",
                geo.width, initial_geo.width))
        assert(geo.height == initial_geo.height,
            string.format("Height mismatch: got %d, expected %d",
                geo.height, initial_geo.height))
        assert(not my_client.xdg_fullscreen,
            "c.xdg_fullscreen should be false after unfullscreen")

        io.stderr:write("[TEST] PASS: geometry restored correctly\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(function()
        if proc_pid then
            os.execute("kill -9 " .. proc_pid .. " 2>/dev/null")
        end
        os.execute("pkill -9 test-fullscreen-client 2>/dev/null")
    end),
}

runner.run_steps(steps, { kill_clients = false })
