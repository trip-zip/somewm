-- Test: keygrabber key release events (issue #409).
--
-- Verifies that key release events reach keygrabber callbacks via the
-- _keygrabber.inject() C test helper. Before the fix, the C layer only
-- forwarded WL_KEYBOARD_KEY_STATE_PRESSED events and hardcoded "press"
-- as the event type, making stop_event="release" permanently lock the
-- keyboard and keyreleased_callback dead code.

local runner = require("_runner")
local awful = require("awful")

local steps = {
    -- Test 1: Release events reach the raw keygrabber callback
    function()
        local events = {}

        keygrabber.run(function(mods, key, event)
            table.insert(events, {key = key, event = event})
        end)

        _keygrabber.inject("a", true)
        _keygrabber.inject("a", false)
        keygrabber.stop()

        assert(#events == 2, "Expected 2 events, got " .. #events)
        assert(events[1].event == "press",
            "First event should be 'press', got '" .. events[1].event .. "'")
        assert(events[2].event == "release",
            "Second event should be 'release', got '" .. events[2].event .. "'")
        assert(events[1].key == "a", "Key should be 'a', got '" .. events[1].key .. "'")

        return true
    end,

    -- Test 2: stop_event="release" stops on key release, not press
    function()
        local stop_fired = false
        local press_seen = false

        local kg = awful.keygrabber {
            stop_key = "Escape",
            stop_event = "release",
            keypressed_callback = function()
                press_seen = true
            end,
            stop_callback = function()
                stop_fired = true
            end,
            autostart = true,
        }

        assert(keygrabber.isrunning(), "Keygrabber should be running")

        -- Press Escape: should NOT stop (stop_event is "release")
        _keygrabber.inject("Escape", true)
        assert(keygrabber.isrunning(),
            "Keygrabber should still be running after Escape press")
        assert(not stop_fired, "stop_callback should not fire on press")

        -- Release Escape: should stop
        _keygrabber.inject("Escape", false)
        assert(not keygrabber.isrunning(),
            "Keygrabber should have stopped after Escape release")
        assert(stop_fired, "stop_callback should fire on release")

        return true
    end,

    -- Test 3: keyreleased_callback fires on release events
    function()
        local pressed = {}
        local released = {}

        local kg = awful.keygrabber {
            keypressed_callback = function(self, mods, key, event)
                table.insert(pressed, key)
            end,
            keyreleased_callback = function(self, mods, key, event)
                table.insert(released, key)
            end,
            stop_key = "Escape",
            autostart = true,
        }

        _keygrabber.inject("x", true)
        _keygrabber.inject("x", false)

        assert(#pressed == 1, "keypressed_callback should fire once, got " .. #pressed)
        assert(#released == 1, "keyreleased_callback should fire once, got " .. #released)
        assert(pressed[1] == "x", "Pressed key should be 'x'")
        assert(released[1] == "x", "Released key should be 'x'")

        -- Clean up
        _keygrabber.inject("Escape", true)

        return true
    end,

    -- Test 4: Key sequence accumulates on release, not press
    function()
        local seq_after_press = nil
        local seq_after_release = nil

        local kg = awful.keygrabber {
            keypressed_callback = function(self)
                seq_after_press = self.sequence
            end,
            keyreleased_callback = function(self)
                seq_after_release = self.sequence
            end,
            stop_key = "Escape",
            autostart = true,
        }

        _keygrabber.inject("h", true)
        _keygrabber.inject("h", false)

        assert(seq_after_press == "",
            "Sequence should be empty after press, got '" .. tostring(seq_after_press) .. "'")
        assert(seq_after_release == "h",
            "Sequence should be 'h' after release, got '" .. tostring(seq_after_release) .. "'")

        -- Clean up
        _keygrabber.inject("Escape", true)

        return true
    end,

    -- Test 5: Standalone release event is delivered (regression guard for
    -- the old WL_KEYBOARD_KEY_STATE_PRESSED-only filter)
    function()
        local events = {}

        keygrabber.run(function(mods, key, event)
            table.insert(events, {key = key, event = event})
        end)

        -- Only inject a release, no prior press
        _keygrabber.inject("Return", false)
        keygrabber.stop()

        assert(#events == 1, "Expected 1 event, got " .. #events)
        assert(events[1].event == "release",
            "Event should be 'release', got '" .. events[1].event .. "'")
        assert(events[1].key == "Return",
            "Key should be 'Return', got '" .. events[1].key .. "'")

        return true
    end,
}

runner.run_steps(steps)
