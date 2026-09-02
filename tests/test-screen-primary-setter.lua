---------------------------------------------------------------------------
-- Tests for assigning screen.primary:
--   1. screen.primary = s updates screen.primary
--   2. Assigning emits primary_changed on the new primary screen
--   3. Assigning the current primary is a no-op (no signal)
--   4. Unrelated keys on the screen table still assign normally
---------------------------------------------------------------------------

local runner = require("_runner")

local original_primary = nil
local fake_screen = nil
local changed = 0

local function on_changed()
    changed = changed + 1
end

local steps = {
    -- Step 1: Add a second screen so there is something to switch to
    function()
        original_primary = screen.primary
        assert(original_primary, "no primary screen")

        fake_screen = screen.fake_add(1400, 0, 400, 300)
        assert(fake_screen ~= original_primary, "fake screen is already primary")

        screen.connect_signal("primary_changed", on_changed)
        return true
    end,

    -- Step 2: Assigning a new primary takes effect and signals
    function()
        screen.primary = fake_screen
        assert(screen.primary == fake_screen,
            "screen.primary was not updated by assignment")
        assert(changed == 1,
            "primary_changed fired " .. changed .. " times, expected 1")
        return true
    end,

    -- Step 3: Re-assigning the same screen is a no-op
    function()
        screen.primary = fake_screen
        assert(changed == 1,
            "primary_changed fired again for an unchanged primary")
        return true
    end,

    -- Step 4: Other keys still assign normally
    function()
        screen.some_test_key = "value"
        assert(screen.some_test_key == "value",
            "assigning an unrelated key on the screen table broke")
        return true
    end,

    -- Step 5: Restore
    function()
        screen.primary = original_primary
        screen.disconnect_signal("primary_changed", on_changed)
        fake_screen:fake_remove()
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
