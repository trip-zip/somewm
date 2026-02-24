---------------------------------------------------------------------------
-- Regression test for VT-switch signal ordering (PR #243)
--
-- Root cause: updatemons() emitted property::geometry BEFORE _added for
-- newly hotplugged screens. naughty's property::geometry handler does
-- pairs(by_position[s]) but init_screen() hadn't run yet, so
-- by_position[s] was nil → crash.
--
-- Fix: somewm.c updatemons() silently caches geometry for
-- needs_screen_added screens, emitting _added first.
--
-- This test uses awesome._test_add_output() to add a headless output,
-- which triggers the real createmon() → updatemons() code path — the
-- same path as VT switch-back or monitor hotplug.
--
-- Run with: HEADLESS=1 make test-one TEST=tests/test-vt-switch-signal-ordering.lua
---------------------------------------------------------------------------

local runner = require("_runner")

-- Skip if _test_add_output is not available (shouldn't happen, but be safe)
if not awesome._test_add_output then
    io.stderr:write("SKIP: awesome._test_add_output not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Force naughty.layout.box to load — this registers the
-- property::geometry handler that crashes when by_position[s] is nil.
require("naughty.layout.box")

local errors_seen = {}
awesome.connect_signal("debug::error", function(err)
    table.insert(errors_seen, tostring(err))
end)

local initial_screen_count = screen.count()

local steps = {
    -- Step 1: Add a headless output.
    -- This triggers createmon() → updatemons() — the real hotplug path.
    -- Without the fix: property::geometry fires before _added, naughty
    -- crashes with "bad argument #1 to 'pairs' (table expected, got nil)".
    function()
        local name = awesome._test_add_output(800, 600)
        assert(name, "awesome._test_add_output returned nil")
        print("TEST: Added headless output: " .. name)
        return true
    end,

    -- Step 2: Verify the new screen was created with tags.
    function()
        local count = screen.count()
        assert(count == initial_screen_count + 1,
            string.format("Expected %d screens, got %d",
                initial_screen_count + 1, count))

        -- The new screen should have tags (set by rc.lua's added handler)
        local new_screen = screen[count]
        assert(new_screen.valid, "New screen is not valid")
        print("TEST: Screen count=" .. count
            .. " new_screen=" .. tostring(new_screen)
            .. " tags=" .. #new_screen.tags)
        return true
    end,

    -- Step 3: Verify no Lua errors occurred during hotplug.
    -- This is the actual regression check — without the fix,
    -- errors_seen would contain the naughty by_position crash.
    function()
        assert(#errors_seen == 0,
            string.format(
                "FAIL: %d error(s) during hotplug: %s",
                #errors_seen,
                errors_seen[1] or ""))
        print("TEST: No errors during hotplug — signal ordering is correct")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
