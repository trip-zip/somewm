---------------------------------------------------------------------------
-- Tests for screen.scale <-> output.scale delegation:
--   1. screen.scale and output.scale are always equal
--   2. Setting screen.scale updates output.scale
--   3. Setting output.scale updates screen.scale
--   4. property::scale signal fires on both objects
--   5. Scale range validation
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-scale-delegation test")

local steps = {
    -- Step 1: Initial values match
    function()
        print("TEST: Step 1 - Initial scale values match")
        for s in screen do
            local o = s.output
            assert(o ~= nil, "screen " .. s.index .. " has nil output")
            assert(s.scale == o.scale,
                "screen " .. s.index .. " scale (" .. s.scale
                .. ") != output.scale (" .. o.scale .. ")")
            print("TEST:   screen " .. s.index
                .. " scale = " .. s.scale .. " OK")
        end
        return true
    end,

    -- Step 2: Setting screen.scale updates output.scale
    function()
        print("TEST: Step 2 - screen.scale setter updates output")
        local s = screen[1]
        local o = s.output
        local original = s.scale

        s.scale = 2.0
        assert(s.scale == 2.0,
            "screen.scale should be 2.0, got " .. s.scale)
        assert(o.scale == 2.0,
            "output.scale should be 2.0, got " .. o.scale)
        print("TEST:   screen.scale=2.0 -> output.scale=" .. o.scale)

        -- Restore
        s.scale = original
        return true
    end,

    -- Step 3: Setting output.scale updates screen.scale
    function()
        print("TEST: Step 3 - output.scale setter updates screen")
        local s = screen[1]
        local o = s.output
        local original = o.scale

        o.scale = 1.5
        assert(o.scale == 1.5,
            "output.scale should be 1.5, got " .. o.scale)
        assert(s.scale == 1.5,
            "screen.scale should be 1.5, got " .. s.scale)
        print("TEST:   output.scale=1.5 -> screen.scale=" .. s.scale)

        -- Restore
        o.scale = original
        return true
    end,

    -- Step 4: Signals fire on both objects
    function()
        print("TEST: Step 4 - Signals fire on both objects")
        local s = screen[1]
        local o = s.output
        local original = o.scale

        local output_signal_fired = false
        local screen_signal_fired = false

        local output_handler = function()
            output_signal_fired = true
        end
        local screen_handler = function()
            screen_signal_fired = true
        end

        o:connect_signal("property::scale", output_handler)
        s:connect_signal("property::scale", screen_handler)

        -- Change scale via output
        o.scale = 1.25

        assert(output_signal_fired,
            "property::scale should fire on output")
        assert(screen_signal_fired,
            "property::scale should fire on screen")
        print("TEST:   output signal: " .. tostring(output_signal_fired))
        print("TEST:   screen signal: " .. tostring(screen_signal_fired))

        -- Cleanup
        o:disconnect_signal("property::scale", output_handler)
        s:disconnect_signal("property::scale", screen_handler)
        o.scale = original

        return true
    end,

    -- Step 5: Signals fire when set via screen too
    function()
        print("TEST: Step 5 - Signals fire when set via screen")
        local s = screen[1]
        local o = s.output
        local original = s.scale

        local output_signal_fired = false
        local screen_signal_fired = false

        local output_handler = function()
            output_signal_fired = true
        end
        local screen_handler = function()
            screen_signal_fired = true
        end

        o:connect_signal("property::scale", output_handler)
        s:connect_signal("property::scale", screen_handler)

        -- Change scale via screen
        s.scale = 1.75

        assert(output_signal_fired,
            "property::scale should fire on output when set via screen")
        assert(screen_signal_fired,
            "property::scale should fire on screen when set via screen")
        print("TEST:   via screen -> output signal: "
            .. tostring(output_signal_fired))
        print("TEST:   via screen -> screen signal: "
            .. tostring(screen_signal_fired))

        -- Cleanup
        o:disconnect_signal("property::scale", output_handler)
        s:disconnect_signal("property::scale", screen_handler)
        s.scale = original

        return true
    end,

    -- Step 6: Scale validation
    function()
        print("TEST: Step 6 - Scale range validation")
        local o = output[1]

        -- Too small
        local ok, err = pcall(function()
            o.scale = 0.01
        end)
        assert(not ok, "expected error for scale=0.01")
        print("TEST:   scale=0.01 error: " .. err)

        -- Too large
        local ok2, err2 = pcall(function()
            o.scale = 100
        end)
        assert(not ok2, "expected error for scale=100")
        print("TEST:   scale=100 error: " .. err2)

        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
