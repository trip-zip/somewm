---------------------------------------------------------------------------
--- Reproduction test for issue #233: XKB keyboard layout switching doesn't
--- persist with multi-layout keymaps.
---
--- Three bugs in somewm_api.c:
--- A) xkb_get_group_names() returns human-readable names instead of XKB
---    symbols format — keyboardlayout widget can't parse them
--- B) xkb_set_layout_group() doesn't persist (layout reverts immediately)
--- C) Layout group reverts to 0 after a keypress because member keyboards
---    keep single-layout keymaps
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local kb_widget = require("awful.widget.keyboardlayout")

runner.run_async(function()
    ------------------------------------------------------------------
    -- Setup: configure multi-layout keyboard (us + cz with qwerty variant)
    ------------------------------------------------------------------
    io.stderr:write("[TEST] Setting up multi-layout keyboard: us,cz(qwerty)\n")
    awful.input.xkb_layout = "us,cz"
    awful.input.xkb_variant = ",qwerty"
    async.sleep(0.3)

    ------------------------------------------------------------------
    -- Test A: xkb_get_group_names() returns parseable symbols format
    ------------------------------------------------------------------
    local group_names = awesome.xkb_get_group_names()
    io.stderr:write("[TEST] xkb_get_group_names() = " .. tostring(group_names) .. "\n")

    assert(group_names ~= nil, "xkb_get_group_names() returned nil")
    assert(type(group_names) == "string", "xkb_get_group_names() should return a string")

    -- Must NOT contain human-readable names (the bug)
    assert(not string.find(group_names, "English"),
        "group_names contains 'English' — returning human-readable names instead of symbols format")
    assert(not string.find(group_names, "Czech"),
        "group_names contains 'Czech' — returning human-readable names instead of symbols format")

    -- Must be parseable by the keyboardlayout widget
    local groups = kb_widget.get_groups_from_group_names(group_names)
    io.stderr:write("[TEST] Parsed groups: " .. tostring(groups and #groups or "nil") .. "\n")

    assert(groups ~= nil, "Widget parser returned nil — group_names format is unparseable")
    assert(#groups == 2,
        "Expected 2 layout groups, got " .. #groups ..
        " (group_names=" .. group_names .. ")")
    assert(groups[1].file == "us",
        "First group should be 'us', got '" .. tostring(groups[1].file) .. "'")
    assert(groups[2].file == "cz",
        "Second group should be 'cz', got '" .. tostring(groups[2].file) .. "'")

    io.stderr:write("[TEST] PASS: xkb_get_group_names() returns parseable symbols\n")

    ------------------------------------------------------------------
    -- Test B: xkb_set_layout_group() persists
    ------------------------------------------------------------------
    awesome.xkb_set_layout_group(1)
    async.sleep(0.2)

    local current = awesome.xkb_get_layout_group()
    io.stderr:write("[TEST] After set_layout_group(1): get_layout_group() = " .. tostring(current) .. "\n")

    assert(current == 1,
        "Layout group should be 1 after xkb_set_layout_group(1), got " .. tostring(current))

    io.stderr:write("[TEST] PASS: xkb_set_layout_group() persists\n")

    ------------------------------------------------------------------
    -- Test C: Layout group survives a keypress
    ------------------------------------------------------------------
    -- Ensure we're on group 1
    awesome.xkb_set_layout_group(1)
    async.sleep(0.2)

    -- Simulate a keypress (letter 'a')
    root.fake_input("key_press", "a")
    root.fake_input("key_release", "a")
    async.sleep(0.2)

    current = awesome.xkb_get_layout_group()
    io.stderr:write("[TEST] After keypress: get_layout_group() = " .. tostring(current) .. "\n")

    assert(current == 1,
        "Layout group reverted to " .. tostring(current) ..
        " after keypress (should stay at 1)")

    io.stderr:write("[TEST] PASS: Layout group survives keypress\n")

    ------------------------------------------------------------------
    -- Cleanup: reset to single layout
    ------------------------------------------------------------------
    awesome.xkb_set_layout_group(0)
    awful.input.xkb_layout = "us"
    awful.input.xkb_variant = ""

    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
