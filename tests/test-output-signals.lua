---------------------------------------------------------------------------
-- Tests for output class-level signals and get_by_name:
--   1. output "added" fires when an output is hotplugged
--   2. o.screen is accessible inside "added" handler
--   3. get_by_name() finds the output by name
--   4. output "removed" fires when the output is destroyed
--   5. o.valid == true and o.name accessible inside "removed" handler
--   6. After removal: output invalidated, get_by_name returns nil
--
-- _test_add_output/_test_remove_output are synchronous (wlroots emits
-- new_output/destroy inline), so the signals have already fired when they
-- return and these steps assert directly instead of polling.
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-signals test")

local out_name = nil
local hot_output = nil

-- Capture tables for signal handler assertions
local added_info = nil
local removed_info = nil

-- Signal handlers
local function on_added(o)
    added_info = {
        name = o.name,
        valid = o.valid,
        screen = o.screen,
    }
    print("TEST:   [signal] added: " .. tostring(o.name)
        .. " screen=" .. tostring(o.screen))
end

local function on_removed(o)
    removed_info = {
        name = o.name,
        valid = o.valid,
    }
    print("TEST:   [signal] removed: " .. tostring(o.name)
        .. " valid=" .. tostring(o.valid))
end

-- Connect class-level signals before the hotplug
output.connect_signal("added", on_added)
output.connect_signal("removed", on_removed)

local steps = {
    -- Step 1: Hotplug an output - "added" signal fires
    function()
        print("TEST: Step 1 - hotplug triggers output 'added' signal")
        out_name = assert(awesome._test_add_output(400, 300),
            "_test_add_output returned nil")
        assert(added_info, "output 'added' signal did not fire")
        assert(added_info.name == out_name,
            "added signal fired for " .. tostring(added_info.name)
            .. ", expected " .. out_name)
        hot_output = assert(output.get_by_name(out_name),
            "get_by_name should find the new output")
        print("TEST:   added signal fired OK")
        return true
    end,

    -- Step 2: Verify added handler saw correct state
    function()
        print("TEST: Step 2 - Verify added handler captured state")

        -- Gap 12: signal fired with the output object
        assert(added_info.valid == true,
            "output should be valid in added handler")
        assert(type(added_info.name) == "string" and #added_info.name > 0,
            "output should have a name in added handler")

        -- Gap 9: o.screen accessible inside added handler
        assert(added_info.screen ~= nil,
            "output.screen should not be nil in added handler")
        assert(added_info.screen == hot_output.screen,
            "output.screen should reference the new screen in added handler")
        print("TEST:   o.screen accessible in added handler OK")

        return true
    end,

    -- Step 3: get_by_name() finds the output
    function()
        print("TEST: Step 3 - get_by_name finds output")
        local found = output.get_by_name(out_name)
        assert(found ~= nil,
            "get_by_name('" .. out_name .. "') returned nil")
        assert(found.name == out_name,
            "get_by_name returned wrong output")
        print("TEST:   get_by_name('" .. out_name .. "') found OK")
        return true
    end,

    -- Step 4: Output destroy triggers "removed" signal
    function()
        print("TEST: Step 4 - destroy triggers output 'removed' signal")
        assert(awesome._test_remove_output(out_name),
            "_test_remove_output failed for " .. out_name)
        assert(removed_info, "output 'removed' signal did not fire")
        print("TEST:   removed signal fired OK")

        -- Gap 10: o.valid == true inside "removed" handler (before invalidation)
        assert(removed_info.valid == true,
            "output should still be valid inside removed handler, got "
            .. tostring(removed_info.valid))
        print("TEST:   o.valid == true inside removed handler OK")

        -- Gap 10: o.name accessible inside "removed" handler
        assert(removed_info.name == out_name,
            "output name should match in removed handler, expected '"
            .. out_name .. "' got '" .. tostring(removed_info.name) .. "'")
        print("TEST:   o.name accessible inside removed handler OK")

        return true
    end,

    -- Step 5: After removal - output invalidated, get_by_name returns nil
    function()
        print("TEST: Step 5 - Post-removal state")

        -- Gap 10: after removal, output is invalidated
        assert(hot_output.valid == false,
            "output should be invalid after removal, got "
            .. tostring(hot_output.valid))
        print("TEST:   output.valid == false after removal OK")

        -- get_by_name returns nil for removed output
        local found = output.get_by_name(out_name)
        assert(found == nil,
            "get_by_name should return nil for removed output")
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
