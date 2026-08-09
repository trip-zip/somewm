---------------------------------------------------------------------------
-- Test: Lock multi-screen support
--
-- Covers: MULTI-1 through MULTI-7, cover API integration
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")
local awful = require("awful")
local lock = require("_lock_helper")

-- Skip if _test_add_output is not available
if not awesome._test_add_output then
    io.stderr:write("SKIP: awesome._test_add_output not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local initial_screen_count = screen.count()
local interactive_wb, cover_wbs
local out2_name, out3_name

runner.run_steps({
    -- Step 1: Add a second headless output
    function()
        out2_name = awesome._test_add_output(800, 600)
        assert(out2_name, "_test_add_output returned nil")
        return true
    end,

    -- Step 2: Wait for second screen
    function()
        if screen.count() < initial_screen_count + 1 then return end
        assert(screen.count() == initial_screen_count + 1,
            "expected " .. (initial_screen_count + 1) .. " screens")
        return true
    end,

    -- Step 3: Create interactive wibox on screen[1], cover on screen[2]
    function()
        cover_wbs = {}
        local s1 = screen[1]
        interactive_wb = wibox({
            x = s1.geometry.x, y = s1.geometry.y,
            width = s1.geometry.width, height = s1.geometry.height,
            visible = false, ontop = true, bg = "#111111",
        })
        awesome.set_lock_surface(interactive_wb)

        for i = 2, screen.count() do
            local s = screen[i]
            local cover = wibox({
                x = s.geometry.x, y = s.geometry.y,
                width = s.geometry.width, height = s.geometry.height,
                visible = false, ontop = true, bg = "#222222",
            })
            awesome.add_lock_cover(cover)
            table.insert(cover_wbs, cover)
        end
        return true
    end,

    -- Step 4: Lock - verify surfaces can be made visible
    function()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        interactive_wb.visible = true
        for _, wb in ipairs(cover_wbs) do
            wb.visible = true
        end
        assert(interactive_wb.visible, "interactive surface should be visible")
        for _, wb in ipairs(cover_wbs) do
            assert(wb.visible, "cover surface should be visible")
        end
        return true
    end,

    -- Step 5: Add third output while locked - create cover for it
    function()
        out3_name = awesome._test_add_output(640, 480)
        assert(out3_name, "failed to add third output")
        return true
    end,

    -- Step 6: Wait for third screen and add a cover for it
    function()
        if screen.count() < initial_screen_count + 2 then return end
        local s = screen[screen.count()]
        local cover = wibox({
            x = s.geometry.x, y = s.geometry.y,
            width = s.geometry.width, height = s.geometry.height,
            visible = true, ontop = true, bg = "#333333",
        })
        awesome.add_lock_cover(cover)
        table.insert(cover_wbs, cover)
        assert(cover.visible, "new cover should be visible while locked")
        return true
    end,

    -- Step 7: Remove third output while locked (MULTI-6).
    -- _test_remove_output is synchronous, so the screen is gone on return.
    function()
        assert(awesome._test_remove_output(out3_name),
            "_test_remove_output failed for " .. out3_name)
        assert(screen.count() == initial_screen_count + 1,
            "expected " .. (initial_screen_count + 1) .. " screens after removal")
        assert(awesome.locked, "should still be locked after screen removal")
        return true
    end,

    -- Step 8: Authenticate and unlock - verify surfaces hidden
    function()
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "should be unlocked")
        interactive_wb.visible = false
        for _, wb in ipairs(cover_wbs) do
            wb.visible = false
        end
        assert(not interactive_wb.visible, "interactive should be hidden after unlock")
        return true
    end,

    -- Cleanup: remove the added output so persistent runs stay clean
    function()
        assert(awesome._test_remove_output(out2_name),
            "_test_remove_output failed for " .. out2_name)
        assert(screen.count() == initial_screen_count,
            "screen count should return to " .. initial_screen_count)
        lock.teardown()
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
