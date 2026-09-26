---------------------------------------------------------------------------
-- Test: chrome drawn across an output edge is still clickable there
--
-- A wibox declares on the output its top-left sits on, and the node it
-- reconciles into is free to overhang onto the neighbor. The input backmap
-- has to find the band that drew the node, not the band the pointer happens
-- to be over, or every click on the overhanging half falls through.
--
-- mouse.object_under_pointer() runs the real xytonode() path, so this reads
-- the backmap rather than a test hook.
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")

if not awesome._test_add_output then
    io.stderr:write("SKIP: awesome._test_add_output not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local initial_count = screen.count()
local left, right, w
local probe_x, probe_y

local steps = {
    function()
        assert(awesome._test_add_output(800, 600), "_test_add_output failed")
        return true
    end,

    function()
        return screen.count() > initial_count or nil
    end,

    -- wlr_output_layout_add_auto() lays outputs out left to right, but read
    -- the geometry rather than assume which screen ended up where.
    function()
        for s in screen do
            local g = s.geometry
            if not left or g.x < left.geometry.x then left = s end
            if not right or g.x > right.geometry.x then right = s end
        end
        assert(left ~= right, "the two outputs share an x origin")
        assert(right.geometry.x == left.geometry.x + left.geometry.width,
            "outputs are not adjacent: cannot straddle the edge")
        return true
    end,

    -- 40px on the left output, 80px over the right one. The top-left stays
    -- on the left output, so that is the screen it is assigned and the band
    -- that declares it.
    function()
        w = wibox({
            x = right.geometry.x - 40,
            y = left.geometry.y + 10,
            width = 120, height = 30,
            bg = "#00ff00", visible = true,
        })
        w:setup({ widget = wibox.widget.textbox, text = "edge" })
        assert(w.screen == left, "wibox was not assigned to the left output")
        probe_x = right.geometry.x + 20
        probe_y = left.geometry.y + 25
        return true
    end,

    -- A drawin only draws once its content entry holds pixels.
    function()
        for _, o in ipairs(awesome._test_declare_order(left)) do
            if o == w.drawin then
                return true
            end
        end
    end,

    -- capi.mouse.coords() warps; assigning mouse.coords replaces the
    -- function with a table and warps nothing.
    function()
        local c = mouse.coords({ x = probe_x, y = probe_y })
        assert(c.x == probe_x and c.y == probe_y, "pointer did not warp")
        return true
    end,

    function()
        local obj = mouse.object_under_pointer()
        assert(obj == w.drawin, string.format(
            "nothing found under (%d,%d), the part of the wibox on screen %d",
            probe_x, probe_y, right.index))
        io.stderr:write("[PASS] overhanging wibox is hit on the neighbor\n")
        return true
    end,

    function()
        w.visible = false
        w = nil
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
