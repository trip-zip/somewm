---------------------------------------------------------------------------
-- Tests for screen.fake_add() / fake_remove() full lifecycle:
--   1. fake_add creates a valid screen with tags and wibar
--   2. Signals fire correctly during fake_add
--   3. fake_remove invalidates the screen
--   4. Layoutlist widget survives screen removal (PR #391 regression)
--   5. Multiple add/remove cycles don't leak or crash
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

print("TEST: Starting screen-fake-add-lifecycle test")

local initial_count = screen.count()
local fake_screen = nil
local added_screens = {}
local removed_screens = {}
local errors = {}

-- Capture errors that would normally become notifications
awesome.connect_signal("debug::error", function(err)
    table.insert(errors, tostring(err))
end)

-- Track added/removed signals (connect before fake_add)
screen.connect_signal("added", function(s)
    table.insert(added_screens, s)
end)
screen.connect_signal("removed", function(s)
    table.insert(removed_screens, s)
end)

local steps = {
    -- Step 1: fake_add creates a valid screen
    function()
        print("TEST: Step 1 - fake_add creates valid screen")
        fake_screen = screen.fake_add(0, 0, 1920, 1080)
        assert(fake_screen ~= nil, "fake_add returned nil")
        assert(fake_screen.valid, "fake screen not valid")
        assert(screen.count() == initial_count + 1,
            "screen count should increment, got " .. screen.count())
        print("TEST:   screen count: " .. screen.count())
        return true
    end,

    -- Step 2: Screen has tags and signals fired
    function()
        print("TEST: Step 2 - Screen has tags, signals fired")
        assert(#fake_screen.tags > 0,
            "fake screen has no tags, desktop_decoration handler didn't run")
        print("TEST:   tags: " .. #fake_screen.tags)

        -- Check added signal fired for our screen
        local found = false
        for _, s in ipairs(added_screens) do
            if s == fake_screen then found = true; break end
        end
        assert(found, "added signal did not fire for fake screen")
        print("TEST:   added signal fired OK")
        return true
    end,

    -- Step 3: Layoutlist widget bound to fake screen works
    function()
        print("TEST: Step 3 - Layoutlist on fake screen")
        local layouts = awful.widget.layoutlist.source.for_screen(fake_screen)
        assert(type(layouts) == "table", "for_screen should return table")
        assert(#layouts > 0, "for_screen should return layouts")
        print("TEST:   layouts: " .. #layouts)
        return true
    end,

    -- Step 4: fake_remove invalidates the screen
    function()
        print("TEST: Step 4 - fake_remove")
        fake_screen:fake_remove()
        assert(not fake_screen.valid, "screen should be invalid after removal")
        assert(screen.count() == initial_count,
            "screen count should return to initial, got " .. screen.count())
        print("TEST:   screen count back to " .. screen.count())
        return true
    end,

    -- Step 5: Layoutlist gracefully handles removed screen (PR #391)
    function()
        print("TEST: Step 5 - Layoutlist handles removed screen")
        local ok, result = pcall(awful.widget.layoutlist.source.for_screen,
            fake_screen)
        assert(ok, "for_screen should not error on invalid screen: "
            .. tostring(result))
        assert(type(result) == "table", "should return table")
        assert(#result == 0, "should return empty table for invalid screen")
        print("TEST:   graceful empty return OK")
        return true
    end,

    -- Step 6: Multiple add/remove cycles
    function()
        print("TEST: Step 6 - Multiple add/remove cycles")
        for i = 1, 3 do
            local s = screen.fake_add(0, 0, 800, 600)
            assert(s ~= nil, "cycle " .. i .. ": fake_add returned nil")
            assert(s.valid, "cycle " .. i .. ": not valid")
            s:fake_remove()
            assert(not s.valid, "cycle " .. i .. ": still valid after remove")
        end
        assert(screen.count() == initial_count,
            "screen count should be initial after cycles")
        print("TEST:   3 cycles OK, count = " .. screen.count())
        return true
    end,

    -- Step 7: No errors accumulated
    function()
        print("TEST: Step 7 - No errors during test")
        assert(#errors == 0,
            "Errors during test:\n" .. table.concat(errors, "\n"))
        print("TEST:   0 errors OK")
        return true
    end,
}

runner.run_steps(steps)
