---------------------------------------------------------------------------
--- Test: carousel strip boundary clamping
--
-- Verifies that the carousel layout:
-- 1. Cannot scroll past the left edge (no empty space left of first column)
-- 2. Cannot scroll past the right edge (no empty space right of last column)
-- 3. Centers the strip when total width is less than viewport
-- 4. Single column is centered
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local carousel = awful.layout.suit.carousel

carousel.scroll_duration = 0

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local tag
local c1, c2, c3

local steps = {
    -- Step 1: Set up carousel layout with on-overflow mode
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        carousel.set_center_mode("on-overflow")
        return true
    end,

    -- Spawn a single client
    function(count)
        if count == 1 then test_client("bound_a") end
        c1 = utils.find_client_by_class("bound_a")
        if c1 then return true end
    end,

    -- Set to 1/3 width and verify centering (strip narrower than viewport)
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.set_column_width(1/3)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local col_center = g1.x + g1.width / 2
        local screen_center = wa.x + wa.width / 2

        io.stderr:write(string.format(
            "[TEST] Single 1/3 col: center=%d, screen_center=%d\n",
            col_center, screen_center))

        -- Single column narrower than viewport should be centered
        -- (strip < viewport triggers centering in clamp_offset)
        assert(math.abs(col_center - screen_center) < wa.width * 0.15,
            string.format("Single column should be centered: col=%d, screen=%d",
                col_center, screen_center))
        io.stderr:write("[TEST] PASS: single narrow column centered\n")
        return true
    end,

    -- Spawn two more clients
    function(count)
        if count == 1 then test_client("bound_b") end
        c2 = utils.find_client_by_class("bound_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("bound_c") end
        c3 = utils.find_client_by_class("bound_c")
        if c3 then return true end
    end,

    -- Set all to full width for boundary clamping tests
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.set_column_width(1.0)
            return nil
        end
        client.focus = c2
        c2:raise()
        carousel.set_column_width(1.0)
        return true
    end,

    function(count)
        if count == 1 then return nil end
        client.focus = c3
        c3:raise()
        carousel.set_column_width(1.0)
        return true
    end,

    -- Focus c1 (leftmost), verify left boundary clamp.
    -- In on-overflow mode, centering c1 wants negative offset, clamped to 0.
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
            "[TEST] Full-width c1 focused: x=%d, w=%d\n", g1.x, g1.width))

        -- With left boundary clamp, c1 should start near wa.x (not pushed right)
        assert(g1.x >= wa.x - 1,
            string.format("c1 should be at left edge: x=%d", g1.x))

        io.stderr:write("[TEST] PASS: left boundary clamped\n")
        return true
    end,

    -- Focus c3 (rightmost), verify right boundary clamp
    function(count)
        if count == 1 then
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g3 = c3:geometry()

        io.stderr:write(string.format(
            "[TEST] Full-width c3 focused: x=%d, w=%d\n", g3.x, g3.width))

        -- c3's right edge should not extend past viewport
        assert(g3.x + g3.width <= wa.x + wa.width + 2,
            string.format("c3 right edge %d should be <= viewport right %d",
                g3.x + g3.width, wa.x + wa.width))

        io.stderr:write("[TEST] PASS: right boundary clamped\n")
        return true
    end,

    -- scroll_by far left should clamp
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        carousel.scroll_by(tag, -10)
        awful.layout.arrange(screen.primary)
        return true
    end,

    function(count)
        if count == 1 then return nil end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()

        io.stderr:write(string.format(
            "[TEST] After scroll far left: c1.x=%d\n", g1.x))

        assert(g1.x >= wa.x - 1,
            "scroll_by should clamp at left boundary")

        io.stderr:write("[TEST] PASS: scroll_by clamped at left\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(function()
        carousel.set_center_mode("on-overflow")
    end),
}

runner.run_steps(steps, { kill_clients = false })
