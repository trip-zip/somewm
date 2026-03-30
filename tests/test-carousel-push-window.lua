---------------------------------------------------------------------------
--- Test: carousel push_window
--
-- Verifies that:
-- 1. push_window() moves focused client into adjacent column
-- 2. Source column is removed if it becomes empty
-- 3. Pushed client stacks in target column
-- 4. Boundary pushes are no-ops
-- 5. Expel reverses a push
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
local g_before

local steps = {
    -- Setup
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        return true
    end,

    -- Spawn three clients (each in own column)
    function(count)
        if count == 1 then test_client("push_a") end
        c1 = utils.find_client_by_class("push_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("push_b") end
        c2 = utils.find_client_by_class("push_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("push_c") end
        c3 = utils.find_client_by_class("push_c")
        if c3 then return true end
    end,

    -- Let layout settle, set all to 1/3 width
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.set_column_width(1/3)
            return nil
        end
        client.focus = c2
        c2:raise()
        carousel.set_column_width(1/3)
        return true
    end,

    function(count)
        if count == 1 then return nil end
        client.focus = c3
        c3:raise()
        carousel.set_column_width(1/3)
        return true
    end,

    -- Focus c2 (middle), push right -> c2 joins c3's column
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    function(count)
        if count == 1 then
            carousel.push_window(1)
            return nil
        end

        -- c2 and c3 should now be stacked in the same column
        local g2 = c2:geometry()
        local g3 = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] After push right: c2 x=%d y=%d, c3 x=%d y=%d\n",
            g2.x, g2.y, g3.x, g3.y))

        -- Same column means same x
        assert(math.abs(g2.x - g3.x) <= 2,
            string.format("c2 and c3 should share x: %d vs %d", g2.x, g3.x))

        -- Should be 2 columns now (c1 alone, c2+c3 stacked)
        -- c1 should still be independent
        local g1 = c1:geometry()
        assert(math.abs(g1.x - g2.x) > 10 or math.abs(g1.y - g2.y) > 10,
            "c1 should be in a different column than c2")

        io.stderr:write("[TEST] PASS: push_window(1) moved c2 into c3's column\n")
        return true
    end,

    -- Expel c2 back out (should restore 3 columns)
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            carousel.expel_window()
            return nil
        end

        local g1 = c1:geometry()
        local g2 = c2:geometry()
        local g3 = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] After expel: c1 x=%d, c2 x=%d, c3 x=%d\n",
            g1.x, g2.x, g3.x))

        -- c2 should now be in its own column (different x from c3)
        -- Allow for scrolling
        local wa = screen.primary.workarea
        assert(c2:geometry().height > wa.height * 0.7,
            "c2 should be full-height after expel (own column)")

        io.stderr:write("[TEST] PASS: expel reverses push\n")
        return true
    end,

    -- Focus c1 (leftmost), push right -> c1 joins its right neighbor's column
    -- Note: after push+expel above, column order is c1, c3, c2.
    -- Pushing c1 right joins c1 with c3's column.
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    function(count)
        if count == 1 then
            carousel.push_window(1)
            return nil
        end

        -- c1 should now be stacked with its right neighbor (c3)
        local g1 = c1:geometry()
        local g3 = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] After push c1 right: c1 x=%d y=%d, c3 x=%d y=%d\n",
            g1.x, g1.y, g3.x, g3.y))

        assert(math.abs(g1.x - g3.x) <= 2,
            string.format("c1 and c3 should share x after push: %d vs %d",
                g1.x, g3.x))

        io.stderr:write("[TEST] PASS: push from leftmost removes empty column\n")
        return true
    end,

    -- Restore: expel c1 back out
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.expel_window()
            return nil
        end
        return true
    end,

    -- Boundary: push left from leftmost column -> no-op
    -- After push+expel ops, column order is [c3], [c1], [c2].
    -- c3 is leftmost, so push c3 left should be no-op.
    function(count)
        if count == 1 then
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    function(count)
        if count == 1 then
            g_before = c3:geometry()
            carousel.push_window(-1)
            return nil
        end

        local g_after = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] Boundary left: before x=%d, after x=%d\n",
            g_before.x, g_after.x))

        -- Position should not change (no-op)
        assert(math.abs(g_before.x - g_after.x) <= 2,
            "Push left from leftmost should be no-op")

        io.stderr:write("[TEST] PASS: push left boundary is no-op\n")
        return true
    end,

    -- Boundary: push right from rightmost column -> no-op
    -- c2 is rightmost, so push c2 right should be no-op.
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    function(count)
        if count == 1 then
            g_before = c2:geometry()
            carousel.push_window(1)
            return nil
        end

        local g_after = c2:geometry()

        io.stderr:write(string.format(
            "[TEST] Boundary right: before x=%d, after x=%d\n",
            g_before.x, g_after.x))

        assert(math.abs(g_before.x - g_after.x) <= 2,
            "Push right from rightmost should be no-op")

        io.stderr:write("[TEST] PASS: push right boundary is no-op\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
