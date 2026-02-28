---------------------------------------------------------------------------
-- Tests for virtual output setter no-op behavior:
--   1. Setting scale on virtual output does not error or change value
--   2. Setting transform on virtual output does not error or change value
--   3. Setting enabled on virtual output does not error or change value
--   4. No property signals fire for virtual output setter attempts
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-virtual-setters test")

local fake_screen = nil
local fake_output = nil

-- Track property signals
local signals_fired = {}
local function make_signal_handler(name)
    return function()
        signals_fired[name] = (signals_fired[name] or 0) + 1
        print("TEST:   [signal] " .. name .. " fired (unexpected)")
    end
end

local on_scale = make_signal_handler("property::scale")
local on_transform = make_signal_handler("property::transform")
local on_enabled = make_signal_handler("property::enabled")

local steps = {
    -- Step 1: Create fake screen with virtual output
    function()
        print("TEST: Step 1 - Create fake screen")
        fake_screen = screen.fake_add(1400, 0, 400, 300)
        fake_output = fake_screen.output
        assert(fake_output ~= nil, "fake screen has no output")
        assert(fake_output.virtual == true, "output should be virtual")
        assert(fake_output.valid == true, "output should be valid")

        -- Connect property signals on the instance
        fake_output:connect_signal("property::scale", on_scale)
        fake_output:connect_signal("property::transform", on_transform)
        fake_output:connect_signal("property::enabled", on_enabled)

        print("TEST:   virtual output created: " .. fake_output.name)
        return true
    end,

    -- Step 2: scale setter no-ops on virtual output
    function()
        print("TEST: Step 2 - scale setter on virtual output")
        local original = fake_output.scale
        print("TEST:   original scale = " .. original)

        -- Should not error
        fake_output.scale = 2.0

        -- Value should not change (virtual outputs return 1.0)
        assert(fake_output.scale == original,
            "virtual output scale should remain " .. original
            .. " after set, got " .. fake_output.scale)
        print("TEST:   scale unchanged after set OK")
        return true
    end,

    -- Step 3: transform setter no-ops on virtual output
    function()
        print("TEST: Step 3 - transform setter on virtual output")
        local original = fake_output.transform
        print("TEST:   original transform = " .. original)

        -- Integer form should not error
        fake_output.transform = 1

        assert(fake_output.transform == original,
            "virtual output transform should remain " .. original
            .. " after set with integer, got " .. fake_output.transform)
        print("TEST:   transform unchanged after integer set OK")

        -- String form should not error
        fake_output.transform = "90"

        assert(fake_output.transform == original,
            "virtual output transform should remain " .. original
            .. " after set with string, got " .. fake_output.transform)
        print("TEST:   transform unchanged after string set OK")
        return true
    end,

    -- Step 4: enabled setter no-ops on virtual output
    function()
        print("TEST: Step 4 - enabled setter on virtual output")
        local original = fake_output.enabled
        print("TEST:   original enabled = " .. tostring(original))

        fake_output.enabled = true
        assert(fake_output.enabled == original,
            "virtual output enabled should remain " .. tostring(original)
            .. " after set true, got " .. tostring(fake_output.enabled))

        fake_output.enabled = false
        assert(fake_output.enabled == original,
            "virtual output enabled should remain " .. tostring(original)
            .. " after set false, got " .. tostring(fake_output.enabled))

        print("TEST:   enabled unchanged after set OK")
        return true
    end,

    -- Step 5: No property signals fired
    function()
        print("TEST: Step 5 - Verify no property signals fired")
        assert((signals_fired["property::scale"] or 0) == 0,
            "property::scale should not fire on virtual output, fired "
            .. (signals_fired["property::scale"] or 0) .. " times")
        assert((signals_fired["property::transform"] or 0) == 0,
            "property::transform should not fire on virtual output, fired "
            .. (signals_fired["property::transform"] or 0) .. " times")
        assert((signals_fired["property::enabled"] or 0) == 0,
            "property::enabled should not fire on virtual output, fired "
            .. (signals_fired["property::enabled"] or 0) .. " times")
        print("TEST:   no property signals fired OK")
        return true
    end,

    -- Step 6: Cleanup
    function()
        print("TEST: Step 6 - Cleanup")
        fake_output:disconnect_signal("property::scale", on_scale)
        fake_output:disconnect_signal("property::transform", on_transform)
        fake_output:disconnect_signal("property::enabled", on_enabled)
        fake_screen:fake_remove()
        assert(fake_output.valid == false,
            "output should be invalid after fake_remove")
        print("TEST:   cleanup complete OK")
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
