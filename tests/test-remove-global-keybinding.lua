---------------------------------------------------------------------------
--- Reproduction test for issue #405: root._remove_key() is a silent no-op
---
--- Verifies that awful.keyboard.remove_global_keybinding() immediately
--- removes ALL C key objects (one per modifier combo) from the C layer.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")

runner.run_async(function()
    -- Create a test keybinding (awful.key creates multiple C key objects
    -- for modifier combinations like numlock on/off)
    local test_key = awful.key({ "Mod4" }, "F12", function() end,
        { description = "test key for removal", group = "test" })

    local num_ckeys = #test_key
    io.stderr:write("[TEST] awful.key has " .. num_ckeys .. " C key objects\n")

    -- Add it and wait for delayed sync
    awful.keyboard.append_global_keybindings({ test_key })
    async.sleep(0.3)

    -- Verify all C key objects are registered
    local count_before = #root._keys()
    assert(root.has_key(test_key), "Key should be registered after append")
    io.stderr:write("[TEST] PASS: key registered (" .. count_before .. " total C keys)\n")

    -- Remove it
    awful.keyboard.remove_global_keybinding(test_key)

    -- All C key objects should be gone IMMEDIATELY
    assert(not root.has_key(test_key),
        "Key should be removed from C layer immediately")
    io.stderr:write("[TEST] PASS: key removed immediately\n")

    -- Verify the count decreased by the right amount
    local count_after = #root._keys()
    local removed = count_before - count_after
    assert(removed == num_ckeys,
        "Expected " .. num_ckeys .. " C keys removed, got " .. removed)
    io.stderr:write("[TEST] PASS: " .. removed .. " C key objects removed\n")

    runner.done()
end)
