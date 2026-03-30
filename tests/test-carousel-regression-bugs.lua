---------------------------------------------------------------------------
--- Test: carousel regression tests for fixed bugs
--
-- Regression tests for bugs reported in PR #351:
-- 1. Scroll offset breaks after column destruction/merge
-- 2. Default column width from beautiful not respected
-- 3. Client geometry uses screen instead of workarea
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local beautiful = require("beautiful")
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
    -- Setup
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        carousel.set_center_mode("on-overflow")
        return true
    end,

    ---------------------------------------------------------------------------
    -- Bug 1: Scroll offset follows focused column after column operations
    -- Uses consume/expel to trigger column destruction without killing clients.
    ---------------------------------------------------------------------------

    function(count)
        if count == 1 then test_client("regbug_a") end
        c1 = utils.find_client_by_class("regbug_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("regbug_b") end
        c2 = utils.find_client_by_class("regbug_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("regbug_c") end
        c3 = utils.find_client_by_class("regbug_c")
        if c3 then return true end
    end,

    -- Focus c2 (middle column), consume c1 to the left (column destroyed)
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
            -- Consume the left neighbor (c1) into c2's column
            carousel.consume_window(-1)
            return nil
        end

        -- c1 is now stacked in c2's column. c1's old column is destroyed.
        -- c2 should still be visible (viewport followed the focused column).
        local wa = screen.primary.workarea
        local g2 = c2:geometry()
        io.stderr:write(string.format(
            "[TEST] After consume (col destroyed): c2 x=%d, w=%d, wa=[%d, %d]\n",
            g2.x, g2.width, wa.x, wa.x + wa.width))

        assert(g2.x >= wa.x - 1,
            string.format("c2 x=%d should be >= wa.x=%d after column removal",
                g2.x, wa.x))
        assert(g2.x < wa.x + wa.width,
            string.format("c2 x=%d should be within workarea after column removal",
                g2.x))

        io.stderr:write("[TEST] PASS: scroll offset followed c2 after column destruction\n")
        return true
    end,

    -- Expel c1 back out (column created). c2 should still be visible.
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.expel_window()
            -- Re-focus c2
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g2 = c2:geometry()
        io.stderr:write(string.format(
            "[TEST] After expel (col created): c2 x=%d, w=%d\n",
            g2.x, g2.width))

        assert(g2.x >= wa.x - 1,
            string.format("c2 x=%d should be visible after expel", g2.x))
        assert(g2.x < wa.x + wa.width,
            "c2 should be within workarea after expel")

        io.stderr:write("[TEST] PASS: scroll offset stable after column creation\n")
        return true
    end,

    -- Cleanup bug 1 clients
    test_client.step_force_cleanup(),

    ---------------------------------------------------------------------------
    -- Bug 2: Default column width from beautiful
    ---------------------------------------------------------------------------

    function(count)
        if count == 1 then
            beautiful.carousel_default_column_width = 0.5
            test_client("regbug_width")
            return nil
        end

        local c = utils.find_client_by_class("regbug_width")
        if not c then return nil end

        -- Wait a tick for layout to settle
        if count < 3 then return nil end

        local wa = screen.primary.workarea
        local g = c:geometry()
        local bw = c.border_width or 0
        local gap = tag.gap or 0

        io.stderr:write(string.format(
            "[TEST] Default width: client w=%d, wa.w=%d, bw=%d, gap=%d\n",
            g.width, wa.width, bw, gap))

        -- Column is 0.5 of workarea. Client width = 0.5 * wa.width - 2*bw - 2*gap
        local expected_col = math.floor(0.5 * wa.width)
        local expected_client = expected_col - 2 * bw - 2 * gap
        assert(math.abs(g.width - expected_client) < 10,
            string.format("Client width %d should be ~%d (50%% of workarea)",
                g.width, expected_client))

        io.stderr:write("[TEST] PASS: beautiful.carousel_default_column_width respected\n")

        -- Reset
        beautiful.carousel_default_column_width = nil
        return true
    end,

    -- Cleanup bug 2
    test_client.step_force_cleanup(),

    ---------------------------------------------------------------------------
    -- Bug 3: Workarea vs screen geometry
    ---------------------------------------------------------------------------

    function(count)
        if count == 1 then
            test_client("regbug_wa")
            return nil
        end

        local c = utils.find_client_by_class("regbug_wa")
        if not c then return nil end

        if count < 3 then return nil end

        local wa = screen.primary.workarea
        local g = c:geometry()
        local bw = c.border_width or 0

        io.stderr:write(string.format(
            "[TEST] Workarea check: client geo=[%d,%d %dx%d], wa=[%d,%d %dx%d]\n",
            g.x, g.y, g.width, g.height, wa.x, wa.y, wa.width, wa.height))

        -- Client must be within workarea bounds (not screen.geometry)
        assert(g.x >= wa.x - 1,
            string.format("Client x=%d should be >= workarea x=%d", g.x, wa.x))
        assert(g.x + g.width + 2 * bw <= wa.x + wa.width + 1,
            string.format("Client right edge %d should be <= workarea right %d",
                g.x + g.width + 2 * bw, wa.x + wa.width))
        assert(g.y >= wa.y - 1,
            string.format("Client y=%d should be >= workarea y=%d", g.y, wa.y))
        assert(g.y + g.height + 2 * bw <= wa.y + wa.height + 1,
            string.format("Client bottom edge %d should be <= workarea bottom %d",
                g.y + g.height + 2 * bw, wa.y + wa.height))

        io.stderr:write("[TEST] PASS: client geometry uses workarea, not screen geometry\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
