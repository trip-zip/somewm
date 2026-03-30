---------------------------------------------------------------------------
--- Test: vertical carousel layout positions clients in a vertical strip
--
-- Verifies that awful.layout.suit.carousel.vertical:
-- 1. Positions clients sequentially in a vertical strip
-- 2. Clients scroll along the y-axis (not x-axis)
-- 3. Focused client is within the viewport vertically
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
local vertical = carousel.vertical
carousel.scroll_duration = 0

local tag
local c1, c2, c3
local signal_count = 0

local steps = {
    -- Step 1: Set up vertical carousel layout on tag
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = vertical
        io.stderr:write("[TEST] Set carousel.vertical layout\n")
        return true
    end,

    -- Step 2: Spawn first client
    function(count)
        if count == 1 then
            test_client("vcarousel_a")
        end
        c1 = utils.find_client_by_class("vcarousel_a")
        if c1 then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
    end,

    -- Step 3: Spawn second client
    function(count)
        if count == 1 then
            test_client("vcarousel_b")
        end
        c2 = utils.find_client_by_class("vcarousel_b")
        if c2 then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
    end,

    -- Step 4: Spawn third client
    function(count)
        if count == 1 then
            test_client("vcarousel_c")
        end
        c3 = utils.find_client_by_class("vcarousel_c")
        if c3 then
            io.stderr:write("[TEST] Client C spawned\n")
            return true
        end
    end,

    -- Step 5: Let arrange settle, then verify vertical positions
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        io.stderr:write(string.format("[TEST] %d clients, workarea=%dx%d at %d,%d\n",
            #client.get(), wa.width, wa.height, wa.x, wa.y))

        local focus = client.focus
        if not focus then
            io.stderr:write("[TEST] No focused client, waiting...\n")
            return nil
        end

        local fg = focus:geometry()
        io.stderr:write(string.format("[TEST] Focused client %s at y=%d, height=%d\n",
            focus.class, fg.y, fg.height))

        -- Focused client should be within the workarea vertically
        assert(fg.y >= wa.y - 1 and fg.y < wa.y + wa.height,
            string.format("Focused client y=%d should be within workarea [%d, %d)",
                fg.y, wa.y, wa.y + wa.height))

        -- In vertical mode, clients should span the full width
        assert(fg.width > wa.width * 0.7,
            string.format("Client width %d should span most of workarea width %d",
                fg.width, wa.width))

        io.stderr:write("[TEST] PASS: focused client is within workarea vertically\n")
        return true
    end,

    -- Step 6: Focus c1 and verify vertical scroll
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] After focus c1: y=%d, height=%d\n",
            g1.y, g1.height))

        -- c1 should now be within viewport vertically
        assert(g1.y >= wa.y - 1 and g1.y < wa.y + wa.height,
            string.format("c1 y=%d should be within workarea after focus", g1.y))
        io.stderr:write("[TEST] PASS: c1 visible after focus\n")

        return true
    end,

    -- Step 7: Verify all clients span full workarea width (stack axis)
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        for _, c in ipairs(client.get()) do
            local g = c:geometry()
            -- In vertical mode, x should be near wa.x (stack axis = x)
            assert(g.x >= wa.x - 1 and g.x < wa.x + wa.width,
                string.format("Client %s x=%d should be within workarea x bounds",
                    c.class, g.x))
        end
        io.stderr:write("[TEST] PASS: all clients within x bounds\n")

        return true
    end,

    -- Step 8: Verify no signals fire when re-arranging
    function(count)
        if count == 1 then
            signal_count = 0
            for _, c in ipairs(client.get()) do
                c:connect_signal("property::geometry", function()
                    signal_count = signal_count + 1
                end)
            end
            awful.layout.arrange(screen.primary)
            return nil
        end

        io.stderr:write(string.format("[TEST] Signals after re-arrange: %d\n", signal_count))
        assert(signal_count == 0,
            string.format("Expected 0 geometry signals during carousel arrange, got %d", signal_count))
        io.stderr:write("[TEST] PASS: no geometry signals during arrange\n")

        return true
    end,

    -- Step 9: Verify screen was not reassigned for any client
    function()
        for _, c in ipairs(client.get()) do
            assert(c.screen == screen.primary,
                string.format("Client %s on wrong screen: %s",
                    c.class, tostring(c.screen)))
        end
        io.stderr:write("[TEST] PASS: all clients on primary screen\n")
        return true
    end,

    -- Step 10: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
