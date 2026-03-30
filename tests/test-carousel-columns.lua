---------------------------------------------------------------------------
--- Test: carousel column reconciliation
--
-- Verifies that the carousel layout:
-- 1. Creates columns for new clients
-- 2. Removes columns when clients close
-- 3. Maintains column state across arrange calls
-- 4. Keeps backward compatibility (one client = one full-width column)
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

local steps = {
    -- Step 1: Set up carousel layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        io.stderr:write("[TEST] Set carousel layout\n")
        return true
    end,

    -- Step 2: Spawn first client
    function(count)
        if count == 1 then test_client("col_a") end
        if utils.find_client_by_class("col_a") then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
    end,

    -- Step 3: Verify single client creates one column
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local c = utils.find_client_by_class("col_a")
        local wa = screen.primary.workarea
        local g = c:geometry()

        -- Single client should fill the workarea width (minus gaps/borders)
        io.stderr:write(string.format("[TEST] Single client: x=%d, w=%d, wa.w=%d\n",
            g.x, g.width, wa.width))
        assert(g.x >= wa.x - 1, "Single client should be at workarea x")
        assert(g.width > wa.width * 0.8,
            string.format("Single client width %d should be close to workarea %d", g.width, wa.width))
        io.stderr:write("[TEST] PASS: single client fills workarea\n")
        return true
    end,

    -- Step 4: Spawn two more clients
    function(count)
        if count == 1 then test_client("col_b") end
        if utils.find_client_by_class("col_b") then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
    end,

    function(count)
        if count == 1 then test_client("col_c") end
        if utils.find_client_by_class("col_c") then
            io.stderr:write("[TEST] Client C spawned\n")
            return true
        end
    end,

    -- Step 5: Verify three clients = three columns
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local clients = client.get()
        io.stderr:write(string.format("[TEST] %d clients present\n", #clients))
        assert(#clients >= 3, "Expected at least 3 clients")

        -- All clients should have the same width (all at width_fraction=1.0)
        local widths = {}
        for _, c in ipairs(clients) do
            local g = c:geometry()
            table.insert(widths, g.width)
            io.stderr:write(string.format("[TEST] Client %s: x=%d, w=%d\n",
                c.class, g.x, g.width))
        end

        -- All widths should be equal (same fraction)
        for i = 2, #widths do
            assert(math.abs(widths[i] - widths[1]) <= 2,
                string.format("Width mismatch: %d vs %d", widths[1], widths[i]))
        end
        io.stderr:write("[TEST] PASS: all columns have equal width\n")
        return true
    end,

    -- Step 6: Close one client and wait for it to disappear
    function(count)
        if count == 1 then
            local c = utils.find_client_by_class("col_b")
            if c then
                -- Kill via pid for reliability (terminals running sleep infinity)
                local pid = c.pid
                if pid then
                    os.execute("kill -9 " .. pid .. " 2>/dev/null")
                end
                c:kill()
            end
            return nil
        end
        -- Wait for client to be gone
        if utils.find_client_by_class("col_b") then return nil end
        io.stderr:write("[TEST] col_b removed\n")
        return true
    end,

    -- Step 7: Verify two clients remain with correct layout
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local remaining = {}
        for _, c in ipairs(client.get()) do
            if c.class == "col_a" or c.class == "col_c" then
                table.insert(remaining, c)
            end
        end

        io.stderr:write(string.format("[TEST] Remaining clients: %d\n", #remaining))
        assert(#remaining == 2, "Expected 2 remaining clients, got " .. #remaining)

        -- Focused client should be within workarea
        local focus = client.focus
        if focus then
            local wa = screen.primary.workarea
            local fg = focus:geometry()
            assert(fg.x >= wa.x - 1 and fg.x < wa.x + wa.width,
                "Focused client should be visible after column removal")
        end
        io.stderr:write("[TEST] PASS: column removed after client close\n")
        return true
    end,

    -- Step 8: Verify no geometry signals during arrange
    function(count)
        if count == 1 then
            local signal_count = 0
            for _, c in ipairs(client.get()) do
                c:connect_signal("property::geometry", function()
                    signal_count = signal_count + 1
                end)
            end
            awful.layout.arrange(screen.primary)
            -- Store for next tick
            rawset(_G, "_test_signal_count", signal_count)
            return nil
        end

        local sc = rawget(_G, "_test_signal_count") or 0
        io.stderr:write(string.format("[TEST] Geometry signals: %d\n", sc))
        assert(sc == 0, "Expected 0 geometry signals, got " .. sc)
        io.stderr:write("[TEST] PASS: no geometry signals during arrange\n")
        rawset(_G, "_test_signal_count", nil)
        return true
    end,

    -- Step 9: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
