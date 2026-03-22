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
-- Test strategy: fake_add triggers screen_added() synchronously (screen.c uses
-- the same path). Immediately emitting property::geometry on the new screen
-- must not trigger a debug::error. Without the fix, this crashes.

local runner = require("_runner")

-- Force naughty.layout.box to load and register its signal handlers,
-- including the capi.screen.connect_signal("property::geometry", ...) handler.
require("naughty.layout.box")

local errors_seen = {}
awesome.connect_signal("debug::error", function(err)
    table.insert(errors_seen, tostring(err))
end)

local fake_screen = nil

local steps = {
    -- Step 1: Add a fake screen.
    -- screen_added() fires synchronously (same path as hotplug createmon()).
    -- naughty's init_screen() runs immediately via connect_for_each_screen,
    -- so by_position[fake_screen] is populated before this step returns.
    function()
        fake_screen = screen.fake_add(1400, 0, 400, 300)
        assert(fake_screen and fake_screen.valid, "screen.fake_add failed")
        return true
    end,

    -- Step 2: Immediately emit property::geometry on the new screen.
    -- With the fix: by_position[fake_screen] is already populated -> no crash.
    -- Without the fix: by_position[fake_screen] could be nil -> debug::error
    --   "bad argument #1 to 'pairs' (table expected, got nil)".
    --
    -- Pass old_geom to match the C emission pattern in screen.c:510-513;
    -- awful/layout/init.lua:426 expects this argument and crashes without it.
    function()
        local geom = fake_screen.geometry
        fake_screen:emit_signal("property::geometry", geom)
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

    -- Step 4: Clean up the fake screen.
    function()
        fake_screen:fake_remove()
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
