---------------------------------------------------------------------------
--- Test: tiled clients rearrange when fullscreen is Lua-set, client-unset
--
-- Reproduces the bug where:
-- 1. Lua sets c.fullscreen = true on client A (other clients rearrange)
-- 2. Client A sends xdg_toplevel_unset_fullscreen (e.g., Firefox Escape)
-- 3. Other tiled clients should rearrange to give A space again
--
-- Without the fix, setfullscreen() only emits a global signal, not the
-- per-client property::fullscreen signal. update_implicitly_floating never
-- runs, so get_floating() returns stale true, client.tiled() excludes A,
-- and other clients are not rearranged.
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

local client_a       -- fullscreen test client (supports SIGUSR2 unfullscreen)
local client_b       -- regular tiled client
local proc_pid_a
local initial_geo_a
local initial_geo_b
local expanded_geo_b

local steps = {
    -- Step 0: Set tile layout
    function()
        local tag = awful.screen.focused().selected_tag
        tag.layout = awful.layout.suit.tile
        io.stderr:write("[TEST] Set layout to tile\n")
        return true
    end,

    -- Step 1: Spawn the regular tiled client (B)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning regular tiled client (B)...\n")
            test_client("tiled_buddy")
        end
        client_b = utils.find_client_by_class("tiled_buddy")
        if client_b then
            io.stderr:write("[TEST] Client B appeared\n")
            return true
        end
    end,

    -- Step 2: Spawn the fullscreen test client (A)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test-fullscreen-client (A)...\n")
            proc_pid_a = awful.spawn(TEST_FULLSCREEN_CLIENT)
        end
        client_a = utils.find_client_by_class("fullscreen_test")
        if client_a then
            io.stderr:write("[TEST] Client A appeared\n")
            return true
        end
    end,

    -- Step 3: Record initial tiled geometries (let layout settle)
    function(count)
        if count < 5 then return nil end

        initial_geo_a = {
            x = client_a.x, y = client_a.y,
            width = client_a.width, height = client_a.height,
        }
        initial_geo_b = {
            x = client_b.x, y = client_b.y,
            width = client_b.width, height = client_b.height,
        }

        io.stderr:write(string.format(
            "[TEST] Initial A: %dx%d+%d+%d\n",
            initial_geo_a.width, initial_geo_a.height,
            initial_geo_a.x, initial_geo_a.y))
        io.stderr:write(string.format(
            "[TEST] Initial B: %dx%d+%d+%d\n",
            initial_geo_b.width, initial_geo_b.height,
            initial_geo_b.x, initial_geo_b.y))

        assert(not client_a.fullscreen, "A should not be fullscreen initially")
        assert(not client_b.fullscreen, "B should not be fullscreen initially")

        -- Sanity: with 2 tiled clients in tile layout, neither should fill
        -- the full workarea width
        local wa = awful.screen.focused().workarea
        assert(initial_geo_a.width < wa.width,
            "A should not fill full workarea width when tiled with B")

        return true
    end,

    -- Step 4: Set A fullscreen via Lua, verify B expands
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Setting A.fullscreen = true from Lua\n")
            client_a.fullscreen = true
        end
        if count < 5 then return nil end

        assert(client_a.fullscreen, "A should be fullscreen")

        expanded_geo_b = {
            x = client_b.x, y = client_b.y,
            width = client_b.width, height = client_b.height,
        }
        io.stderr:write(string.format(
            "[TEST] B after A fullscreen: %dx%d+%d+%d\n",
            expanded_geo_b.width, expanded_geo_b.height,
            expanded_geo_b.x, expanded_geo_b.y))

        -- B should have expanded (it's now the only tiled client)
        local wa = awful.screen.focused().workarea
        -- In tile layout with master_width_factor=0.5 and 1 client,
        -- the single client gets the full workarea width minus gaps/borders
        assert(expanded_geo_b.width > initial_geo_b.width,
            string.format("B should expand when A goes fullscreen: %d > %d",
                expanded_geo_b.width, initial_geo_b.width))

        io.stderr:write("[TEST] PASS: B expanded when A went fullscreen\n")
        return true
    end,

    -- Step 5: Client A requests unfullscreen via protocol (SIGUSR2)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGUSR2 to A (protocol unfullscreen)\n")
            awesome.kill(proc_pid_a, 12) -- SIGUSR2 = 12
        end

        if client_a.fullscreen then return nil end
        if count > 30 then
            error("Timed out waiting for A to unfullscreen")
        end

        io.stderr:write("[TEST] A is no longer fullscreen\n")
        return true
    end,

    -- Step 6: Verify B rearranged back to share space with A
    function(count)
        if count < 5 then return nil end

        local restored_geo_b = {
            x = client_b.x, y = client_b.y,
            width = client_b.width, height = client_b.height,
        }
        local restored_geo_a = {
            x = client_a.x, y = client_a.y,
            width = client_a.width, height = client_a.height,
        }

        io.stderr:write(string.format(
            "[TEST] A after unfullscreen: %dx%d+%d+%d\n",
            restored_geo_a.width, restored_geo_a.height,
            restored_geo_a.x, restored_geo_a.y))
        io.stderr:write(string.format(
            "[TEST] B after A unfullscreen: %dx%d+%d+%d\n",
            restored_geo_b.width, restored_geo_b.height,
            restored_geo_b.x, restored_geo_b.y))

        -- KEY ASSERTION: B should have shrunk back from expanded state
        -- to approximately its initial width (sharing space with A again)
        assert(restored_geo_b.width < expanded_geo_b.width,
            string.format(
                "B should shrink when A exits fullscreen: got %d, was %d when expanded",
                restored_geo_b.width, expanded_geo_b.width))

        -- B should be close to its initial geometry (within tolerance for
        -- border width changes)
        local tolerance = 10
        assert(math.abs(restored_geo_b.width - initial_geo_b.width) <= tolerance,
            string.format(
                "B width should return to initial: got %d, expected ~%d",
                restored_geo_b.width, initial_geo_b.width))

        -- A should also be tiled at roughly its initial size
        assert(math.abs(restored_geo_a.width - initial_geo_a.width) <= tolerance,
            string.format(
                "A width should return to initial: got %d, expected ~%d",
                restored_geo_a.width, initial_geo_a.width))

        io.stderr:write("[TEST] PASS: tiled clients rearranged correctly\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(function()
        if proc_pid_a then
            os.execute("kill -9 " .. proc_pid_a .. " 2>/dev/null")
        end
        os.execute("pkill -9 test-fullscreen 2>/dev/null")
    end),
}

runner.run_steps(steps, { kill_clients = false })
