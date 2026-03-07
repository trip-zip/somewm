---------------------------------------------------------------------------
-- Test: Drawin geometry updates after screen scale change
--
-- Verifies that wiboxes matching screen geometry are auto-resized when
-- the screen's logical size changes due to a scale change. Covers both
-- visible drawins (resized immediately) and invisible drawins (resized
-- when made visible).
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")

local test_wibox_visible = nil
local test_wibox_invisible = nil

local original_scale = nil
local initial_geo = nil

local steps = {
    -- Step 1: Record initial screen geometry (scale 1.0)
    function()
        local s = screen[1]
        original_scale = s.scale
        initial_geo = s.geometry

        print("TEST: initial screen geometry: "
            .. initial_geo.width .. "x" .. initial_geo.height
            .. " scale=" .. original_scale)

        assert(initial_geo.width > 0, "screen width must be > 0")
        assert(initial_geo.height > 0, "screen height must be > 0")
        return true
    end,

    -- Step 2: Create visible wibox matching screen geometry exactly
    function()
        local s = screen[1]
        test_wibox_visible = wibox {
            x = initial_geo.x,
            y = initial_geo.y,
            width = initial_geo.width,
            height = initial_geo.height,
            visible = true,
            screen = s,
        }
        assert(test_wibox_visible, "visible wibox creation failed")

        local geo = test_wibox_visible:geometry()
        assert(geo.width == initial_geo.width,
            "visible wibox width should match screen: "
            .. geo.width .. " vs " .. initial_geo.width)
        assert(geo.height == initial_geo.height,
            "visible wibox height should match screen: "
            .. geo.height .. " vs " .. initial_geo.height)

        print("TEST: visible wibox created at "
            .. geo.width .. "x" .. geo.height)
        return true
    end,

    -- Step 3: Change scale to 2.0
    function()
        screen[1].scale = 2.0
        print("TEST: set scale to 2.0")
        return true
    end,

    -- Step 4: Wait one step for propagation, then verify
    function()
        local s = screen[1]
        local new_geo = s.geometry

        print("TEST: screen geometry after scale=2.0: "
            .. new_geo.width .. "x" .. new_geo.height)

        -- Screen geometry should have halved
        assert(new_geo.width == math.floor(initial_geo.width / 2),
            "screen width should be halved: expected "
            .. math.floor(initial_geo.width / 2)
            .. ", got " .. new_geo.width)
        assert(new_geo.height == math.floor(initial_geo.height / 2),
            "screen height should be halved: expected "
            .. math.floor(initial_geo.height / 2)
            .. ", got " .. new_geo.height)

        -- Visible wibox should have been auto-resized
        local wgeo = test_wibox_visible:geometry()
        print("TEST: visible wibox geometry after scale: "
            .. wgeo.width .. "x" .. wgeo.height)
        assert(wgeo.width == new_geo.width,
            "visible wibox width should match new screen: expected "
            .. new_geo.width .. ", got " .. wgeo.width)
        assert(wgeo.height == new_geo.height,
            "visible wibox height should match new screen: expected "
            .. new_geo.height .. ", got " .. wgeo.height)
        assert(wgeo.x == new_geo.x,
            "visible wibox x should match new screen: expected "
            .. new_geo.x .. ", got " .. wgeo.x)
        assert(wgeo.y == new_geo.y,
            "visible wibox y should match new screen: expected "
            .. new_geo.y .. ", got " .. wgeo.y)

        print("[PASS] Visible wibox auto-resized on scale change")
        return true
    end,

    -- Step 5: Test invisible drawin path - create invisible wibox at current geometry
    function()
        local s = screen[1]
        local geo = s.geometry
        test_wibox_invisible = wibox {
            x = geo.x,
            y = geo.y,
            width = geo.width,
            height = geo.height,
            visible = false,
            screen = s,
        }
        assert(test_wibox_invisible, "invisible wibox creation failed")

        print("TEST: invisible wibox created at "
            .. geo.width .. "x" .. geo.height .. " (scale=2.0)")
        return true
    end,

    -- Step 6: Change scale to 3.0
    function()
        screen[1].scale = 3.0
        print("TEST: set scale to 3.0")
        return true
    end,

    -- Step 7: Make invisible wibox visible, check it gets resized
    function()
        local s = screen[1]
        local new_geo = s.geometry

        print("TEST: screen geometry after scale=3.0: "
            .. new_geo.width .. "x" .. new_geo.height)

        -- Wibox still has old geometry (from scale=2.0), which is larger
        -- than screen at scale=3.0. Making it visible should auto-shrink.
        test_wibox_invisible.visible = true

        local wgeo = test_wibox_invisible:geometry()
        print("TEST: invisible->visible wibox geometry: "
            .. wgeo.width .. "x" .. wgeo.height)
        assert(wgeo.width == new_geo.width,
            "shown wibox width should match screen: expected "
            .. new_geo.width .. ", got " .. wgeo.width)
        assert(wgeo.height == new_geo.height,
            "shown wibox height should match screen: expected "
            .. new_geo.height .. ", got " .. wgeo.height)

        print("[PASS] Invisible->visible wibox auto-resized on show")
        return true
    end,

    -- Step 8: Restore and cleanup
    function()
        if test_wibox_visible then
            test_wibox_visible.visible = false
            test_wibox_visible = nil
        end
        if test_wibox_invisible then
            test_wibox_invisible.visible = false
            test_wibox_invisible = nil
        end
        screen[1].scale = original_scale
        print("[TEST] Cleanup complete, scale restored to " .. original_scale)
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
