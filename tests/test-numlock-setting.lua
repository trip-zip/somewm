---------------------------------------------------------------------------
--- Test for issue #239: NumLock breaks wibar scroll bindings.
---
--- Verifies that awesome._set_keyboard_setting("numlock", bool) toggles
--- NumLock without crashing, exercising the full path:
---   Lua -> luaA_awesome_set_keyboard_setting("numlock") -> some_set_numlock()
---     -> xkb_state_serialize_mods -> wlr_keyboard_notify_modifiers
---
--- Note: The CLEANMASK regression (scroll/button bindings firing with NumLock
--- active) cannot currently be tested from the Lua integration layer because
--- root.fake_input("button_press") uses wlr_seat_pointer_notify_button, which
--- delivers to Wayland clients rather than triggering buttonnotify/axisnotify.
--- A full regression test would require virtual pointer injection
--- (wlr_virtual_pointer_v1).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")

runner.run_async(function()
    ------------------------------------------------------------------
    -- Test: toggle NumLock on and off without error
    ------------------------------------------------------------------
    io.stderr:write("[TEST] Enabling NumLock via _set_keyboard_setting\n")
    awesome._set_keyboard_setting("numlock", true)
    async.sleep(0.2)

    io.stderr:write("[TEST] Disabling NumLock via _set_keyboard_setting\n")
    awesome._set_keyboard_setting("numlock", false)
    async.sleep(0.1)

    io.stderr:write("[TEST] Re-enabling NumLock\n")
    awesome._set_keyboard_setting("numlock", true)
    async.sleep(0.1)

    io.stderr:write("[TEST] Disabling NumLock again\n")
    awesome._set_keyboard_setting("numlock", false)
    async.sleep(0.1)

    io.stderr:write("[TEST] PASS: _set_keyboard_setting('numlock') toggles without crashing\n")

    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
