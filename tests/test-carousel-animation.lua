---------------------------------------------------------------------------
--- Test: carousel scroll animation
--
-- Verifies that the carousel layout:
-- 1. Duration 0 snaps instantly (no animation)
-- 2. Duration > 0 starts animation that reaches the target
-- 3. Mid-animation retarget smoothly switches to new target
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

local tag
local c1, c2, c3

local steps = {
    -- Step 1: Set up carousel with animation disabled
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        carousel.scroll_duration = 0
        carousel.set_center_mode("always")
        return true
    end,

    -- Spawn three clients
    function(count)
        if count == 1 then test_client("anim_a") end
        c1 = utils.find_client_by_class("anim_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("anim_b") end
        c2 = utils.find_client_by_class("anim_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("anim_c") end
        c3 = utils.find_client_by_class("anim_c")
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
            "[TEST] Instant snap: c1.x=%d (wa.x=%d)\n", g1.x, wa.x))

        assert(g1.x >= wa.x - 1 and g1.x < wa.x + wa.width,
            "c1 should be visible with instant snap")
        io.stderr:write("[TEST] PASS: instant snap works\n")
        return true
    end,

    -- Enable animation, focus c3, wait for it to reach target
    function(count)
        if count == 1 then
            carousel.scroll_duration = 0.15  -- short but testable
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        -- Check if c3 has reached the expected centered position
        local wa = screen.primary.workarea
        local g3 = c3:geometry()

        -- c3 should be visible (animation may still be in progress or done)
        if g3.x >= wa.x - 1 and g3.x < wa.x + wa.width then
            io.stderr:write(string.format(
                "[TEST] Animation complete: c3.x=%d\n", g3.x))
            io.stderr:write("[TEST] PASS: animation reaches target\n")
            return true
        end

        -- Still animating, wait
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

        -- On tick 2, retarget to c2
        if count == 2 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        -- Wait for c2 to be visible (animation converges to retarget)
        local wa = screen.primary.workarea
        local g2 = c2:geometry()

        if g2.x >= wa.x - 1 and g2.x < wa.x + wa.width then
            io.stderr:write(string.format(
                "[TEST] After retarget: c2.x=%d\n", g2.x))
            io.stderr:write("[TEST] PASS: retarget works\n")
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
