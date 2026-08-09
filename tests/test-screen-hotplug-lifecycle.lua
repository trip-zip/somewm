---------------------------------------------------------------------------
-- Tests for hotplugged screen full lifecycle:
--   1. A hotplugged output creates a valid screen with tags
--   2. Signals fire correctly during hotplug
--   3. Output removal invalidates the screen
--   4. Layoutlist widget survives screen removal (PR #391 regression)
--   5. Multiple add/remove cycles don't leak or crash
--
-- _test_add_output and _test_remove_output are synchronous: wlroots emits
-- new_output/destroy inline, and createmon/cleanupmon build and tear down the
-- screen before the helper returns. So these steps assert directly instead of
-- polling.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

print("TEST: Starting screen-hotplug-lifecycle test")

local initial_count = screen.count()
local out_name = nil
local hot_screen = nil
local added_screens = {}
local removed_screens = {}
local errors = {}

-- Capture errors that would normally become notifications
awesome.connect_signal("debug::error", function(err)
    table.insert(errors, tostring(err))
end)

-- Track added/removed signals (connect before hotplug)
screen.connect_signal("added", function(s)
    table.insert(added_screens, s)
end)
screen.connect_signal("removed", function(s)
    table.insert(removed_screens, s)
end)

local steps = {
    -- Step 1: hotplug creates a valid screen
    function()
        print("TEST: Step 1 - hotplug creates valid screen")
        out_name = assert(awesome._test_add_output(1920, 1080),
            "_test_add_output returned nil")
        hot_screen = assert(output.get_by_name(out_name),
            "no output named " .. out_name).screen
        assert(hot_screen, "hotplugged output has no screen")
        assert(hot_screen.valid, "hotplugged screen not valid")
        assert(screen.count() == initial_count + 1,
            "screen count should increment, got " .. screen.count())
        print("TEST:   screen count: " .. screen.count())
        return true
    end,

    -- Step 2: Screen has tags and signals fired
    function()
        print("TEST: Step 2 - Screen has tags, signals fired")
        assert(#hot_screen.tags > 0,
            "hotplugged screen has no tags, desktop_decoration handler didn't run")
        print("TEST:   tags: " .. #hot_screen.tags)

        -- Check added signal fired for our screen
        local found = false
        for _, s in ipairs(added_screens) do
            if s == hot_screen then found = true; break end
        end
        assert(found, "added signal did not fire for hotplugged screen")
        print("TEST:   added signal fired OK")
        return true
    end,

    -- Step 3: Layoutlist widget bound to the new screen works
    function()
        print("TEST: Step 3 - Layoutlist on hotplugged screen")
        local layouts = awful.widget.layoutlist.source.for_screen(hot_screen)
        assert(type(layouts) == "table", "for_screen should return table")
        assert(#layouts > 0, "for_screen should return layouts")
        print("TEST:   layouts: " .. #layouts)
        return true
    end,

    -- Step 4: Output removal invalidates the screen
    function()
        print("TEST: Step 4 - remove output")
        assert(awesome._test_remove_output(out_name),
            "_test_remove_output failed for " .. out_name)
        assert(not hot_screen.valid, "screen should be invalid after removal")
        assert(screen.count() == initial_count,
            "screen count should return to initial, got " .. screen.count())
        print("TEST:   screen count back to " .. screen.count())

        -- Check removed signal fired for our screen
        local found = false
        for _, s in ipairs(removed_screens) do
            if s == hot_screen then found = true; break end
        end
        assert(found, "removed signal did not fire for hotplugged screen")
        return true
    end,

    -- Step 5: Layoutlist gracefully handles removed screen (PR #391)
    function()
        print("TEST: Step 5 - Layoutlist handles removed screen")
        local ok, result = pcall(awful.widget.layoutlist.source.for_screen,
            hot_screen)
        assert(ok, "for_screen should not error on invalid screen: "
            .. tostring(result))
        assert(type(result) == "table", "should return table")
        assert(#result == 0, "should return empty table for invalid screen")
        print("TEST:   graceful empty return OK")
        return true
    end,
}

-- Step 6 and on: each add/remove cycle is its own step
for i = 1, 3 do
    steps[#steps + 1] = function()
        local name = assert(awesome._test_add_output(800, 600),
            "cycle " .. i .. ": _test_add_output failed")
        local s = assert(output.get_by_name(name), "cycle " .. i
            .. ": no output named " .. name).screen
        assert(s and s.valid, "cycle " .. i .. ": screen not valid")
        assert(awesome._test_remove_output(name),
            "cycle " .. i .. ": _test_remove_output failed")
        assert(not s.valid, "cycle " .. i .. ": still valid after remove")
        assert(screen.count() == initial_count,
            "cycle " .. i .. ": screen count not restored")
        print("TEST:   cycle " .. i .. " OK, count = " .. screen.count())
        return true
    end
end

-- Final step: no errors accumulated
steps[#steps + 1] = function()
    print("TEST: No errors during test")
    assert(#errors == 0,
        "Errors during test:\n" .. table.concat(errors, "\n"))
    print("TEST:   0 errors OK")
    return true
end

runner.run_steps(steps)
