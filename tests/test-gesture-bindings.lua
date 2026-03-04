-- Test: awful.gesture bindings with _gesture.inject() C test helper.
--
-- Verifies that gesture bindings work end-to-end through the C↔Lua bridge:
-- swipe direction matching, hold immediate trigger, pinch updates with scale,
-- and passthrough for unbound gestures.

local runner = require("_runner")
local gesture = require("awful.gesture")

local steps = {
    -- Test 1: 3-finger swipe left binding fires correctly
    function()
        local triggered = false
        local trigger_state = nil

        local b = gesture {
            type = "swipe", fingers = 3, direction = "left",
            on_trigger = function(s)
                triggered = true
                trigger_state = s
            end,
        }

        -- Simulate via C inject
        _gesture.inject({type = "swipe_begin", time = 1000, fingers = 3})
        _gesture.inject({type = "swipe_update", time = 1010, fingers = 3, dx = -20, dy = 0})
        _gesture.inject({type = "swipe_update", time = 1020, fingers = 3, dx = -20, dy = 0})
        _gesture.inject({type = "swipe_end", time = 1030, cancelled = false})

        assert(triggered, "swipe left should have triggered")
        assert(trigger_state.direction == "left",
            "direction should be 'left', got: " .. tostring(trigger_state.direction))
        assert(trigger_state.dx == -40,
            "dx should be -40, got: " .. tostring(trigger_state.dx))

        b:remove()
        return true
    end,

    -- Test 2: Non-matching gestures pass through (returns false)
    function()
        local b = gesture {
            type = "swipe", fingers = 3, direction = "left",
            on_trigger = function() end,
        }

        -- 4-finger swipe should not be consumed
        local consumed = _gesture.inject({type = "swipe_begin", time = 2000, fingers = 4})
        assert(not consumed, "4-finger swipe should not be consumed by 3-finger binding")

        b:remove()
        return true
    end,

    -- Test 3: Hold fires immediately on begin
    function()
        local triggered = false
        local ended = false

        local b = gesture {
            type = "hold", fingers = 3,
            on_trigger = function() triggered = true end,
            on_end = function() ended = true end,
        }

        local consumed = _gesture.inject({type = "hold_begin", time = 3000, fingers = 3})
        assert(consumed, "hold should be consumed")
        assert(triggered, "hold on_trigger should fire on begin")
        assert(not ended, "hold on_end should not fire yet")

        _gesture.inject({type = "hold_end", time = 3500, cancelled = false})
        assert(ended, "hold on_end should fire on end")

        b:remove()
        return true
    end,

    -- Test 4: Pinch with on_update receives scale
    function()
        local scale_received = nil

        local b = gesture {
            type = "pinch", fingers = 2,
            on_trigger = function() end,
            on_update = function(s) scale_received = s.scale end,
        }

        _gesture.inject({type = "pinch_begin", time = 4000, fingers = 2})
        _gesture.inject({type = "pinch_update", time = 4010, fingers = 2,
            dx = 0, dy = 0, scale = 1.75, rotation = 0})
        assert(scale_received == 1.75,
            "pinch scale should be 1.75, got: " .. tostring(scale_received))

        _gesture.inject({type = "pinch_end", time = 4020, cancelled = false})
        b:remove()
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
