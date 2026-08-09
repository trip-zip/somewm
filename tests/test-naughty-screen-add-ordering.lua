-- Test: screen_added() fires before property::geometry on hotplug screens.
-- Regression test for the VT-switch race in somewm.c:createmon().
--
-- Root cause: createmon() previously deferred screen_added() to an idle
-- callback via wl_event_loop_add_idle(). Between luaA_screen_new() and the
-- idle firing, a second output layout change event could trigger updatemons()
-- -> property::geometry on the new screen before naughty's init_screen() had
-- run, leaving by_position[s] nil and crashing pairs(nil).
--
-- Fix: screen_added() is now emitted synchronously (6ca11b1), matching
-- AwesomeWM's screen_refresh() pattern.
--
-- Test strategy: hotplug a headless output, which drives the real createmon()
-- -> updatemons() path synchronously. When _test_add_output returns, naughty's
-- init_screen() must already have run, so emitting property::geometry on the
-- new screen must not trigger a debug::error. Without the fix, this crashes.

local runner = require("_runner")

-- Force naughty.layout.box to load and register its signal handlers,
-- including the capi.screen.connect_signal("property::geometry", ...) handler.
require("naughty.layout.box")

local errors_seen = {}
awesome.connect_signal("debug::error", function(err)
    table.insert(errors_seen, tostring(err))
end)

local out_name = nil
local hot_screen = nil

local steps = {
    -- Step 1: Hotplug an output.
    -- screen_added() fires synchronously inside createmon()/updatemons(), and
    -- naughty's init_screen() runs immediately via connect_for_each_screen, so
    -- by_position[hot_screen] is populated before this returns.
    function()
        out_name = assert(awesome._test_add_output(400, 300),
            "_test_add_output failed")
        hot_screen = assert(output.get_by_name(out_name),
            "no output named " .. out_name).screen
        assert(hot_screen and hot_screen.valid,
            "hotplugged screen should be valid")
        return true
    end,

    -- Step 2: Immediately emit property::geometry on the new screen.
    -- With the fix: by_position[hot_screen] is already populated -> no crash.
    -- Without the fix: by_position[hot_screen] could be nil -> debug::error
    --   "bad argument #1 to 'pairs' (table expected, got nil)".
    --
    -- Pass old_geom to match the C emission pattern in screen.c:510-513;
    -- awful/layout/init.lua:426 expects this argument and crashes without it.
    function()
        local geom = hot_screen.geometry
        hot_screen:emit_signal("property::geometry", geom)
        return true
    end,

    -- Step 3: Verify no Lua errors were raised.
    function()
        assert(#errors_seen == 0,
            string.format(
                "FAIL: %d error(s) after property::geometry on new screen: %s",
                #errors_seen,
                errors_seen[1] or ""))
        return true
    end,

    -- Step 4: Clean up the hotplugged output.
    function()
        assert(awesome._test_remove_output(out_name),
            "_test_remove_output failed for " .. out_name)
        assert(not hot_screen.valid, "screen should be invalid after removal")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
