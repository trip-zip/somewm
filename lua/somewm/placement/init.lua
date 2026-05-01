---------------------------------------------------------------------------
-- Anchor a target rect inside a parent rect.
--
-- This is the engine-agnostic primitive for layout-shaped placement: given
-- a parent geometry and a target size, return the absolute (x, y, w, h) the
-- target should occupy under one of the nine standard anchor positions.
-- The implementation builds a `somewm.layout.solve` tree with a single
-- workarea leaf inside an `align`-configured row, then reads the leaf's
-- post-solve bounds.
--
-- Non-layout placement concerns (cursor reads, overlap search, try-and-fit,
-- distance compare, memento lookup, signal-driven re-application) live in
-- `awful.placement` and stay there - they were never tree-shaped.
--
--    local placement = require("somewm.placement")
--    local geo = placement.solve {
--        parent        = screen.workarea,
--        target_width  = 400,
--        target_height = 300,
--        anchor        = "centered",
--    }
--    -- geo = { x, y, width, height } in absolute coords
--
-- @module somewm.placement
---------------------------------------------------------------------------

local layout = require("somewm.layout")
local clay_c = _somewm_clay

local placement = {}

---------------------------------------------------------------------------
-- Anchor name -> Clay alignment mapping.
--
-- Mirrors `awful.placement.align_map`'s nine *full-axis* anchors. Partial-
-- axis anchors (`center_vertical`, `center_horizontal`) are not handled
-- here - the caller decides which axis to keep from the original geometry
-- and asks for a single-axis anchor accordingly.
---------------------------------------------------------------------------

local anchor_to_align = {
    top_left     = { x = "left",   y = "top"    },
    top          = { x = "center", y = "top"    },
    top_right    = { x = "right",  y = "top"    },
    left         = { x = "left",   y = "center" },
    centered     = { x = "center", y = "center" },
    right        = { x = "right",  y = "center" },
    bottom_left  = { x = "left",   y = "bottom" },
    bottom       = { x = "center", y = "bottom" },
    bottom_right = { x = "right",  y = "bottom" },
}

--- Solve an anchor placement.
--
-- @tparam table spec
-- @tparam table spec.parent Absolute parent rect: { x, y, width, height }.
-- @tparam number spec.target_width Target rect width in pixels.
-- @tparam number spec.target_height Target rect height in pixels.
-- @tparam string|table spec.anchor One of `top_left`, `top`, `top_right`,
--   `left`, `centered`, `right`, `bottom_left`, `bottom`, `bottom_right`,
--   or a `{x = "left|center|right", y = "top|center|bottom"}` table for
--   custom alignment.
-- @treturn table|nil { x, y, width, height } in absolute coords, or nil
--   when the anchor is unrecognized (partial-axis, etc.) or when Clay is
--   absent (busted unit tests). Callers that get nil fall through to a
--   legacy non-Clay path.
function placement.solve(spec)
    if not clay_c then return nil end
    local align_xy
    if type(spec.anchor) == "string" then
        align_xy = anchor_to_align[spec.anchor]
    elseif type(spec.anchor) == "table" then
        align_xy = spec.anchor
    end
    if not align_xy then return nil end

    local p = spec.parent

    local result = layout.solve {
        source   = "placement",
        width    = p.width,
        height   = p.height,
        offset_x = p.x,
        offset_y = p.y,
        root = layout.row {
            grow  = true,
            align = align_xy,
            layout.measure {
                width  = spec.target_width,
                height = spec.target_height,
            },
        },
    }
    return result and result.workarea
end

return placement

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
