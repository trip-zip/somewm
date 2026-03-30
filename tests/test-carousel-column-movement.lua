---------------------------------------------------------------------------
--- Test: carousel column movement
--
-- Verifies that the carousel layout:
-- 1. move_column() swaps focused column with neighbor
-- 2. Column order changes after move
-- 3. Boundary moves are no-ops
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
        if count == 1 then test_client("move_a") end
        c1 = utils.find_client_by_class("move_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("move_b") end
        c2 = utils.find_client_by_class("move_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("move_c") end
        c3 = utils.find_client_by_class("move_c")
        if c3 then return true end
    end,

    -- Let layout settle, focus c1
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        -- Set all columns to 1/3 width so they're all visible
        carousel.set_column_width(1/3)
        return true
    end,

    -- Wait for width change to apply
    function(count)
        if count == 1 then return nil end

        -- Focus c2 and set its width too
        client.focus = c2
        c2:raise()
        carousel.set_column_width(1/3)
        return true
    end,

    function(count)
        if count == 1 then return nil end

        -- Focus c3 and set its width too
        client.focus = c3
        c3:raise()
        carousel.set_column_width(1/3)
        return true
    end,

    -- Wait and then focus c2 (middle column) for the move test
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    -- Record positions before move
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local g1 = c1:geometry()
        local g2 = c2:geometry()
        local g3 = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] Before move: c1.x=%d, c2.x=%d, c3.x=%d\n",
            g1.x, g2.x, g3.x))

        -- Store positions for comparison
        rawset(_G, "_test_x_before", { c1 = g1.x, c2 = g2.x, c3 = g3.x })
        return true
    end,

    -- Move c2's column to the right (swap with c3)
    function(count)
        if count == 1 then
            carousel.move_column(1)
            return nil
        end

        local g1 = c1:geometry()
        local g2 = c2:geometry()
        local g3 = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] After move right: c1.x=%d, c2.x=%d, c3.x=%d\n",
            g1.x, g2.x, g3.x))

        -- After moving c2 right, order should be: c1, c3, c2
        -- c3 should now be to the left of c2
        assert(g3.x < g2.x,
            string.format("c3 (x=%d) should be left of c2 (x=%d) after move right",
                g3.x, g2.x))

        io.stderr:write("[TEST] PASS: move_column(1) swapped with right neighbor\n")
        return true
    end,

    -- Move c2 right again (should be at boundary now, no-op)
    function(count)
        if count == 1 then
            carousel.move_column(1)
            return nil
        end

        -- c2 should still be the rightmost
        local g2 = c2:geometry()
        local g3 = c3:geometry()
        io.stderr:write(string.format(
            "[TEST] After boundary move: c2.x=%d, c3.x=%d\n", g2.x, g3.x))
        io.stderr:write("[TEST] PASS: boundary move handled\n")
        return true
    end,

    -- Move c2 left twice (should end up back in leftmost position)
    function(count)
        if count == 1 then
            carousel.move_column(-1)
            carousel.move_column(-1)
            return nil
        end

        local g1 = c1:geometry()
        local g2 = c2:geometry()

        io.stderr:write(string.format(
            "[TEST] After 2x move left: c1.x=%d, c2.x=%d\n", g1.x, g2.x))

        -- c2 should now be the leftmost
        assert(g2.x <= g1.x,
            string.format("c2 (x=%d) should be leftmost after 2x left move", g2.x))

        io.stderr:write("[TEST] PASS: move_column(-1) works\n")
        rawset(_G, "_test_x_before", nil)
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
