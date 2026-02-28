---------------------------------------------------------------------------
-- Tests for output class-level signals and virtual get_by_name:
--   1. output "added" fires during fake_add()
--   2. o.screen is accessible inside "added" handler
--   3. get_by_name() finds virtual output by name
--   4. output "removed" fires during fake_remove()
--   5. o.valid == true and o.name accessible inside "removed" handler
--   6. After removal: output invalidated, get_by_name returns nil
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-signals test")

local fake_screen = nil
local fake_output = nil

-- Capture tables for signal handler assertions
local added_info = nil
local removed_info = nil

-- Signal handlers
local function on_added(o)
    added_info = {
        name = o.name,
        valid = o.valid,
        virtual = o.virtual,
        screen = o.screen,
    }
    print("TEST:   [signal] added: " .. tostring(o.name)
        .. " screen=" .. tostring(o.screen))
end

local function on_removed(o)
    removed_info = {
        name = o.name,
        valid = o.valid,
        virtual = o.virtual,
    }
    print("TEST:   [signal] removed: " .. tostring(o.name)
        .. " valid=" .. tostring(o.valid))
end

-- Connect class-level signals before any fake_add
output.connect_signal("added", on_added)
output.connect_signal("removed", on_removed)

local steps = {
    -- Step 1: Create fake screen — "added" signal fires synchronously
    function()
        print("TEST: Step 1 - fake_add triggers output 'added' signal")
        fake_screen = screen.fake_add(1400, 0, 400, 300)
        fake_output = fake_screen.output

        -- Signal fired synchronously during fake_add
        assert(added_info ~= nil,
            "output 'added' signal did not fire during fake_add()")
        print("TEST:   added signal fired OK")
        return true
    end,

    -- Step 2: Verify added handler saw correct state
    function()
        print("TEST: Step 2 - Verify added handler captured state")

        -- Gap 12: signal fired with the output object
        assert(added_info.valid == true,
            "output should be valid in added handler")
        assert(added_info.virtual == true,
            "output should be virtual in added handler")
        assert(type(added_info.name) == "string" and #added_info.name > 0,
            "output should have a name in added handler")

        -- Gap 9: o.screen accessible inside added handler
        assert(added_info.screen ~= nil,
            "output.screen should not be nil in added handler")
        assert(added_info.screen == fake_screen,
            "output.screen should reference the fake screen in added handler")
        print("TEST:   o.screen == fake_screen in added handler OK")

        return true
    end,

    -- Step 3: get_by_name() finds virtual output
    function()
        print("TEST: Step 3 - get_by_name finds virtual output")
        local name = fake_output.name
        local found = output.get_by_name(name)
        assert(found ~= nil,
            "get_by_name('" .. name .. "') returned nil for virtual output")
        assert(found.name == name,
            "get_by_name returned wrong output")
        assert(found.virtual == true,
            "get_by_name result should be virtual")
        print("TEST:   get_by_name('" .. name .. "') found virtual OK")
        return true
    end,

    -- Step 4: fake_remove triggers "removed" signal
    function()
        print("TEST: Step 4 - fake_remove triggers output 'removed' signal")
        local output_name = fake_output.name
        fake_screen:fake_remove()

        -- Signal fired synchronously during fake_remove
        assert(removed_info ~= nil,
            "output 'removed' signal did not fire during fake_remove()")
        print("TEST:   removed signal fired OK")

        -- Gap 10: o.valid == true inside "removed" handler (before invalidation)
        assert(removed_info.valid == true,
            "output should still be valid inside removed handler, got "
            .. tostring(removed_info.valid))
        print("TEST:   o.valid == true inside removed handler OK")

        -- Gap 10: o.name accessible inside "removed" handler
        assert(removed_info.name == output_name,
            "output name should match in removed handler, expected '"
            .. output_name .. "' got '" .. tostring(removed_info.name) .. "'")
        print("TEST:   o.name accessible inside removed handler OK")

        return true
    end,

    -- Step 5: After removal — output invalidated, get_by_name returns nil
    function()
        print("TEST: Step 5 - Post-removal state")

        -- Gap 10: after fake_remove, output is invalidated
        assert(fake_output.valid == false,
            "output should be invalid after fake_remove, got "
            .. tostring(fake_output.valid))
        print("TEST:   output.valid == false after removal OK")

        -- get_by_name returns nil for removed virtual output
        local found = output.get_by_name(removed_info.name)
        assert(found == nil,
            "get_by_name should return nil for removed virtual output")
        print("TEST:   get_by_name returns nil after removal OK")

        return true
    end,

    -- Step 6: Disconnect signal handlers (cleanup)
    function()
        print("TEST: Step 6 - Cleanup signal handlers")
        output.disconnect_signal("added", on_added)
        output.disconnect_signal("removed", on_removed)
        print("TEST:   signal handlers disconnected OK")
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
