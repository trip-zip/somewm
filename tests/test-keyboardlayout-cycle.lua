---------------------------------------------------------------------------
--- Reproduction test for issue #438: keyboardlayout widget errors when
--- cycling layouts via mouse click at the wrap-around point.
---
--- The next_layout() modulo arithmetic produced an out-of-range group
--- number when wrapping from the last layout back to the first.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local kb_widget = require("awful.widget.keyboardlayout")

runner.run_async(function()
    ------------------------------------------------------------------
    -- Setup: configure multi-layout keyboard
    ------------------------------------------------------------------
    io.stderr:write("[TEST] Setting up multi-layout keyboard: us,cz\n")
    awful.input.xkb_layout = "us,cz"
    async.sleep(0.3)

    local instance = kb_widget()

    io.stderr:write("[TEST] Widget state: #_layout=" .. tostring(#instance._layout) .. "\n")
    assert(#instance._layout == 2,
        "Expected 2 layouts, got " .. #instance._layout)

    ------------------------------------------------------------------
    -- Test A: next_layout() from group 0 should not error
    ------------------------------------------------------------------
    awesome.xkb_set_layout_group(0)
    async.sleep(0.2)
    -- Manually sync _current since signal may be delayed in nested mode
    instance._current = awesome.xkb_get_layout_group()

    io.stderr:write("[TEST] Calling next_layout() from group 0\n")
    local ok, err = pcall(instance.next_layout)
    assert(ok, "next_layout() from group 0 errored: " .. tostring(err))
    io.stderr:write("[TEST] PASS: next_layout() from group 0 succeeded\n")

    async.sleep(0.2)

    ------------------------------------------------------------------
    -- Test B: next_layout() from group 1 should wrap to 0, not error
    -- This is the actual bug: before the fix, this produced group 2
    ------------------------------------------------------------------
    awesome.xkb_set_layout_group(1)
    async.sleep(0.2)
    -- Manually sync _current since signal may be delayed in nested mode
    instance._current = awesome.xkb_get_layout_group()
    assert(instance._current == 1,
        "Expected _current=1, got " .. tostring(instance._current))

    io.stderr:write("[TEST] Calling next_layout() from group 1 (wrap-around)\n")
    ok, err = pcall(instance.next_layout)
    assert(ok, "next_layout() from group 1 errored (wrap-around bug): " .. tostring(err))
    io.stderr:write("[TEST] PASS: next_layout() wrap-around succeeded\n")

    ------------------------------------------------------------------
    -- Test C: set_layout rejects out-of-range group numbers
    ------------------------------------------------------------------
    ok, err = pcall(instance.set_layout, #instance._layout)
    assert(not ok, "set_layout(#_layout) should error but succeeded")
    io.stderr:write("[TEST] PASS: set_layout rejects group=" .. #instance._layout .. "\n")

    ok, err = pcall(instance.set_layout, -1)
    assert(not ok, "set_layout(-1) should error but succeeded")
    io.stderr:write("[TEST] PASS: set_layout rejects group=-1\n")

    ------------------------------------------------------------------
    -- Cleanup: reset to single layout
    ------------------------------------------------------------------
    awesome.xkb_set_layout_group(0)
    awful.input.xkb_layout = "us"

    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
