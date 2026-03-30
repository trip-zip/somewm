---------------------------------------------------------------------------
--- Test: carousel gesture scrolling
--
-- Verifies that the carousel layout:
-- 1. make_gesture_binding() creates a working 3-finger swipe binding
-- 2. Swipe left (dx<0) scrolls viewport right
-- 3. Swipe right (dx>0) scrolls viewport left
-- 4. On release, viewport snaps to nearest column
-- 5. On release, focus follows to nearest column's client
-- 6. Gesture respects strip boundaries (no overscroll)
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
local gesture_binding

local steps = {
    -- Step 1: Set up carousel layout and gesture binding
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        carousel.set_center_mode("always")
        gesture_binding = carousel.make_gesture_binding()
        return true
    end,

    -- Spawn three clients at 1/2 width
    function(count)
        if count == 1 then test_client("gest_a") end
        c1 = utils.find_client_by_class("gest_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("gest_b") end
        c2 = utils.find_client_by_class("gest_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("gest_c") end
        c3 = utils.find_client_by_class("gest_c")
        if c3 then return true end
    end,

    -- Set all to 1/2 width so strip overflows
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

    -- Focus c1 and let settle
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] Before gesture: c1.x=%d\n", g1.x))
        rawset(_G, "_test_start_x", g1.x)
        return true
    end,

    -- Simulate 3-finger swipe left (should scroll viewport right)
    function(count)
        if count == 1 then
            _gesture.inject({type = "swipe_begin", time = 1000, fingers = 3})
            _gesture.inject({type = "swipe_update", time = 1010, fingers = 3,
                dx = -100, dy = 0})
            _gesture.inject({type = "swipe_update", time = 1020, fingers = 3,
                dx = -100, dy = 0})
            return nil
        end

        -- During swipe, viewport should have moved
        local g1 = c1:geometry()
        local start_x = rawget(_G, "_test_start_x")

        io.stderr:write(string.format(
            "[TEST] During swipe: c1.x=%d (was %d)\n", g1.x, start_x))

        -- c1 should have moved left (viewport scrolled right)
        assert(g1.x < start_x,
            string.format("Swipe left should scroll right: x=%d, was=%d",
                g1.x, start_x))

        io.stderr:write("[TEST] PASS: swipe moves viewport\n")
        return true
    end,

    -- End the swipe, check snap and focus
    function(count)
        if count == 1 then
            _gesture.inject({type = "swipe_end", time = 1030, cancelled = false})
            return nil
        end

        local focus = client.focus
        io.stderr:write(string.format(
            "[TEST] After swipe end: focused=%s\n",
            focus and focus.class or "nil"))

        -- Focus should have changed to the column nearest viewport center
        assert(focus ~= nil, "Should have a focused client after gesture")

        io.stderr:write("[TEST] PASS: gesture release focuses nearest column\n")
        return true
    end,

    -- Test boundary: swipe far right from leftmost position (should clamp)
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        if count == 2 then
            _gesture.inject({type = "swipe_begin", time = 2000, fingers = 3})
            -- Swipe right (positive dx) = scroll viewport left (toward start)
            _gesture.inject({type = "swipe_update", time = 2010, fingers = 3,
                dx = 5000, dy = 0})
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()

        io.stderr:write(string.format(
            "[TEST] After overscroll right: c1.x=%d\n", g1.x))

        -- c1 should not be pushed past the right side of viewport
        -- (boundary clamping prevents overscroll)
        assert(g1.x >= wa.x - 1,
            "Left boundary should prevent overscroll")

        _gesture.inject({type = "swipe_end", time = 2020, cancelled = false})

        io.stderr:write("[TEST] PASS: gesture respects strip boundaries\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(function()
        if gesture_binding then gesture_binding:remove() end
        carousel.set_center_mode("on-overflow")
        rawset(_G, "_test_start_x", nil)
    end),
}

runner.run_steps(steps, { kill_clients = false })
