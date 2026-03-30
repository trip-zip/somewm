---------------------------------------------------------------------------
-- Test: Lock edge cases
--
-- Covers: EDGE-2 force-unlock path (via clear_lock_surface while locked)
--
-- Note: The true EDGE-2 scenario (drawin destroyed by wl_surface destruction)
-- cannot be triggered from Lua because the lock surface registry reference
-- keeps the drawin alive. This test exercises the force-unlock path by
-- clearing the surface while locked, which triggers the same recovery logic.
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")
local lock = require("_lock_helper")

-- Check if we're in headless mode
local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

if is_headless() then
    io.stderr:write("SKIP: session lock test requires ext-session-lock protocol (unavailable in headless)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local deactivate_fired = false

awesome.connect_signal("lock::deactivate", function()
    deactivate_fired = true
end)

runner.run_steps({
    -- Step 1: Lock with a surface, then authenticate and verify normal unlock
    function()
        lock.setup()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "should be unlocked")
        return true
    end,

    -- Step 2: Lock, clear the surface while locked, verify we can still recover
    -- (authenticate + unlock should still work even without surface)
    function()
        lock.setup()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        deactivate_fired = false

        awesome.clear_lock_surface()

        -- Session is still locked but surface is gone.
        -- We can still authenticate and unlock.
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "should be unlocked after auth+unlock with no surface")
        assert(deactivate_fired, "lock::deactivate should have fired")
        return true
    end,

    -- Step 3: Verify session is still functional (can lock again with new surface)
    function()
        lock.setup()
        local result = awesome.lock()
        assert(result == true, "should be able to lock again after recovery")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        return true
    end,

    -- Cleanup
    function()
        lock.teardown()
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
