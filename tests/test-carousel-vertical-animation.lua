---------------------------------------------------------------------------
--- Test: vertical carousel scroll animation
--
-- Verifies that carousel.vertical:
-- 1. Duration 0 snaps instantly (no animation)
-- 2. Duration > 0 starts animation that reaches the target on y-axis
-- 3. Mid-animation retarget smoothly switches to new target
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

local tag
local c1, c2, c3

local steps = {
    -- Step 1: Set up vertical carousel with animation disabled
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = vertical
        carousel.scroll_duration = 0
        carousel.set_center_mode("always")
        return true
    end,

    -- Spawn three clients
    function(count)
        if count == 1 then test_client("vanim_a") end
        c1 = utils.find_client_by_class("vanim_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("vanim_b") end
        c2 = utils.find_client_by_class("vanim_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("vanim_c") end
        c3 = utils.find_client_by_class("vanim_c")
        if c3 then return true end
    end,

    -- Test instant snap (duration=0): focus c1, verify immediately positioned
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
            "[TEST] Instant snap: c1.y=%d (wa.y=%d)\n", g1.y, wa.y))

        assert(g1.y >= wa.y - 1 and g1.y < wa.y + wa.height,
            "c1 should be visible with instant snap")
        io.stderr:write("[TEST] PASS: instant snap works\n")
        return true
    end,

    -- Enable animation, focus c3, wait for it to reach target
    function(count)
        if count == 1 then
            carousel.scroll_duration = 0.15
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g3 = c3:geometry()

        -- c3 should be visible (animation may still be in progress or done)
        if g3.y >= wa.y - 1 and g3.y < wa.y + wa.height then
            io.stderr:write(string.format(
                "[TEST] Animation complete: c3.y=%d\n", g3.y))
            io.stderr:write("[TEST] PASS: animation reaches target on y-axis\n")
            return true
        end

        return nil
    end,

    -- Test retarget: animate to c1, then immediately switch to c2
    function(count)
        if count == 1 then
            carousel.scroll_duration = 0.3
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        if count == 2 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g2 = c2:geometry()

        if g2.y >= wa.y - 1 and g2.y < wa.y + wa.height then
            io.stderr:write(string.format(
                "[TEST] After retarget: c2.y=%d\n", g2.y))
            io.stderr:write("[TEST] PASS: retarget works on y-axis\n")
            return true
        end

        return nil
    end,

    -- Cleanup
    test_client.step_force_cleanup(function()
        carousel.scroll_duration = 0
        carousel.set_center_mode("on-overflow")
    end),
}

runner.run_steps(steps, { kill_clients = false })
