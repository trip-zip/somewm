---------------------------------------------------------------------------
--- Test: carousel push_window (consume-or-expel)
--
-- Verifies that:
-- 1. Solo window: push consumes into adjacent column (merge)
-- 2. Solo window: boundary pushes are no-ops
-- 3. Multi-window column: push expels into new column in given direction
-- 4. Expel reverses a consume
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

    ---------------------------------------------------------------------------
    -- Solo consume: focus c2 (middle), push right -> c2 joins c3's column
    ---------------------------------------------------------------------------
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
        local g1 = c1:geometry()
        assert(math.abs(g1.x - g2.x) > 10 or math.abs(g1.y - g2.y) > 10,
            "c1 should be in a different column than c2")

        io.stderr:write("[TEST] PASS: solo push_window(1) consumed c2 into c3's column\n")
        return true
    end,

    ---------------------------------------------------------------------------
    -- Multi-window expel: c2 is stacked with c3, push c2 right -> expels c2
    -- State: [c1], [c3+c2]. Focus c2, push right -> [c1], [c3], [c2]
    ---------------------------------------------------------------------------
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

        local wa = screen.primary.workarea

        -- c2 should be in its own column (full height)
        assert(c2:geometry().height > wa.height * 0.7,
            "c2 should be full-height after expel (own column)")

        -- c3 should also be in its own column (full height)
        assert(c3:geometry().height > wa.height * 0.7,
            "c3 should be full-height after expel")

        -- c2 should be to the right of c3 (expel right)
        assert(c2:geometry().x > c3:geometry().x,
            string.format("c2 should be right of c3: c2.x=%d c3.x=%d",
                c2:geometry().x, c3:geometry().x))

        io.stderr:write("[TEST] PASS: multi-window push_window(1) expelled c2 into new column\n")
        return true
    end,

    ---------------------------------------------------------------------------
    -- Consume c2 back into c1's column, then expel left
    -- State: [c1], [c3], [c2]. Consume c2 into c3: [c1], [c3+c2].
    -- Focus c2, push left -> expels c2 before c3: [c1], [c2], [c3]
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            -- Solo c2: push left consumes into c3's column
            carousel.push_window(-1)
            return nil
        end
        -- Verify c2 and c3 are stacked
        assert(math.abs(c2:geometry().x - c3:geometry().x) <= 2,
            "c2 and c3 should share x after consume")
        return true
    end,

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
            carousel.push_window(-1)
            return nil
        end

        local wa = screen.primary.workarea

        -- c2 should be in its own column (full height)
        assert(c2:geometry().height > wa.height * 0.7,
            "c2 should be full-height after expel left")

        -- c2 should be to the left of c3 (expel left)
        assert(c2:geometry().x < c3:geometry().x,
            string.format("c2 should be left of c3: c2.x=%d c3.x=%d",
                c2:geometry().x, c3:geometry().x))

        io.stderr:write("[TEST] PASS: multi-window push_window(-1) expelled c2 left\n")
        return true
    end,

    ---------------------------------------------------------------------------
    -- Multi-window expel at boundary: consume c2 into c3 (rightmost),
    -- then push c2 right (expels at right edge).
    -- State: [c1], [c2], [c3]. Consume c2 into c3: [c1], [c3+c2].
    -- Focus c2, push right -> expels at right: [c1], [c3], [c2]
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            -- Solo c2: push right consumes into c3's column
            carousel.push_window(1)
            return nil
        end
        assert(math.abs(c2:geometry().x - c3:geometry().x) <= 2,
            "c2 and c3 should share x after consume")
        return true
    end,

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

        local wa = screen.primary.workarea

        -- c2 should be in its own column at the right edge
        assert(c2:geometry().height > wa.height * 0.7,
            "c2 should be full-height after boundary expel")

        -- c2 should be rightmost
        assert(c2:geometry().x >= c3:geometry().x,
            string.format("c2 should be right of c3: c2.x=%d c3.x=%d",
                c2:geometry().x, c3:geometry().x))

        io.stderr:write("[TEST] PASS: multi-window boundary expel works at right edge\n")
        return true
    end,

    ---------------------------------------------------------------------------
    -- Solo boundary: restore to 3 columns, push leftmost left -> no-op
    ---------------------------------------------------------------------------
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
            g_before = c1:geometry()
            carousel.push_window(-1)
            return nil
        end

        local g_after = c1:geometry()

        io.stderr:write(string.format(
            "[TEST] Boundary left: before x=%d, after x=%d\n",
            g_before.x, g_after.x))

        assert(math.abs(g_before.x - g_after.x) <= 2,
            "Push left from leftmost should be no-op")

        io.stderr:write("[TEST] PASS: solo push left boundary is no-op\n")
        return true
    end,

    -- Solo boundary: push rightmost right -> no-op
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

        io.stderr:write("[TEST] PASS: solo push right boundary is no-op\n")
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
