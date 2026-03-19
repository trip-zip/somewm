---------------------------------------------------------------------------
--- Test: carousel variable column widths
--
-- Verifies that the carousel layout:
-- 1. Supports different width fractions per column
-- 2. cycle_column_width() cycles through presets
-- 3. adjust_column_width() adjusts by delta
-- 4. set_column_width() sets exact fraction
-- 5. maximize_column() sets to 1.0
-- 6. Columns can have independent widths
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local carousel = awful.layout.suit.carousel

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

carousel.scroll_duration = 0

local tag
local c1, c2

local steps = {
    -- Step 1: Set up carousel layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        return true
    end,

    -- Step 2-3: Spawn two clients
    function(count)
        if count == 1 then test_client("width_a") end
        c1 = utils.find_client_by_class("width_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("width_b") end
        c2 = utils.find_client_by_class("width_b")
        if c2 then return true end
    end,

    -- Step 4: Focus c1 and let layout settle
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    -- Step 5: Cycle column width (deferred arrange)
    function(count)
        if count == 1 then
            carousel.cycle_column_width()
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] c1 after cycle: w=%d (wa=%d)\n", g1.width, wa.width))

        -- Default 1.0 -> cycles to 1/3 (first preset after wrapping)
        local expected = math.floor(wa.width / 3)
        assert(math.abs(g1.width - expected) < wa.width * 0.1,
            string.format("Expected width ~%d (1/3), got %d", expected, g1.width))
        io.stderr:write("[TEST] PASS: cycle to 1/3\n")
        return true
    end,

    -- Step 6: Cycle again to 1/2
    function(count)
        if count == 1 then
            carousel.cycle_column_width()
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local expected = math.floor(wa.width / 2)
        io.stderr:write(string.format("[TEST] c1 after second cycle: w=%d (expected ~%d)\n",
            g1.width, expected))

        assert(math.abs(g1.width - expected) < wa.width * 0.1,
            string.format("Expected width ~%d (1/2), got %d", expected, g1.width))
        io.stderr:write("[TEST] PASS: cycle to 1/2\n")
        return true
    end,

    -- Step 7: Verify c2 width unaffected (still 1.0)
    function()
        local wa = screen.primary.workarea
        local g2 = c2:geometry()
        io.stderr:write(string.format("[TEST] c2 width: %d (wa=%d)\n", g2.width, wa.width))
        assert(g2.width > wa.width * 0.8,
            string.format("c2 should be full width, got %d", g2.width))
        io.stderr:write("[TEST] PASS: c2 unaffected\n")
        return true
    end,

    -- Step 8: set_column_width(0.75)
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.set_column_width(0.75)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local expected = math.floor(wa.width * 0.75)
        io.stderr:write(string.format("[TEST] c1 set 0.75: w=%d (expected ~%d)\n",
            g1.width, expected))

        assert(math.abs(g1.width - expected) < wa.width * 0.1,
            string.format("Expected ~%d, got %d", expected, g1.width))
        io.stderr:write("[TEST] PASS: set_column_width\n")
        return true
    end,

    -- Step 9: maximize_column()
    function(count)
        if count == 1 then
            carousel.maximize_column()
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] c1 after maximize: w=%d (wa=%d)\n",
            g1.width, wa.width))
        assert(g1.width > wa.width * 0.8,
            string.format("Expected full width, got %d", g1.width))
        io.stderr:write("[TEST] PASS: maximize_column\n")
        return true
    end,

    -- Step 10: adjust_column_width (set to 0.5, then adjust by -0.1)
    function(count)
        if count == 1 then
            carousel.set_column_width(0.5)
            -- set_column_width triggers deferred arrange, adjust will also trigger one.
            -- Both modify the state synchronously though.
            carousel.adjust_column_width(-0.1)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local expected = math.floor(wa.width * 0.4)
        io.stderr:write(string.format("[TEST] c1 adjust -0.1 from 0.5: w=%d (expected ~%d)\n",
            g1.width, expected))

        assert(math.abs(g1.width - expected) < wa.width * 0.1,
            string.format("Expected ~%d, got %d", expected, g1.width))
        io.stderr:write("[TEST] PASS: adjust_column_width\n")
        return true
    end,

    -- Step 11: Cleanup
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
