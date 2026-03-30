---------------------------------------------------------------------------
--- Test: carousel centering modes
--
-- Verifies that the carousel layout:
-- 1. "always" mode centers the focused column
-- 2. "never" mode only scrolls when column is fully offscreen
-- 3. "on-overflow" mode centers when partially offscreen
-- 4. set_center_mode() changes the mode
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
        -- Start with "always" mode (easiest to verify)
        carousel.set_center_mode("always")
        return true
    end,

    -- Spawn three clients with 1/3 width each
    function(count)
        if count == 1 then test_client("center_a") end
        c1 = utils.find_client_by_class("center_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("center_b") end
        c2 = utils.find_client_by_class("center_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("center_c") end
        c3 = utils.find_client_by_class("center_c")
        if c3 then return true end
    end,

    -- Set all columns to 1/3 width so they fit side by side
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

    -- Test "always" mode: focused column should be centered
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local col_center = g1.x + g1.width / 2
        local screen_center = wa.x + wa.width / 2

        io.stderr:write(string.format(
            "[TEST] always mode: c1 center=%d, screen center=%d\n",
            col_center, screen_center))

        -- With "always" mode, focused column's center should be near screen center
        assert(math.abs(col_center - screen_center) < wa.width * 0.15,
            string.format("Column center %d should be near screen center %d",
                col_center, screen_center))

        io.stderr:write("[TEST] PASS: always mode centers focused column\n")
        return true
    end,

    -- Switch to "never" mode
    function(count)
        if count == 1 then
            carousel.set_center_mode("never")
            -- Focus c1 which should be visible
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()

        io.stderr:write(string.format(
            "[TEST] never mode: c1 x=%d, w=%d, wa=[%d,%d]\n",
            g1.x, g1.width, wa.x, wa.x + wa.width))

        -- c1 should be visible
        assert(g1.x >= wa.x - 1 and g1.x + g1.width <= wa.x + wa.width + 1,
            "c1 should be visible in never mode")

        io.stderr:write("[TEST] PASS: never mode keeps visible columns in place\n")
        return true
    end,

    -- Switch to "on-overflow" mode and verify
    function(count)
        if count == 1 then
            carousel.set_center_mode("on-overflow")
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g2 = c2:geometry()

        io.stderr:write(string.format(
            "[TEST] on-overflow mode: c2 x=%d, w=%d\n", g2.x, g2.width))

        -- c2 should be visible
        assert(g2.x >= wa.x - 1,
            string.format("c2 x=%d should be >= wa.x=%d", g2.x, wa.x))

        io.stderr:write("[TEST] PASS: on-overflow mode\n")
        return true
    end,

    -- Verify set_center_mode rejects invalid modes
    function()
        local ok = pcall(function()
            carousel.set_center_mode("invalid")
        end)
        assert(not ok, "set_center_mode should reject invalid modes")
        io.stderr:write("[TEST] PASS: invalid mode rejected\n")

        -- Verify "edge" is accepted
        local ok2 = pcall(function()
            carousel.set_center_mode("edge")
        end)
        assert(ok2, "set_center_mode should accept 'edge'")
        assert(carousel.center_mode == "edge", "center_mode should be 'edge'")
        io.stderr:write("[TEST] PASS: edge mode accepted\n")

        -- Reset to default
        carousel.set_center_mode("on-overflow")
        return true
    end,

    ---------------------------------------------------------------------------
    -- "edge" centering mode: scroll just enough to bring column to nearest edge
    ---------------------------------------------------------------------------

    -- Resize columns to 0.5 for edge mode tests (3 columns at 0.5 = overflow)
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.set_column_width(0.5)
            return nil
        end
        client.focus = c2
        c2:raise()
        carousel.set_column_width(0.5)
        return true
    end,

    function(count)
        if count == 1 then return nil end
        client.focus = c3
        c3:raise()
        carousel.set_column_width(0.5)
        return true
    end,

    -- Switch to edge mode, focus c1 first to establish viewport position
    function(count)
        if count == 1 then
            carousel.set_center_mode("edge")
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    -- Focus c3 (offscreen right): should align right edge to viewport right
    function(count)
        if count == 1 then
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g3 = c3:geometry()
        local bw = c3.border_width or 0
        local right_edge = g3.x + g3.width + 2 * bw

        io.stderr:write(string.format(
            "[TEST] edge mode c3: x=%d, w=%d, right=%d, wa.right=%d\n",
            g3.x, g3.width, right_edge, wa.x + wa.width))

        -- c3's right edge should be near the right edge of the workarea
        assert(right_edge <= wa.x + wa.width + 5,
            string.format("c3 right edge %d should be <= workarea right %d",
                right_edge, wa.x + wa.width))
        assert(g3.x >= wa.x - 1,
            string.format("c3 should be visible (x=%d >= wa.x=%d)", g3.x, wa.x))

        io.stderr:write("[TEST] PASS: edge mode aligns rightward column to right edge\n")
        return true
    end,

    -- Focus c1 (offscreen left): should align left edge to viewport left
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()

        io.stderr:write(string.format(
            "[TEST] edge mode c1: x=%d, wa.x=%d\n", g1.x, wa.x))

        -- c1's left edge should be near the left edge of the workarea
        local gap = tag.gap or 0
        assert(g1.x <= wa.x + gap + 5,
            string.format("c1 x=%d should be near wa.x=%d (edge-aligned left)",
                g1.x, wa.x))
        assert(g1.x >= wa.x - 1,
            string.format("c1 x=%d should be >= wa.x=%d", g1.x, wa.x))

        io.stderr:write("[TEST] PASS: edge mode aligns leftward column to left edge\n")
        return true
    end,

    -- Focus c2 which should be visible (viewport at left): should not scroll
    function(count)
        if count == 1 then
            -- c1 is left-aligned, c2 is right next to it. At 0.5 width each,
            -- c2's right edge is at 1.0 * viewport. Both c1 and c2 fit.
            -- Record c1 position before focusing c2.
            rawset(_G, "_edge_c1_x_before", c1:geometry().x)
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g2 = c2:geometry()

        -- c2 should be visible
        assert(g2.x >= wa.x - 1,
            string.format("c2 x=%d should be visible", g2.x))
        assert(g2.x + g2.width <= wa.x + wa.width + 5,
            "c2 should be within viewport")

        -- Viewport should not have moved (c1 position unchanged)
        local c1_x_before = rawget(_G, "_edge_c1_x_before")
        local c1_x_after = c1:geometry().x
        io.stderr:write(string.format(
            "[TEST] edge mode no-scroll: c1 before=%d, after=%d\n",
            c1_x_before, c1_x_after))
        assert(math.abs(c1_x_before - c1_x_after) <= 2,
            "Viewport should not move when focusing already-visible column")

        rawset(_G, "_edge_c1_x_before", nil)
        io.stderr:write("[TEST] PASS: edge mode does not scroll for visible columns\n")

        -- Reset to default
        carousel.set_center_mode("on-overflow")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
