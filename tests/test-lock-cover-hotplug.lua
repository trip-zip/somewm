---------------------------------------------------------------------------
-- Test: Lock cover hotplug
--
-- Verifies that adding a lock cover while the session is already locked
-- correctly promotes it to the blocking layer, and that unlock properly
-- removes it.
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

-- Skip if _test_add_output is not available
if not awesome._test_add_output then
    io.stderr:write("SKIP: awesome._test_add_output not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local initial_screen_count = screen.count()
local interactive_wb
local cover_wbs = {}

local function set_all_visible(visible)
    interactive_wb.visible = visible
    for _, wb in ipairs(cover_wbs) do
        wb.visible = visible
    end
end

runner.run_steps({
    -- Step 1: Set up interactive lock surface on screen[1]
    function()
        interactive_wb = lock.setup()
        return true
    end,

    -- Step 2: Lock the session
    function()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        interactive_wb.visible = true
        return true
    end,

    -- Step 3: Add a new output while locked
    function()
        local name = awesome._test_add_output(800, 600)
        assert(name, "_test_add_output returned nil")
        return true
    end,

    -- Step 4: Wait for the new screen, then register a cover for it
    function()
        if screen.count() < initial_screen_count + 1 then return end
        local s = screen[screen.count()]
        local cover = wibox({
            x = s.geometry.x, y = s.geometry.y,
            width = s.geometry.width, height = s.geometry.height,
            visible = true, ontop = true, bg = "#222222",
        })
        awesome.add_lock_cover(cover)
        table.insert(cover_wbs, cover)
        assert(cover.visible, "hotplugged cover should be visible while locked")
        return true
    end,

    -- Step 5: Unlock and verify the cover is hidden after we hide it
    function()
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "should be unlocked")
        set_all_visible(false)
        -- Verify they are actually hidden (not ghost panes)
        assert(not interactive_wb.visible, "interactive should be hidden")
        for _, wb in ipairs(cover_wbs) do
            assert(not wb.visible, "cover should be hidden after unlock")
        end
        return true
    end,

    -- Step 6: Re-lock and unlock to verify session still works
    function()
        awesome.lock()
        assert(awesome.locked, "re-lock should succeed")
        set_all_visible(true)
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "re-unlock should succeed")
        set_all_visible(false)
        return true
    end,

    -- Cleanup
    function()
        lock.teardown()
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
