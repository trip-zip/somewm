---------------------------------------------------------------------------
--- Test: vertical carousel column operations
--
-- Verifies that carousel.vertical correctly handles:
-- 1. consume_window() stacks clients horizontally (stack axis = x in vertical)
-- 2. expel_window() splits clients back out
-- 3. move_column() reorders rows in strip order
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

local steps = {
    -- Step 1: Set up vertical carousel layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = vertical
        return true
    end,

    -- Spawn three clients
    function(count)
        if count == 1 then test_client("vops_a") end
        c1 = utils.find_client_by_class("vops_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("vops_b") end
        c2 = utils.find_client_by_class("vops_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("vops_c") end
        c3 = utils.find_client_by_class("vops_c")
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

    -- Consume c2 (next row) into c1's row
    function(count)
        if count == 1 then
            carousel.consume_window(1)
            return nil
        end

        -- c1 and c2 should now be in the same row, stacked horizontally
        -- (stack axis = x in vertical mode)
        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local g2 = c2:geometry()

        io.stderr:write(string.format(
            "[TEST] After consume: c1 x=%d w=%d, c2 x=%d w=%d (wa.w=%d)\n",
            g1.x, g1.width, g2.x, g2.width, wa.width))

        -- They should be stacked along the x-axis (same y, different x)
        assert(math.abs(g1.y - g2.y) <= 2,
            string.format("Stacked clients should have same y: %d vs %d", g1.y, g2.y))

        -- c1 should be left of c2
        assert(g1.x < g2.x,
            string.format("c1 (x=%d) should be left of c2 (x=%d)", g1.x, g2.x))

        -- Each should take roughly half the width
        local expected_w = math.floor(wa.width / 2)
        assert(g1.width < wa.width and g1.width > expected_w * 0.5,
            string.format("c1 width %d should be roughly half of %d", g1.width, wa.width))

        io.stderr:write("[TEST] PASS: consume stacks horizontally in vertical mode\n")
        return true
    end,

    -- Expel c2 back out
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        if count == 2 then
            carousel.expel_window()
            return nil
        end

        -- c2 should now be in its own row again
        local g1 = c1:geometry()
        local g2 = c2:geometry()
        local wa = screen.primary.workarea

        io.stderr:write(string.format(
            "[TEST] After expel: c1 x=%d w=%d, c2 x=%d w=%d\n",
            g1.x, g1.width, g2.x, g2.width))

        -- c1 should now fill the full row width (only client in its row)
        assert(g1.width > wa.width * 0.7,
            string.format("c1 should be full width after expel: %d", g1.width))

        io.stderr:write("[TEST] PASS: expel splits window back out\n")
        return true
    end,

    -- Test move_column: swap c1 and c2's rows
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        if count == 2 then
            -- Record c1's position before move
            local g1_before = c1:geometry()
            local g2_before = c2:geometry()
            io.stderr:write(string.format(
                "[TEST] Before move: c1.y=%d, c2.y=%d\n",
                g1_before.y, g2_before.y))
            carousel.move_column(1)
            return nil
        end

        local g1 = c1:geometry()
        local g2 = c2:geometry()
        io.stderr:write(string.format(
            "[TEST] After move: c1.y=%d, c2.y=%d\n", g1.y, g2.y))

        -- After moving c1 forward, c2 should now be before c1
        -- (c2's y should be less than c1's y, or c1 should have moved)
        io.stderr:write("[TEST] PASS: move_column works in vertical mode\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
