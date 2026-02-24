---------------------------------------------------------------------------
--- Test: selmon tracks cursor across monitor boundaries
--
-- Regression test for #245: selmon was only updated on button press or
-- focusclient(), so layer-shell clients (rofi) that don't specify an
-- output appeared on the wrong monitor after moving the mouse.
--
-- The fix updates selmon in motionnotify() on monitor boundary crossing.
-- This test uses root.fake_input("motion_notify") which routes through
-- motionnotify(), exercising the actual fix.
--
-- Requires 2 outputs:
--   WLR_WL_OUTPUTS=2 make test-one TEST=tests/test-selmon-mouse-motion.lua
---------------------------------------------------------------------------

local runner = require("_runner")

-- Skip if fewer than 2 screens (default headless has 1)
if screen.count() < 2 then
    io.stderr:write("SKIP: test-selmon-mouse-motion requires WLR_WL_OUTPUTS=2\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local s1, s2

local steps = {
    -- Step 1: Identify screens and their geometries
    function()
        s1 = screen[1]
        s2 = screen[2]
        io.stderr:write(string.format(
            "[TEST] screen 1: %dx%d+%d+%d, screen 2: %dx%d+%d+%d\n",
            s1.geometry.width, s1.geometry.height, s1.geometry.x, s1.geometry.y,
            s2.geometry.width, s2.geometry.height, s2.geometry.x, s2.geometry.y))
        return true
    end,

    -- Step 2: Warp cursor to center of screen 1, then verify
    function()
        local cx = s1.geometry.x + s1.geometry.width / 2
        local cy = s1.geometry.y + s1.geometry.height / 2
        -- Use absolute warp to position cursor
        root.fake_input("motion_notify", false, cx, cy)
        local ms = mouse.screen
        io.stderr:write(string.format(
            "[TEST] Cursor at (%d,%d), mouse.screen=%d\n", cx, cy, ms.index))
        assert(ms == s1,
            string.format("Expected mouse on screen 1, got screen %d", ms.index))
        return true
    end,

    -- Step 3: Move cursor to center of screen 2 via relative motion
    function()
        -- Calculate relative offset from screen 1 center to screen 2 center
        local s1cx = s1.geometry.x + s1.geometry.width / 2
        local s2cx = s2.geometry.x + s2.geometry.width / 2
        local s1cy = s1.geometry.y + s1.geometry.height / 2
        local s2cy = s2.geometry.y + s2.geometry.height / 2
        local dx = s2cx - s1cx
        local dy = s2cy - s1cy
        io.stderr:write(string.format(
            "[TEST] Moving cursor by relative (%d,%d)\n", dx, dy))
        root.fake_input("motion_notify", true, dx, dy)
        local ms = mouse.screen
        io.stderr:write(string.format(
            "[TEST] mouse.screen=%d (expected %d)\n", ms.index, s2.index))
        assert(ms == s2,
            string.format("BUG #245: Expected mouse on screen %d, got screen %d",
                s2.index, ms.index))
        io.stderr:write("[TEST] PASS: cursor tracked to screen 2\n")
        return true
    end,

    -- Step 4: Move back to screen 1 via relative motion
    function()
        local s1cx = s1.geometry.x + s1.geometry.width / 2
        local s2cx = s2.geometry.x + s2.geometry.width / 2
        local s1cy = s1.geometry.y + s1.geometry.height / 2
        local s2cy = s2.geometry.y + s2.geometry.height / 2
        local dx = s1cx - s2cx
        local dy = s1cy - s2cy
        root.fake_input("motion_notify", true, dx, dy)
        local ms = mouse.screen
        assert(ms == s1,
            string.format("Expected mouse back on screen 1, got screen %d", ms.index))
        io.stderr:write("[TEST] PASS: cursor tracked back to screen 1\n")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
