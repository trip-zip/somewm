---------------------------------------------------------------------------
--- Test: minimized clients restore to full size after other clients close
--
-- Regression test for #329: when a tiled client is minimized, the other
-- client is closed, and the minimized client is restored, the window frame
-- occupies the full layout area but the client's rendered content stays at
-- the old (half) size because the suspended state was never cleared.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local c1, c2
local tag

local steps = {
    -- Step 1: Spawn first client
    function(count)
        if count == 1 then
            tag = screen.primary.tags[1]
            tag:view_only()
            tag.layout = awful.layout.suit.tile
            io.stderr:write("[TEST] Spawning client 1...\n")
            test_client("restore_a")
        end
        c1 = utils.find_client_by_class("restore_a")
        if c1 then
            io.stderr:write("[TEST] Client 1 spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Spawn second client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client 2...\n")
            test_client("restore_b")
        end
        c2 = utils.find_client_by_class("restore_b")
        if c2 then
            io.stderr:write("[TEST] Client 2 spawned\n")
            return true
        end
        return nil
    end,

    -- Step 3: Both clients should be tiled, each taking half the screen
    function()
        assert(#tag:clients() == 2, "Expected 2 clients on tag")
        assert(not c1.floating, "Client 1 should be tiled")
        assert(not c2.floating, "Client 2 should be tiled")
        io.stderr:write("[TEST] Both clients tiled\n")
        return true
    end,

    -- Step 4: Minimize client 1
    function()
        io.stderr:write("[TEST] Minimizing client 1...\n")
        c1.minimized = true
        assert(c1.minimized, "Client 1 should be minimized")
        return true
    end,

    -- Step 5: Close client 2
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing client 2...\n")
            if c2.pid then
                os.execute("kill -9 " .. c2.pid .. " 2>/dev/null")
            else
                c2:kill()
            end
        end
        -- Wait for client 2 to be gone
        if #client.get() <= 1 then
            io.stderr:write("[TEST] Client 2 closed\n")
            return true
        end
        return nil
    end,

    -- Step 6: Restore client 1
    function()
        io.stderr:write("[TEST] Restoring client 1...\n")
        c1.minimized = false
        assert(not c1.minimized, "Client 1 should be unminimized")
        return true
    end,

    -- Step 7: Wait a frame for layout to settle, then verify geometry
    function()
        -- After restore, c1 should be the only client and should fill
        -- the full layout area (the workarea minus any gaps/borders).
        local wa = tag.screen.workarea

        -- The client geometry should approximately fill the workarea.
        -- Use the width as the primary check: it should be close to the
        -- full workarea width, not half of it.
        local geo = c1:geometry()
        local bw = c1.border_width or 0
        local total_w = geo.width + 2 * bw

        io.stderr:write(string.format(
            "[TEST] Client geometry: %dx%d+%d+%d (bw=%d), workarea: %dx%d+%d+%d\n",
            geo.width, geo.height, geo.x, geo.y, bw,
            wa.width, wa.height, wa.x, wa.y))

        -- The client should use at least 80% of the workarea width.
        -- (Exact match depends on gaps/useless_gap settings, but half-width
        -- would be ~50%, so 80% is a safe threshold.)
        assert(total_w > wa.width * 0.8,
            string.format(
                "Client width %d is too small (workarea width %d). " ..
                "Client did not restore to full size after unminimize.",
                total_w, wa.width))

        io.stderr:write("[TEST] PASS: client restored to full layout size\n")
        return true
    end,

    -- Step 8: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
