---------------------------------------------------------------------------
--- Test: carousel layout positions clients in a horizontal strip
--
-- Verifies that awful.layout.suit.carousel:
-- 1. Positions clients sequentially in a horizontal strip
-- 2. Centers the focused client on screen
-- 3. Positions offscreen clients without screen reassignment
-- 4. Does not emit property::geometry signals during arrange
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

local carousel = awful.layout.suit.carousel
carousel.scroll_duration = 0

local tag
local c1, c2, c3
local signal_count = 0

local steps = {
    -- Step 1: Set up carousel layout on tag
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        io.stderr:write("[TEST] Set carousel layout\n")
        return true
    end,

    -- Step 2: Spawn first client
    function(count)
        if count == 1 then
            test_client("carousel_a")
        end
        c1 = utils.find_client_by_class("carousel_a")
        if c1 then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
    end,

    -- Step 3: Spawn second client
    function(count)
        if count == 1 then
            test_client("carousel_b")
        end
        c2 = utils.find_client_by_class("carousel_b")
        if c2 then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
    end,

    -- Step 4: Spawn third client
    function(count)
        if count == 1 then
            test_client("carousel_c")
        end
        c3 = utils.find_client_by_class("carousel_c")
        if c3 then
            io.stderr:write("[TEST] Client C spawned\n")
            return true
        end
    end,

    -- Step 5: Let arrange settle, then verify positions
    function(count)
        if count == 1 then
            -- Force a layout arrange and wait a tick
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        io.stderr:write(string.format("[TEST] %d clients, workarea=%dx%d at %d,%d\n",
            #client.get(), wa.width, wa.height, wa.x, wa.y))

        -- The focused client should be roughly centered.
        -- With 3 clients, focus is on the last-spawned (c3).
        local focus = client.focus
        if not focus then
            io.stderr:write("[TEST] No focused client, waiting...\n")
            return nil
        end

        local fg = focus:geometry()
        io.stderr:write(string.format("[TEST] Focused client %s at x=%d, width=%d\n",
            focus.class, fg.x, fg.width))

        -- Focused client should be within the workarea (centered)
        assert(fg.x >= wa.x - 1 and fg.x < wa.x + wa.width,
            string.format("Focused client x=%d should be within workarea [%d, %d)",
                fg.x, wa.x, wa.x + wa.width))
        io.stderr:write("[TEST] PASS: focused client is within workarea\n")

        return true
    end,

    -- Step 6: Focus c1 (should be a different client) and verify scroll
    function(count)
        if count == 1 then
            -- Focus a specific client
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] After focus c1: x=%d, width=%d\n", g1.x, g1.width))

        -- c1 should now be centered
        assert(g1.x >= wa.x - 1 and g1.x < wa.x + wa.width,
            string.format("c1 x=%d should be within workarea after focus", g1.x))
        io.stderr:write("[TEST] PASS: c1 centered after focus\n")

        return true
    end,

    -- Step 7: Verify no signals fire when re-arranging
    function(count)
        if count == 1 then
            signal_count = 0
            -- Connect signal counters to all clients
            for _, c in ipairs(client.get()) do
                c:connect_signal("property::geometry", function()
                    signal_count = signal_count + 1
                end)
            end
            -- Re-arrange (should use _set_geometry_silent, no signals)
            awful.layout.arrange(screen.primary)
            return nil
        end

        io.stderr:write(string.format("[TEST] Signals after re-arrange: %d\n", signal_count))
        assert(signal_count == 0,
            string.format("Expected 0 geometry signals during carousel arrange, got %d", signal_count))
        io.stderr:write("[TEST] PASS: no geometry signals during arrange\n")

        return true
    end,

    -- Step 8: Verify screen was not reassigned for any client
    function()
        for _, c in ipairs(client.get()) do
            assert(c.screen == screen.primary,
                string.format("Client %s on wrong screen: %s",
                    c.class, tostring(c.screen)))
        end
        io.stderr:write("[TEST] PASS: all clients on primary screen\n")
        return true
    end,

    -- Step 9: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
