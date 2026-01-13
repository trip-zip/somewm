---------------------------------------------------------------------------
-- Test: Drawin borders follow shape_bounding
--
-- Regression test for issue #172: borders should be clipped to match
-- the shape_bounding mask, not remain rectangular.
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")
local gears = require("gears")
local cairo = require("lgi").cairo
local ffi = require("ffi")

local BOX_X, BOX_Y = 50, 50
local BOX_W, BOX_H = 200, 100
local BORDER_W = 4
local CORNER_RADIUS = 20

local test_wibox = nil

-- Get pixel from screenshot
local function get_pixel(surface, x, y)
    surface:flush()
    local data = surface:get_data()
    local stride = surface:get_stride()
    local width = surface:get_width()
    local height = surface:get_height()

    if x < 0 or x >= width or y < 0 or y >= height then
        return nil
    end

    local ptr = ffi.cast('uint8_t*', data)
    local offset = y * stride + x * 4
    return {
        b = ptr[offset + 0],
        g = ptr[offset + 1],
        r = ptr[offset + 2],
        a = ptr[offset + 3]
    }
end

local steps = {
    -- Step 1: Create wibox with shape and border
    function()
        test_wibox = wibox {
            x = BOX_X, y = BOX_Y,
            width = BOX_W, height = BOX_H,
            visible = true,
            bg = "#ff0000",           -- Red content
            border_width = BORDER_W,
            border_color = "#00ff00", -- Green border
            ontop = true,
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, CORNER_RADIUS)
            end,
        }
        io.stderr:write("[TEST] Created wibox with rounded shape and border\n")
        return true
    end,

    -- Step 2: Wait for rendering
    function(count)
        if count >= 3 then return true end
    end,

    -- Step 3: Check that corner pixels are transparent (not green border)
    function()
        local surface = root.content(true)
        surface = cairo.Surface(surface, true)

        -- Top-left corner of the border area (outside content, inside border rect)
        -- If border is shaped, this should be transparent
        -- If border is rectangular, this will be green
        local corner_x = BOX_X - BORDER_W + 2
        local corner_y = BOX_Y - BORDER_W + 2

        local pixel = get_pixel(surface, corner_x, corner_y)

        if not pixel then
            error("Could not read pixel at corner")
        end

        io.stderr:write(string.format(
            "[TEST] Corner pixel at (%d,%d): r=%d g=%d b=%d a=%d\n",
            corner_x, corner_y, pixel.r, pixel.g, pixel.b, pixel.a
        ))

        -- Corner should be transparent (background), not green (border)
        -- If alpha > 10 AND green channel is high, border is rectangular (bug)
        if pixel.a > 10 and pixel.g > 200 then
            error(string.format(
                "Border corner is NOT shaped: pixel at (%d,%d) is green (r=%d,g=%d,b=%d,a=%d). " ..
                "Expected transparent (shaped border follows rounded corners).",
                corner_x, corner_y, pixel.r, pixel.g, pixel.b, pixel.a
            ))
        end

        io.stderr:write("[PASS] Border corner is transparent (shaped correctly)\n")
        return true
    end,

    -- Step 4: Verify border IS visible on the flat edges (middle of top edge)
    function()
        local surface = root.content(true)
        surface = cairo.Surface(surface, true)

        -- Middle of top border (should be green)
        local edge_x = BOX_X + BOX_W / 2
        local edge_y = BOX_Y - BORDER_W / 2

        local pixel = get_pixel(surface, edge_x, edge_y)

        if not pixel then
            error("Could not read pixel at edge")
        end

        io.stderr:write(string.format(
            "[TEST] Edge pixel at (%d,%d): r=%d g=%d b=%d a=%d\n",
            edge_x, edge_y, pixel.r, pixel.g, pixel.b, pixel.a
        ))

        -- Edge should be green (border visible)
        if pixel.g < 200 or pixel.a < 200 then
            error(string.format(
                "Border edge is missing: pixel at (%d,%d) is not green (r=%d,g=%d,b=%d,a=%d).",
                edge_x, edge_y, pixel.r, pixel.g, pixel.b, pixel.a
            ))
        end

        io.stderr:write("[PASS] Border edge is visible (green)\n")
        return true
    end,

    -- Step 5: Check all four corners are transparent
    function()
        local surface = root.content(true)
        surface = cairo.Surface(surface, true)

        local corners = {
            { x = BOX_X - BORDER_W + 2, y = BOX_Y - BORDER_W + 2, name = "top-left" },
            { x = BOX_X + BOX_W + BORDER_W - 3, y = BOX_Y - BORDER_W + 2, name = "top-right" },
            { x = BOX_X - BORDER_W + 2, y = BOX_Y + BOX_H + BORDER_W - 3, name = "bottom-left" },
            { x = BOX_X + BOX_W + BORDER_W - 3, y = BOX_Y + BOX_H + BORDER_W - 3, name = "bottom-right" },
        }

        for _, corner in ipairs(corners) do
            local pixel = get_pixel(surface, corner.x, corner.y)
            if pixel and pixel.a > 10 and pixel.g > 200 then
                error(string.format(
                    "%s border corner is NOT shaped: pixel at (%d,%d) is green (r=%d,g=%d,b=%d,a=%d).",
                    corner.name, corner.x, corner.y, pixel.r, pixel.g, pixel.b, pixel.a
                ))
            end
            io.stderr:write(string.format("[PASS] %s corner is transparent\n", corner.name))
        end

        return true
    end,

    -- Step 6: Cleanup
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

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
