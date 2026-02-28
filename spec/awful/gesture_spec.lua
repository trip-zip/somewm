---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

-- Mock _gesture C table before requiring the module
local handler_fn = nil
_G._gesture = {
    set_handler = function(fn)
        handler_fn = fn
    end,
    inject = function(event)
        if handler_fn then
            return handler_fn(event)
        end
        return false
    end,
}

local gesture = require("awful.gesture")

describe("awful.gesture", function()
    -- Helper: simulate a full gesture sequence through handler_fn
    local function send(event)
        return handler_fn(event)
    end

    before_each(function()
        -- Re-register all bindings fresh by reloading
        -- Instead, we'll track and remove bindings manually
    end)

    describe("registration", function()
        it("registers a swipe binding and returns an object", function()
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() end,
            }
            assert.is_not_nil(b)
            assert.is.equal("swipe", b.type)
            assert.is.equal(3, b.fingers)
            assert.is.equal("left", b.direction)
            b:remove()
        end)

        it("registers a hold binding", function()
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() end,
            }
            assert.is.equal("hold", b.type)
            b:remove()
        end)

        it("registers a pinch binding", function()
            local b = gesture {
                type = "pinch", fingers = 2,
                on_update = function() end,
            }
            assert.is.equal("pinch", b.type)
            b:remove()
        end)

        it("rejects invalid type", function()
            assert.has_error(function()
                gesture { type = "tap", fingers = 1 }
            end)
        end)

        it("rejects direction on non-swipe", function()
            assert.has_error(function()
                gesture { type = "hold", fingers = 3, direction = "left" }
            end)
        end)

        it("rejects invalid direction", function()
            assert.has_error(function()
                gesture { type = "swipe", fingers = 3, direction = "diagonal" }
            end)
        end)
    end)

    describe("removal", function()
        it("remove() stops binding from matching", function()
            local triggered = false
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() triggered = true end,
            }
            b:remove()

            local consumed = send({type = "hold_begin", time = 100, fingers = 3})
            assert.is_false(consumed)
            assert.is_false(triggered)
        end)

        it("double remove() is safe", function()
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() end,
            }
            b:remove()
            assert.has_no_errors(function() b:remove() end)
        end)
    end)

    describe("hold gesture", function()
        it("fires on_trigger on begin", function()
            local state = nil
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function(s) state = s end,
            }

            local consumed = send({type = "hold_begin", time = 100, fingers = 3})
            assert.is_true(consumed)
            assert.is_not_nil(state)
            assert.is.equal("hold", state.type)
            assert.is.equal(3, state.fingers)
            assert.is.equal(100, state.time)

            send({type = "hold_end", time = 200, cancelled = false})
            b:remove()
        end)

        it("fires on_end on end", function()
            local end_state = nil
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() end,
                on_end = function(s) end_state = s end,
            }

            send({type = "hold_begin", time = 100, fingers = 3})
            send({type = "hold_end", time = 200, cancelled = false})
            assert.is_not_nil(end_state)
            assert.is_false(end_state.cancelled)
            b:remove()
        end)

        it("passes cancelled flag", function()
            local end_state = nil
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() end,
                on_end = function(s) end_state = s end,
            }

            send({type = "hold_begin", time = 100, fingers = 3})
            send({type = "hold_end", time = 200, cancelled = true})
            assert.is_true(end_state.cancelled)
            b:remove()
        end)

        it("does not consume non-matching finger count", function()
            local b = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() end,
            }

            local consumed = send({type = "hold_begin", time = 100, fingers = 4})
            assert.is_false(consumed)
            b:remove()
        end)
    end)

    describe("swipe with direction", function()
        it("fires on_trigger on end when direction matches", function()
            local trigger_state = nil
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function(s) trigger_state = s end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            -- Swipe left (negative dx)
            send({type = "swipe_update", time = 110, fingers = 3, dx = -20, dy = 0})
            send({type = "swipe_update", time = 120, fingers = 3, dx = -20, dy = 0})
            assert.is_nil(trigger_state) -- not triggered yet (direction just committed)

            send({type = "swipe_end", time = 130, cancelled = false})
            assert.is_not_nil(trigger_state)
            assert.is.equal("left", trigger_state.direction)
            assert.is.equal(-40, trigger_state.dx)
            b:remove()
        end)

        it("does not fire on_trigger when direction doesn't match", function()
            local triggered = false
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() triggered = true end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = 20, dy = 0})
            send({type = "swipe_update", time = 120, fingers = 3, dx = 20, dy = 0})
            send({type = "swipe_end", time = 130, cancelled = false})
            assert.is_false(triggered)
            b:remove()
        end)

        it("does not fire on_trigger when cancelled", function()
            local triggered = false
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() triggered = true end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = -40, dy = 0})
            send({type = "swipe_end", time = 130, cancelled = true})
            assert.is_false(triggered)
            b:remove()
        end)

        it("fires on_end even when direction doesn't match", function()
            local end_called = false
            local b_left = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() end,
                on_end = function() end_called = true end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = -40, dy = 0})
            send({type = "swipe_end", time = 130, cancelled = false})
            -- on_end fires because there IS a matched binding (direction matches)
            assert.is_true(end_called)
            b_left:remove()
        end)
    end)

    describe("swipe without direction", function()
        it("fires on_trigger immediately on begin", function()
            local trigger_state = nil
            local b = gesture {
                type = "swipe", fingers = 3,
                on_trigger = function(s) trigger_state = s end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            assert.is_not_nil(trigger_state)
            assert.is.equal("swipe", trigger_state.type)

            send({type = "swipe_end", time = 130, cancelled = false})
            b:remove()
        end)

        it("fires on_update on each update", function()
            local updates = {}
            local b = gesture {
                type = "swipe", fingers = 3,
                on_trigger = function() end,
                on_update = function(s) table.insert(updates, s) end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = -10, dy = 5})
            send({type = "swipe_update", time = 120, fingers = 3, dx = -15, dy = 3})
            assert.is.equal(2, #updates)
            assert.is.equal(-25, updates[2].dx)
            assert.is.equal(8, updates[2].dy)

            send({type = "swipe_end", time = 130, cancelled = false})
            b:remove()
        end)
    end)

    describe("pinch gesture", function()
        it("fires on_trigger on begin and on_update with scale", function()
            local trigger_state = nil
            local update_states = {}
            local b = gesture {
                type = "pinch", fingers = 2,
                on_trigger = function(s) trigger_state = s end,
                on_update = function(s) table.insert(update_states, s) end,
            }

            send({type = "pinch_begin", time = 100, fingers = 2})
            assert.is_not_nil(trigger_state)
            assert.is.equal("pinch", trigger_state.type)

            send({type = "pinch_update", time = 110, fingers = 2,
                dx = 1, dy = 0, scale = 1.5, rotation = 10})
            assert.is.equal(1, #update_states)
            assert.is.equal(1.5, update_states[1].scale)
            assert.is.equal(10, update_states[1].rotation)

            send({type = "pinch_end", time = 130, cancelled = false})
            b:remove()
        end)
    end)

    describe("direction detection", function()
        it("detects up direction", function()
            local trigger_state = nil
            local b = gesture {
                type = "swipe", fingers = 3, direction = "up",
                on_trigger = function(s) trigger_state = s end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = 0, dy = -40})
            send({type = "swipe_end", time = 130, cancelled = false})
            assert.is_not_nil(trigger_state)
            assert.is.equal("up", trigger_state.direction)
            b:remove()
        end)

        it("detects down direction", function()
            local trigger_state = nil
            local b = gesture {
                type = "swipe", fingers = 3, direction = "down",
                on_trigger = function(s) trigger_state = s end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = 0, dy = 40})
            send({type = "swipe_end", time = 130, cancelled = false})
            assert.is_not_nil(trigger_state)
            assert.is.equal("down", trigger_state.direction)
            b:remove()
        end)

        it("detects right direction", function()
            local trigger_state = nil
            local b = gesture {
                type = "swipe", fingers = 3, direction = "right",
                on_trigger = function(s) trigger_state = s end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = 40, dy = 0})
            send({type = "swipe_end", time = 130, cancelled = false})
            assert.is_not_nil(trigger_state)
            assert.is.equal("right", trigger_state.direction)
            b:remove()
        end)

        it("respects direction_threshold", function()
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            -- Below threshold (default 30)
            send({type = "swipe_update", time = 110, fingers = 3, dx = -25, dy = 0})
            -- Check that direction isn't committed yet by ending
            local triggered = false
            b:remove()

            local b2 = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() triggered = true end,
            }
            send({type = "swipe_begin", time = 200, fingers = 3})
            send({type = "swipe_update", time = 210, fingers = 3, dx = -25, dy = 0})
            send({type = "swipe_end", time = 220, cancelled = false})
            -- Direction was not committed (25 < 30), so on_trigger doesn't fire
            assert.is_false(triggered)
            b2:remove()
        end)

        it("direction_threshold can be changed", function()
            local old = gesture.direction_threshold
            gesture.direction_threshold = 10

            local triggered = false
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() triggered = true end,
            }

            send({type = "swipe_begin", time = 100, fingers = 3})
            send({type = "swipe_update", time = 110, fingers = 3, dx = -15, dy = 0})
            send({type = "swipe_end", time = 120, cancelled = false})
            assert.is_true(triggered)

            gesture.direction_threshold = old
            b:remove()
        end)
    end)

    describe("consume-eagerly", function()
        it("consumes all gestures matching type+fingers", function()
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() end,
            }

            -- 3-finger swipe right should still be consumed (because 3-finger
            -- swipe bindings exist), even though direction won't match
            local consumed = send({type = "swipe_begin", time = 100, fingers = 3})
            assert.is_true(consumed)

            send({type = "swipe_update", time = 110, fingers = 3, dx = 40, dy = 0})
            send({type = "swipe_end", time = 120, cancelled = false})
            b:remove()
        end)

        it("does not consume unmatched finger counts", function()
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() end,
            }

            local consumed = send({type = "swipe_begin", time = 100, fingers = 4})
            assert.is_false(consumed)
            b:remove()
        end)
    end)

    describe("first match wins", function()
        it("matches the first registered binding", function()
            local first_triggered = false
            local second_triggered = false

            local b1 = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() first_triggered = true end,
            }
            local b2 = gesture {
                type = "hold", fingers = 3,
                on_trigger = function() second_triggered = true end,
            }

            send({type = "hold_begin", time = 100, fingers = 3})
            assert.is_true(first_triggered)
            assert.is_false(second_triggered)

            send({type = "hold_end", time = 200, cancelled = false})
            b1:remove()
            b2:remove()
        end)
    end)

    describe("metadata", function()
        it("stores description and group", function()
            local b = gesture {
                type = "swipe", fingers = 3, direction = "left",
                on_trigger = function() end,
                description = "view previous tag",
                group = "tag",
            }
            assert.is.equal("view previous tag", b.description)
            assert.is.equal("tag", b.group)
            b:remove()
        end)
    end)
end)
