-- Test: naughty notification batch destroy (issue #193).
--
-- Bug: lua/naughty/core.lua:502-507 uses ipairs + table.remove without break.
-- When destroying multiple notifications, table.remove shifts indices down,
-- causing ipairs to skip the next element. The result is that one notification
-- remains stuck in naughty._active and cannot be dismissed.
--
-- This has existed in AwesomeWM since commit 97417121 (2019). Every other
-- table.remove in the naughty module has break or return — this is the only
-- instance missing it.
--
-- Reproduction: create 3 persistent notifications, destroy all of them,
-- assert that naughty._active is empty.

local runner = require("_runner")
local naughty = require("naughty")
local notification = require("naughty.notification")

-- Register minimal handlers so notifications can be created without a full
-- widget stack. The naughty module requires request::display to consider
-- itself "active" and register() asserts a preset is set.
naughty.connect_signal("request::display", function() end)

local errors_seen = {}
awesome.connect_signal("debug::error", function(err)
    table.insert(errors_seen, tostring(err))
end)

local notifs = {}

local steps = {
    -- Step 1: Create 3 persistent notifications (timeout=0 = never expires).
    function()
        for i = 1, 3 do
            notifs[i] = notification({
                title   = "test " .. i,
                text    = "notification " .. i,
                timeout = 0,
            })
        end

        assert(#naughty.active == 3,
            string.format("Expected 3 active, got %d", #naughty.active))
        return true
    end,

    -- Step 2: Destroy all notifications.
    -- This triggers the buggy ipairs+table.remove loop in core.lua cleanup().
    -- Without the fix, the second notification is skipped and remains stuck.
    function()
        for _, n in ipairs(notifs) do
            n:destroy()
        end
        return true
    end,

    -- Step 3: Verify all notifications were removed from _active.
    -- Without the fix: #naughty.active == 1 (one notification stuck).
    -- With the fix: #naughty.active == 0.
    function()
        assert(#naughty.active == 0,
            string.format(
                "BUG: %d notification(s) stuck in naughty.active after destroy",
                #naughty.active))

        assert(#errors_seen == 0,
            string.format("Unexpected error(s): %s", errors_seen[1] or ""))
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
