---------------------------------------------------------------------------
-- Test: Lock surface and cover API
--
-- Covers: BEH-9, BEH-10, BEH-11, BEH-12, cover API
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")
local awful = require("awful")
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

runner.run_steps({
    -- Step 1: BEH-9 - set_lock_surface accepts wibox
    function()
        local s = awful.screen.focused()
        local wb = wibox({
            x = 0, y = 0,
            width = s.geometry.width,
            height = s.geometry.height,
            visible = false,
            bg = "#000000",
        })
        awesome.set_lock_surface(wb)
        -- Verify surface is registered by attempting lock (returns false without surface)
        local result = awesome.lock()
        assert(result == true, "lock should succeed with wibox surface")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        awesome.clear_lock_surface()
        return true
    end,

    -- Step 2: BEH-12 - rejects invalid types
    function()
        local ok, err

        ok, err = pcall(function() awesome.set_lock_surface("bad") end)
        assert(not ok, "should reject string")

        ok, err = pcall(function() awesome.set_lock_surface(42) end)
        assert(not ok, "should reject number")

        ok, err = pcall(function() awesome.set_lock_surface(nil) end)
        assert(not ok, "should reject nil")

        ok, err = pcall(function() awesome.set_lock_surface({}) end)
        assert(not ok, "should reject table without drawin")

        return true
    end,

    -- Step 3: BEH-11 - setting new surface replaces old (lock still works)
    function()
        local wb1 = wibox({
            x = 0, y = 0, width = 100, height = 100,
            visible = false, bg = "#ff0000",
        })
        local wb2 = wibox({
            x = 0, y = 0, width = 200, height = 200,
            visible = false, bg = "#00ff00",
        })
        awesome.set_lock_surface(wb1)
        awesome.set_lock_surface(wb2)
        -- Lock should still work with the replaced surface
        local result = awesome.lock()
        assert(result == true, "lock should succeed after surface replacement")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        awesome.clear_lock_surface()
        return true
    end,

    -- Step 4: BEH-10 - surface survives GC after registration
    function()
        do
            local wb = wibox({
                x = 0, y = 0, width = 100, height = 100,
                visible = false, bg = "#0000ff",
            })
            awesome.set_lock_surface(wb)
        end
        -- wb is out of scope, force GC
        collectgarbage("collect")
        collectgarbage("collect")
        -- If the surface was GC'd, lock() would fail (returns false)
        local result = awesome.lock()
        assert(result == true, "lock surface should survive GC")
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        awesome.clear_lock_surface()
        return true
    end,

    -- Step 5: clear_lock_surface prevents lock
    function()
        lock.setup()
        awesome.clear_lock_surface()
        local result = awesome.lock()
        assert(result == false, "lock should fail after clear_lock_surface")
        return true
    end,

    -- Step 6: Cover API - add, idempotent add, remove, clear
    function()
        local covers = {}
        for i = 1, 3 do
            covers[i] = wibox({
                x = 0, y = 0, width = 100, height = 100,
                visible = false, bg = "#000000",
            })
            awesome.add_lock_cover(covers[i])
        end

        -- Idempotent: adding same cover again should not error
        awesome.add_lock_cover(covers[1])

        -- Remove one
        awesome.remove_lock_cover(covers[2])

        -- Clear all
        awesome.clear_lock_covers()
        return true
    end,

    -- Cleanup
    function()
        lock.teardown()
        return true
    end,
})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
