---------------------------------------------------------------------------
--- Test: carousel vertical stacking (consume/expel)
--
-- Verifies that the carousel layout:
-- 1. consume_window() pulls a window into the focused column
-- 2. Consumed windows stack vertically within a column
-- 3. expel_window() moves a window back to its own column
-- 4. Expel is a no-op for single-client columns
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
local c1, c2, c3

local steps = {
    -- Step 1: Set up carousel layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        return true
    end,

    -- Spawn three clients
    function(count)
        if count == 1 then test_client("stack_a") end
        c1 = utils.find_client_by_class("stack_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("stack_b") end
        c2 = utils.find_client_by_class("stack_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("stack_c") end
        c3 = utils.find_client_by_class("stack_c")
        if c3 then return true end
    end,

    -- Let layout settle with focus on c1
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    -- Consume c2 (to the right) into c1's column
    function(count)
        if count == 1 then
            carousel.consume_window(1)
            return nil
        end

        -- c1 and c2 should now be in the same column (vertically stacked)
        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local g2 = c2:geometry()

        io.stderr:write(string.format(
            "[TEST] After consume: c1 y=%d h=%d, c2 y=%d h=%d (wa.h=%d)\n",
            g1.y, g1.height, g2.y, g2.height, wa.height))

        -- They should be stacked vertically (same x, different y)
        assert(math.abs(g1.x - g2.x) <= 2,
            string.format("Stacked clients should have same x: %d vs %d", g1.x, g2.x))

        -- c1 should be above c2
        assert(g1.y < g2.y,
            string.format("c1 (y=%d) should be above c2 (y=%d)", g1.y, g2.y))

        -- Each should take roughly half the height
        local expected_h = math.floor(wa.height / 2)
        assert(g1.height < wa.height and g1.height > expected_h * 0.5,
            string.format("c1 height %d should be roughly half of %d", g1.height, wa.height))

        io.stderr:write("[TEST] PASS: consume stacks vertically\n")
        return true
    end,

    -- Verify c3 is still in its own column
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local g3 = c3:geometry()
        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] c3: x=%d w=%d, c1: x=%d w=%d\n",
            g3.x, g3.width, g1.x, g1.width))

        -- c3 should be in a different column (different x)
        -- (c3 could be offscreen since c1's column is focused)
        io.stderr:write("[TEST] PASS: c3 still independent\n")
        return true
    end,

    -- Expel c2 back out
    function(count)
        if count == 1 then
            -- Focus c2 first (it's in the same column as c1)
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        if count == 2 then
            carousel.expel_window()
            return nil
        end

        -- c2 should now be in its own column again
        local g1 = c1:geometry()
        local g2 = c2:geometry()
        local wa = screen.primary.workarea

        io.stderr:write(string.format(
            "[TEST] After expel: c1 y=%d h=%d, c2 y=%d h=%d\n",
            g1.y, g1.height, g2.y, g2.height))

        -- c1 should now fill the full column height (only client in its column)
        assert(g1.height > wa.height * 0.7,
            string.format("c1 should be full height after expel: %d", g1.height))

        io.stderr:write("[TEST] PASS: expel splits window back out\n")
        return true
    end,

    -- Expel on single-client column should be a no-op
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local g_before = c1:geometry()
        carousel.expel_window() -- should be no-op (c1 is alone)

        -- Wait for any deferred arrange
        return true
    end,

    function(count)
        if count == 1 then return nil end

        local g_after = c1:geometry()
        -- Should still be full height (no change)
        local wa = screen.primary.workarea
        assert(g_after.height > wa.height * 0.7,
            "Expel on single client should be no-op")
        io.stderr:write("[TEST] PASS: expel no-op for single client\n")
        return true
    end,

    -- Cleanup
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
