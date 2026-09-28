-- Test: awesome._active_modifiers reports the currently held modifiers.
--
-- It used to be a static empty table set once at startup, so
-- awful.keyboard.emulate_key_combination never released held modifiers and
-- Lua could not query modifier state at all.

local runner = require("_runner")

local function sorted(t)
    local copy = {}
    for i, v in ipairs(t) do copy[i] = v end
    table.sort(copy)
    return table.concat(copy, ",")
end

local steps = {
    function()
        assert(sorted(awesome._active_modifiers) == "",
            "Expected no modifiers, got " .. sorted(awesome._active_modifiers))

        root.fake_input("key_press", "Control_L")
        root.fake_input("key_press", "Alt_L")
        assert(sorted(awesome._active_modifiers) == "Control,Mod1",
            "Expected Control,Mod1, got " .. sorted(awesome._active_modifiers))

        root.fake_input("key_release", "Alt_L")
        assert(sorted(awesome._active_modifiers) == "Control",
            "Expected Control, got " .. sorted(awesome._active_modifiers))

        root.fake_input("key_release", "Control_L")
        assert(sorted(awesome._active_modifiers) == "",
            "Expected no modifiers, got " .. sorted(awesome._active_modifiers))

        -- Every reported name must be usable by awful.keyboard
        root.fake_input("key_press", "Shift_L")
        for _, m in ipairs(awesome._active_modifiers) do
            assert(awesome._modifiers[m], "Unknown modifier name " .. m)
        end
        root.fake_input("key_release", "Shift_L")

        return true
    end,
}

runner.run_steps(steps)
