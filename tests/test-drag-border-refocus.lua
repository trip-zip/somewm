---------------------------------------------------------------------------
--- Test: border colors update correctly after drag ends
--
-- Regression test for issue #308: when a drag operation ends, the focused
-- client's border should return to the correct focus color. Previously,
-- destroydragicon() fired while seat->drag was still set, so the border
-- color guard in focusclient() blocked the update.
--
-- Uses root.fake_drag_start()/fake_drag_end() to simulate drag operations
-- without needing real Wayland data device protocol interaction.
--
-- Key insight: the Lua focus path (client.focus = c) does NOT set C-level
-- border colors. Only the C-level focusclient() does. So before drag,
-- borders are normal color (Lua path was used). After root.fake_drag_end(),
-- destroydrag() calls focusclient() (C path) which sets the focus color.
-- This is exactly what the fix ensures.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local c1, c2

local steps = {
    -- Step 1: Spawn first client
    function(count)
        if count == 1 then
            test_client("drag_border_a")
        end
        c1 = utils.find_client_by_class("drag_border_a")
        return c1 and true or nil
    end,

    -- Step 2: Spawn second client (gets focus)
    function(count)
        if count == 1 then
            test_client("drag_border_b")
        end
        c2 = utils.find_client_by_class("drag_border_b")
        if not c2 then return nil end
        -- Wait for c2 to have focus
        if client.focus ~= c2 then return nil end
        return true
    end,

    -- Step 3: Verify initial state - Lua focus path does NOT set C-level
    -- border colors, so both clients have normal (creation) color
    function()
        assert(client.focus == c2, "c2 should be focused")
        assert(c1:_border_is_normal_color(),
            "c1 should have normal border color initially")
        assert(c2:_border_is_normal_color(),
            "c2 should have normal border color initially (Lua focus path)")
        return true
    end,

    -- Step 4: Simulate drag without icon (the secondary bug path).
    -- After drag ends, destroydrag() calls C-level focusclient() which
    -- sets the focused client's border to focus color.
    function()
        root.fake_drag_start()
        root.fake_drag_end()

        -- destroydrag() called focusclient(focustop(selmon), 0).
        -- Since seat->drag is NULL, the border color guard passes and
        -- the focused client gets the focus color.
        assert(client.focus == c2,
            "c2 should still be focused after drag ends")
        assert(c2:_border_is_focus_color(),
            "c2 border should be focus color after drag ends (no icon)")
        assert(c1:_border_is_normal_color(),
            "c1 border should be normal color after drag ends (no icon)")

        io.stderr:write("[TEST] PASS: border colors correct after drag without icon\n")
        return true
    end,

    -- Step 5: Simulate a second drag cycle to verify listener cleanup
    function()
        root.fake_drag_start()
        root.fake_drag_end()

        assert(c2:_border_is_focus_color(),
            "c2 border should be focus color after second drag cycle")
        assert(c1:_border_is_normal_color(),
            "c1 border should be normal color after second drag cycle")

        io.stderr:write("[TEST] PASS: border colors correct after repeated drag\n")
        return true
    end,

    -- Step 6: Cleanup
    test_client.step_force_cleanup(),
}

runner.run_steps(steps, { kill_clients = false })
