---------------------------------------------------------------------------
-- Test: Drawin shape (rounded corners) renders with proper transparency
--
-- Verifies that shape_bounding masks produce fully transparent corners,
-- not semi-transparent artifacts from premultiplied alpha bugs.
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local cairo = require("lgi").cairo
local ffi = require("ffi")

-- Test wibox parameters
local BOX_X, BOX_Y = 50, 50
local BOX_W, BOX_H = 200, 100
local CORNER_RADIUS = 20
local BOX_COLOR = "#ff5500"  -- Bright orange for visibility

local test_wibox = nil

--- Get ARGB pixel value from a cairo surface at (x, y)
-- Uses LuaJIT FFI to read raw pixel data from cairo surface
local function get_pixel(surface, x, y)
    surface:flush()
    local data = surface:get_data()
    local stride = surface:get_stride()
    local width = surface:get_width()
    local height = surface:get_height()

    if x < 0 or x >= width or y < 0 or y >= height then
        return nil
    end

    -- Cast lgi userdata to FFI pointer for direct memory access
    local ptr = ffi.cast('uint8_t*', data)

    -- ARGB32 format: 4 bytes per pixel (BGRA in memory on little-endian)
    local offset = y * stride + x * 4
    local b = ptr[offset + 0]
    local g = ptr[offset + 1]
    local r = ptr[offset + 2]
    local a = ptr[offset + 3]

    return { a = a, r = r, g = g, b = b }
end

--- Check if a pixel is fully transparent (premultiplied: all channels = 0)
local function is_fully_transparent(pixel)
    return pixel.a == 0 and pixel.r == 0 and pixel.g == 0 and pixel.b == 0
end

--- Check if a pixel has the box color (non-transparent orange)
local function is_box_color(pixel)
    return pixel.a > 200  -- Should be nearly opaque
end

local steps = {
    -- Step 1: Create wibox with rounded corners
    function()
        test_wibox = wibox {
            x = BOX_X,
            y = BOX_Y,
            width = BOX_W,
            height = BOX_H,
            bg = BOX_COLOR,
            visible = true,
            screen = awful.screen.focused(),
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, CORNER_RADIUS)
            end,
        }
        return true
    end,

    -- Step 2: Wait a frame for rendering
    function(count)
        if count >= 2 then
            return true
        end
        -- Return nil to keep waiting (not false, which means failure)
    end,

    -- Step 3: Capture screenshot and verify corner transparency
    function()
        -- Get screenshot with alpha preserved
        local surface = root.content(true)
        if not surface then
            error("Failed to get root.content()")
        end

        -- Wrap in lgi cairo surface
        surface = cairo.Surface(surface, true)

        -- Test points: corners should be transparent, center should have color
        local corner_points = {
            { x = BOX_X + 2, y = BOX_Y + 2, name = "top-left" },
            { x = BOX_X + BOX_W - 3, y = BOX_Y + 2, name = "top-right" },
            { x = BOX_X + 2, y = BOX_Y + BOX_H - 3, name = "bottom-left" },
            { x = BOX_X + BOX_W - 3, y = BOX_Y + BOX_H - 3, name = "bottom-right" },
        }

        local center_point = {
            x = BOX_X + BOX_W / 2,
            y = BOX_Y + BOX_H / 2,
            name = "center"
        }

        -- Verify corners are fully transparent
        for _, pt in ipairs(corner_points) do
            local pixel = get_pixel(surface, pt.x, pt.y)
            if not pixel then
                error("Could not read pixel at " .. pt.name)
            end

            if not is_fully_transparent(pixel) then
                error(string.format(
                    "%s corner NOT fully transparent: a=%d r=%d g=%d b=%d " ..
                    "(expected all zeros for premultiplied alpha)",
                    pt.name, pixel.a, pixel.r, pixel.g, pixel.b
                ))
            end
            io.stderr:write(string.format("[PASS] %s corner is transparent\n", pt.name))
        end

        -- Verify center has color (sanity check)
        local center_pixel = get_pixel(surface, center_point.x, center_point.y)
        if not is_box_color(center_pixel) then
            error(string.format(
                "Center pixel not opaque: a=%d (expected >200)",
                center_pixel.a
            ))
        end
        io.stderr:write("[PASS] Center has expected color\n")

        -- Note: lgi manages surface lifecycle, no explicit destroy needed
        return true
    end,

    -- Step 4: Cleanup
    function()
        if test_wibox then
            test_wibox.visible = false
            test_wibox = nil
        end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
