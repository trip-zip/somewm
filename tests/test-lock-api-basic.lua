---------------------------------------------------------------------------
-- Test: Lock API basics
--
-- Covers: SEC-1, SEC-2, BEH-1, BEH-2, EDGE-1, lock signals
---------------------------------------------------------------------------

local runner = require("_runner")
local lock = require("_lock_helper")

local signals = {}
awesome.connect_signal("lock::activate", function(source)
    table.insert(signals, { name = "lock::activate", source = source })
end)
awesome.connect_signal("lock::deactivate", function()
    table.insert(signals, { name = "lock::deactivate" })
end)
awesome.connect_signal("lock::auth_failed", function(attempt_count)
    table.insert(signals, { name = "lock::auth_failed", attempt_count = attempt_count })
end)

runner.run_steps({
    -- Step 1: Setup lock surface, verify lock() works (proves surface was set)
    function()
        lock.setup()
        -- lock() returns false if no surface registered, so this proves it worked
        local result = awesome.lock()
        assert(result == true, "lock should succeed (proves set_lock_surface worked)")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        return true
    end,

    -- Step 2: BEH-2 - unlock when not locked returns true
    function()
        assert(not awesome.locked, "should not be locked yet")
        local result = awesome.unlock()
        assert(result == true, "unlock when not locked should return true")
        return true
    end,

    -- Step 3: lock() returns true, awesome.locked == true, lock::activate fires
    function()
        signals = {}
        local result = awesome.lock()
        assert(result == true, "lock should return true")
        assert(awesome.locked, "awesome.locked should be true")
        assert(#signals == 1, "expected 1 signal, got " .. #signals)
        assert(signals[1].name == "lock::activate", "expected lock::activate")
        assert(signals[1].source == "user", "expected source='user'")
        return true
    end,

    -- Step 4: BEH-1 - second lock() doesn't re-emit signal
    function()
        signals = {}
        local result = awesome.lock()
        assert(result == true, "second lock should return true")
        assert(#signals == 0, "second lock should not emit signal")
        return true
    end,

    -- Step 5: SEC-1 - unlock without authenticate fails
    function()
        assert(awesome.locked, "should still be locked")
        assert(not awesome.authenticated, "should not be authenticated")
        local result = awesome.unlock()
        assert(result == false, "unlock without auth should return false")
        assert(awesome.locked, "should still be locked after failed unlock")
        return true
    end,

    -- Step 6: SEC-2 - authenticate, unlock, re-lock, verify authenticated reset
    function()
        local authed = awesome.authenticate(lock.TEST_PASSWORD)
        assert(authed == true, "authenticate should succeed")
        assert(awesome.authenticated, "authenticated should be true")

        local unlocked = awesome.unlock()
        assert(unlocked == true, "unlock should succeed after auth")
        assert(not awesome.locked, "should not be locked")

        -- Re-lock and verify authenticated was reset
        signals = {}
        awesome.lock()
        assert(awesome.locked, "should be locked again")
        assert(not awesome.authenticated, "authenticated should be reset on new lock")
        return true
    end,

    -- Step 7: lock::auth_failed fires with incrementing attempt_count
    function()
        signals = {}
        awesome.authenticate("wrongpass1")
        assert(#signals == 1, "expected 1 auth_failed signal")
        assert(signals[1].name == "lock::auth_failed")
        assert(signals[1].attempt_count == 1, "first failed attempt should be 1")

        signals = {}
        awesome.authenticate("wrongpass2")
        assert(#signals == 1, "expected 1 auth_failed signal")
        assert(signals[1].attempt_count == 2, "second failed attempt should be 2")
        return true
    end,

    -- Step 8: lock::deactivate fires on successful unlock
    function()
        awesome.authenticate(lock.TEST_PASSWORD)
        signals = {}
        local unlocked = awesome.unlock()
        assert(unlocked == true, "unlock should succeed")
        assert(#signals == 1, "expected 1 signal")
        assert(signals[1].name == "lock::deactivate", "expected lock::deactivate")
        return true
    end,

    -- Step 9: EDGE-1 - clear_lock_surface then lock() returns false
    function()
        awesome.clear_lock_surface()
        local result = awesome.lock()
        assert(result == false, "lock without surface should return false")
        assert(not awesome.locked, "should not be locked")
        return true
    end,

    -- Cleanup
    function()
        lock.teardown()
        return true
    end,
})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
