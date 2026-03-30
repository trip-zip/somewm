---------------------------------------------------------------------------
--- Test: carousel focus_first_column / focus_last_column
--
-- Verifies that:
-- 1. focus_first_column() focuses the first client in the first column
-- 2. focus_last_column() focuses the first client in the last column
-- 3. Viewport scrolls to show the focused column
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
    -- Setup
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        return true
    end,

    -- Spawn three clients (full-width, so they overflow)
    function(count)
        if count == 1 then test_client("efocus_a") end
        c1 = utils.find_client_by_class("efocus_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("efocus_b") end
        c2 = utils.find_client_by_class("efocus_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("efocus_c") end
        c3 = utils.find_client_by_class("efocus_c")
        if c3 then return true end
    end,

    -- Focus middle column
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,

    -- focus_first_column: should focus c1
    function(count)
        if count == 1 then
            carousel.focus_first_column()
            return nil
        end

        assert(client.focus == c1,
            string.format("Expected focus on c1 (%s), got %s",
                c1.class, client.focus and client.focus.class or "nil"))

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        io.stderr:write(string.format(
            "[TEST] focus_first: c1 x=%d, wa.x=%d\n", g1.x, wa.x))

        -- c1 should be visible (scrolled into view)
        assert(g1.x >= wa.x - 1 and g1.x < wa.x + wa.width,
            string.format("c1 should be visible after focus_first_column (x=%d)", g1.x))

        io.stderr:write("[TEST] PASS: focus_first_column() works\n")
        return true
    end,

    -- focus_last_column: should focus c3
    function(count)
        if count == 1 then
            carousel.focus_last_column()
            return nil
        end

        assert(client.focus == c3,
            string.format("Expected focus on c3 (%s), got %s",
                c3.class, client.focus and client.focus.class or "nil"))

        local wa = screen.primary.workarea
        local g3 = c3:geometry()
        io.stderr:write(string.format(
            "[TEST] focus_last: c3 x=%d, wa.x=%d, wa.w=%d\n",
            g3.x, wa.x, wa.width))

        -- c3 should be visible
        assert(g3.x >= wa.x - 1 and g3.x < wa.x + wa.width,
            string.format("c3 should be visible after focus_last_column (x=%d)", g3.x))

        io.stderr:write("[TEST] PASS: focus_last_column() works\n")
        return true
    end,

    -- Verify round-trip: first -> last -> first
    function(count)
        if count == 1 then
            carousel.focus_first_column()
            return nil
        end

        assert(client.focus == c1,
            "focus_first_column should return to c1 after focus_last_column")

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        assert(g1.x >= wa.x - 1 and g1.x < wa.x + wa.width,
            "c1 should be visible after round-trip")

        io.stderr:write("[TEST] PASS: round-trip focus_first -> focus_last -> focus_first\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
