---------------------------------------------------------------------------
--- Test: Clay debug view toggle + re-solve.
---
--- Exercises the debug-view machinery end to end on the headless backend:
--- enabling debug runs the full render path (Clay's injected debug commands ->
--- cairo overlay -> scene buffer), is_debug_enabled tracks state, a
--- debug_resolve (the pointer-motion re-solve) re-renders WITHOUT perturbing
--- client geometry, output add/remove while debug is on cleans up the
--- per-screen overlay, and disabling reflows back. The panel pixels and the
--- hover highlight are manual QA; here we assert state, geometry stability,
--- and that nothing crashes through the render / cleanup paths.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")

local saved_geo = nil
local saved_count = nil
local fake_screen = nil

local steps = {
    -- tile layout on tag 1 so the merged solve has client nodes.
    function()
        local tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = clay.tile
        return true
    end,

    function(count)
        if count == 1 then test_client("dbg_a") end
        return utils.find_client_by_class("dbg_a") and true or nil
    end,

    -- Enable debug, let the arrange it schedules run, and confirm a solve +
    -- render fired with debug on (no crash through the cairo/scene path).
    function(count)
        if count == 1 then
            assert(_somewm_clay.is_debug_enabled() == false,
                "debug should start disabled")
            _somewm_clay.reset_solve_counts()
            clay.set_debug(true)
            return nil
        end
        assert(_somewm_clay.is_debug_enabled() == true,
            "debug should be enabled after set_debug(true)")
        local c = _somewm_clay.get_solve_counts()
        if c.total < 1 then
            if count >= 10 then
                error("no solve ran after enabling debug")
            end
            return nil  -- arrange is delayed; wait for it
        end
        io.stderr:write("[TEST] PASS: debug enabled, solve + render ran\n")
        return true
    end,

    -- A debug re-solve (what pointer motion triggers via clay_debug_tick) must
    -- re-render the overlay WITHOUT moving the tiled client: it runs no_apply +
    -- debug_only, so geometry is left exactly as the last real arrange placed it.
    function(count)
        local c = utils.find_client_by_class("dbg_a")
        assert(c, "client dbg_a went away")
        if count == 1 then
            saved_geo = c:geometry()
            _somewm_clay.reset_solve_counts()
            clay.debug_resolve(screen.primary)
            return nil  -- let the next clay_apply_all run (must be a no-op)
        end
        local sc = _somewm_clay.get_solve_counts()
        assert(sc.total >= 1, "debug_resolve should run at least one solve")
        local g = c:geometry()
        assert(g.x == saved_geo.x and g.y == saved_geo.y
            and g.width == saved_geo.width and g.height == saved_geo.height,
            string.format("debug_resolve must not move the client: was %d,%d %dx%d now %d,%d %dx%d",
                saved_geo.x, saved_geo.y, saved_geo.width, saved_geo.height,
                g.x, g.y, g.width, g.height))
        io.stderr:write("[TEST] PASS: debug_resolve re-rendered without moving the client\n")
        return true
    end,

    -- Add an output while debug is on (renders an overlay on it), then remove
    -- it: clay_screen_removed must free that screen's overlay + context cleanly
    -- (ASAN catches a leak/UAF) and the screen count must return to normal.
    function(count)
        if count == 1 then
            saved_count = screen.count()
            fake_screen = screen.fake_add(1920, 0, 800, 600)
            assert(fake_screen and fake_screen.valid, "fake_add failed")
            awful.layout.arrange(fake_screen)
            return nil  -- let the fake screen's debug solve render its overlay
        end
        if count == 2 then
            fake_screen:fake_remove()
            fake_screen = nil
            return nil  -- let screen_removed -> clay_screen_removed run
        end
        if screen.count() ~= saved_count then
            if count >= 10 then
                error("screen count did not return to "..saved_count)
            end
            return nil
        end
        assert(_somewm_clay.is_debug_enabled() == true,
            "debug should still be on after the output removal")
        io.stderr:write("[TEST] PASS: output add/remove under debug cleaned up\n")
        return true
    end,

    -- Disable debug; state flips back and the desktop reflows (no crash).
    function(count)
        if count == 1 then
            clay.set_debug(false)
            return nil
        end
        assert(_somewm_clay.is_debug_enabled() == false,
            "debug should be disabled after set_debug(false)")
        io.stderr:write("[TEST] PASS: debug disabled cleanly\n")
        return true
    end,

    -- Clean up.
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then return true end
    end,
}

runner.run_steps(steps, { kill_clients = false })
