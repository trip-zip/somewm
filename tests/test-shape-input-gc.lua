---------------------------------------------------------------------------
-- Test: shape_input surface survives after cairo_surface_finish()
--
-- Regression test for issue #174: SIGSEGV when shape_input surface is
-- finished by Lua (via lgi GC) while C code still holds a reference.
--
-- The bug: luaA_drawin_set_shape_input() only takes a cairo reference,
-- not a deep copy. When lgi calls cairo_surface_finish(), the backing
-- data is freed even though C holds a reference, causing use-after-free.
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")
local gears = require("gears")
local cairo = require("lgi").cairo

local test_wibox = nil
local BOX_X, BOX_Y = 100, 100
local BOX_W, BOX_H = 300, 150

local steps = {
    -- Step 1: Create wibox and set shape_input, then finish the surface
    function()
        test_wibox = wibox {
            x = BOX_X, y = BOX_Y,
            width = BOX_W, height = BOX_H,
            visible = true,
            bg = "#ff5500",
            ontop = true,
        }

        -- Set shape_input and immediately finish the surface
        -- This simulates what happens when lgi GC's the surface
        local function set_and_finish_shape()
            local img = cairo.ImageSurface.create(cairo.Format.A1, BOX_W, BOX_H)
            local cr = cairo.Context.create(img)
            gears.shape.rounded_rect(cr, BOX_W, BOX_H, 30)
            cr:fill()

            -- Pass raw surface to C
            test_wibox.drawin.shape_input = img._native

            -- Finish the surface - this frees backing data
            -- (simulates lgi GC calling cairo_surface_finish)
            img:finish()
        end
        set_and_finish_shape()

        -- Force GC and allocate memory to overwrite freed data
        collectgarbage("collect")
        collectgarbage("collect")

        -- Aggressively allocate and free memory to corrupt freed surface data
        for round = 1, 10 do
            local junk = {}
            for i = 1, 1000 do
                junk[i] = string.rep(string.char(round), 1000)
            end
            junk = nil
            collectgarbage("collect")
        end

        -- Also create and destroy some cairo surfaces to reuse cairo's memory pool
        for i = 1, 20 do
            local temp = cairo.ImageSurface.create(cairo.Format.A1, BOX_W, BOX_H)
            temp:finish()
        end
        collectgarbage("collect")

        io.stderr:write("[TEST] shape_input set and surface finished\n")
        return true
    end,

    -- Step 2: Wait a frame for any pending operations
    function(count)
        if count >= 2 then
            return true
        end
    end,

    -- Step 3: capi.mouse.coords() only warps; object_under_pointer() is what
    -- runs xytonode() and with it drawin_accepts_input_at(), the read of the
    -- finished surface that used to crash. Assigning mouse.coords instead
    -- warps nothing: awful.mouse has no set_coords, so the assignment lands
    -- in its props table and shadows this function.
    function()
        mouse.coords({ x = BOX_X + BOX_W / 2, y = BOX_Y + BOX_H / 2 })
        assert(mouse.object_under_pointer() == test_wibox.drawin,
            "center of the shape did not accept input")
        io.stderr:write("[TEST] center of the wibox accepts input\n")
        return true
    end,

    -- Step 4: The corners fall outside the rounded rect, so the mask reads 0
    -- there. A mask whose backing data was freed and overwritten answers
    -- these wrong (or crashes) instead.
    function()
        for _, corner in ipairs({
            { BOX_X + 5, BOX_Y + 5 },
            { BOX_X + BOX_W - 5, BOX_Y + 5 },
            { BOX_X + BOX_W - 5, BOX_Y + BOX_H - 5 },
            { BOX_X + 5, BOX_Y + BOX_H - 5 },
        }) do
            mouse.coords({ x = corner[1], y = corner[2] })
            assert(mouse.object_under_pointer() ~= test_wibox.drawin,
                string.format("corner (%d,%d) accepted input", corner[1],
                    corner[2]))
        end
        io.stderr:write("[TEST] all four corners pass input through\n")
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

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
