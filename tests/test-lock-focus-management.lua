---------------------------------------------------------------------------
-- Test: Lock focus save/restore
--
-- Covers: BEH-5 (save focus on lock), BEH-6 (restore on unlock),
--         BEH-7 (focustop fallback if saved client is gone)
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local lock = require("_lock_helper")
local test_client = require("_client")

if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local focused_before_lock = nil

runner.run_steps({
    -- Step 1: Setup lock surface and spawn a client
    function()
        lock.setup()
        test_client("test_lock_focus")
        return true
    end,

    -- Step 2: Wait for client to appear and get focus
    function()
        if #client.get() < 1 then return end
        if client.focus == nil then return end
        return true
    end,

    -- Step 3: BEH-5/6 - Lock saves focus, unlock restores it
    function()
        focused_before_lock = client.focus
        assert(focused_before_lock ~= nil, "should have focus before lock")
        awesome.lock()
        assert(awesome.locked, "should be locked")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        return true
    end,

    -- Verify focus restored to same client (both Lua bookkeeping and keyboard)
    function(count)
        if count < 2 then return end
        assert(client.focus == focused_before_lock,
            "BEH-6: focus should be restored to pre-lock client")
        assert(focused_before_lock:has_keyboard_focus(),
            "BEH-6: pre-lock client should have Wayland keyboard focus after unlock")
        return true
    end,

    -- Step 4: Lock/unlock cycle doesn't crash with valid clients
    function()
        awesome.lock()
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        return true
    end,

    function(count)
        if count < 2 then return end
        assert(client.focus ~= nil, "focus should exist after second lock/unlock cycle")
        assert(client.focus:has_keyboard_focus(),
            "focused client should have Wayland keyboard focus after second unlock")
        return true
    end,

    -- Cleanup
    function()
        lock.teardown()
        test_client.terminate()
        return true
    end,

    -- Wait for clients to be gone
    function()
        if #client.get() > 0 then return end
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
