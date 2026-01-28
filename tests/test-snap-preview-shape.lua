-- Test: Snap preview shape_bounding with ARGB32 surface (issue #224)
-- Verifies A1→ARGB32 format fix doesn't regress.

local runner = require("_runner")
local wibox = require("wibox")
local gears = require("gears")
local cairo = require("lgi").cairo

local test_wibox = nil

local steps = {
    -- Step 1: Create wibox (similar to snap preview placeholder)
    function()
        test_wibox = wibox {
            x = 100,
            y = 100,
            width = 400,
            height = 300,
            bg = "#ff0000",
            ontop = true,
            visible = true,
        }
        assert(test_wibox, "Failed to create wibox")
        io.stderr:write("[TEST] Created test wibox\n")
        return true
    end,

    -- Step 2: Create ARGB32 surface with shape (like snap.lua does)
    function()
        local geo = test_wibox:geometry()

        -- This is the exact pattern from the fixed snap.lua
        local img = cairo.ImageSurface(cairo.Format.ARGB32, geo.width, geo.height)
        local cr = cairo.Context(img)
        cr:set_antialias(cairo.Antialias.BEST)

        -- Clear and draw shape outline (same as snap.lua)
        cr:set_operator(cairo.Operator.CLEAR)
        cr:set_source_rgba(0, 0, 0, 1)
        cr:paint()
        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(1, 1, 1, 1)

        local line_width = 5
        cr:set_line_width(line_width)
        cr:translate(line_width, line_width)
        gears.shape.rounded_rect(cr, geo.width - 2 * line_width, geo.height - 2 * line_width, 10)
        cr:stroke()

        -- This assignment would crash with A1 format (issue #224)
        test_wibox.shape_bounding = img._native
        test_wibox._shape_bounding_surface = img  -- Keep reference to prevent GC

        io.stderr:write("[PASS] ARGB32 shape_bounding assigned without crash\n")
        return true
    end,

    -- Step 3: Verify wibox is still valid and visible
    function()
        assert(test_wibox.visible == true, "wibox should still be visible")
        assert(test_wibox.drawable.valid == true, "drawable should still be valid")
        io.stderr:write("[PASS] Wibox remains valid after shape_bounding assignment\n")
        return true
    end,

    -- Step 4: Test A1 format would have crashed (verify format matters)
    -- We can't actually test A1 crashing, but we can verify ARGB32 properties
    function()
        local geo = test_wibox:geometry()
        local img = cairo.ImageSurface(cairo.Format.ARGB32, geo.width, geo.height)

        -- ARGB32 should have 4 bytes per pixel stride
        local stride = img:get_stride()
        local expected_min_stride = geo.width * 4  -- At least 4 bytes per pixel
        assert(stride >= expected_min_stride,
            string.format("ARGB32 stride should be >= %d, got %d", expected_min_stride, stride))

        io.stderr:write("[PASS] ARGB32 surface has correct stride (4 bytes/pixel)\n")
        return true
    end,

    -- Step 5: Cleanup
    function()
        if test_wibox then
            test_wibox.visible = false
            test_wibox = nil
        end
        io.stderr:write("[TEST] Cleanup complete\n")
        return true
    end,
}

runner.run_steps(steps)
