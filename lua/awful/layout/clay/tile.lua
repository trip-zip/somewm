---------------------------------------------------------------------------
-- The four `tile.*` orientations as Clay-native declarative descriptors.
--
-- Body signature is `function(ctx) -> tree`; the tree uses
-- `layout.props.master_width_factor` for sizing and
-- `children = layout.first_n(layout.props.master_count)` for child
-- distribution, so binding and slot resolution happen inside
-- `layout.subtree` (driven by the suit adapter).
--
-- The body still picks the structural variant imperatively (single
-- client, master-only, slave-only, two-pane) because the choice between
-- "row of one column" and "row of two columns" is not naturally
-- expressible as a slot or binding.
--
-- mouse_resize_handler is the tile-family interactive resize logic:
-- the user grabs an edge, the cursor warps to the master/slave split,
-- and dragging adjusts master_width_factor and the per-slave wfact.
-- Lives next to the layout itself (rather than in suit/tile.lua) so
-- adding/removing tile orientations only touches this file.
---------------------------------------------------------------------------

local math   = math
local ipairs = ipairs
local capi = {
    mouse        = mouse,
    mousegrabber = mousegrabber,
}
-- awful.client is required lazily inside mouse_resize_handler to avoid
-- the circular load when awful.client -> awful.mouse.client ->
-- awful.layout.suit.floating -> awful.layout.clay reaches back here.
local layout = require("somewm.layout")

local NAMES = {
    right  = "clay.tile",
    left   = "clay.tileleft",
    top    = "clay.tiletop",
    bottom = "clay.tilebottom",
}

return function(clay)
    local function tile_skip_gap(nclients, t)
        return nclients == 1 and t.master_fill_policy == "expand"
    end

    -- Whether resize warps the mouse cursor to the master/slave split
    -- corner on grab. AwesomeWM exposes this as a layout-level toggle.
    local resize_jump_to_corner = true

    local function mouse_resize_handler(c, _corner, _x, _y, orientation)
        orientation = orientation or "tile"
        local wa = c.screen.workarea
        local t = c.screen.selected_tag
        local useless_gap = t.gap
        local mwfact = t.master_width_factor
        local cursor
        local g = c:geometry()
        local offset = 0
        local corner_coords
        local coordinates_delta = { x = 0, y = 0 }

        if orientation == "tile" then
            cursor = "cross"
            if g.height + useless_gap + 15 > wa.height then
                offset = g.height * 0.5
                cursor = "sb_h_double_arrow"
            elseif g.y + g.height + useless_gap + 15 <= wa.y + wa.height then
                offset = g.height
            end
            corner_coords = { x = wa.x + wa.width * mwfact, y = g.y + offset }
        elseif orientation == "left" then
            cursor = "cross"
            if g.height + useless_gap + 15 >= wa.height then
                offset = g.height * 0.5
                cursor = "sb_h_double_arrow"
            elseif g.y + useless_gap + g.height + 15 <= wa.y + wa.height then
                offset = g.height
            end
            corner_coords = { x = wa.x + wa.width * (1 - mwfact), y = g.y + offset }
        elseif orientation == "bottom" then
            cursor = "cross"
            if g.width + useless_gap + 15 >= wa.width then
                offset = g.width * 0.5
                cursor = "sb_v_double_arrow"
            elseif g.x + g.width + useless_gap + 15 <= wa.x + wa.width then
                offset = g.width
            end
            corner_coords = { y = wa.y + wa.height * mwfact, x = g.x + offset }
        else
            cursor = "cross"
            if g.width + useless_gap + 15 >= wa.width then
                offset = g.width * 0.5
                cursor = "sb_v_double_arrow"
            elseif g.x + g.width + useless_gap + 15 <= wa.x + wa.width then
                offset = g.width
            end
            corner_coords = { y = wa.y + wa.height * (1 - mwfact), x = g.x + offset }
        end

        if resize_jump_to_corner then
            capi.mouse.coords(corner_coords)
        else
            local mouse_coords = capi.mouse.coords()
            coordinates_delta = {
                x = corner_coords.x - mouse_coords.x,
                y = corner_coords.y - mouse_coords.y,
            }
        end

        local prev_coords = {}
        capi.mousegrabber.run(function(coords)
            if not c.valid then return false end

            coords.x = coords.x + coordinates_delta.x
            coords.y = coords.y + coordinates_delta.y
            for _, v in ipairs(coords.buttons) do
                if v then
                    prev_coords = { x = coords.x, y = coords.y }
                    local fact_x = (coords.x - wa.x) / wa.width
                    local fact_y = (coords.y - wa.y) / wa.height
                    local new_mwfact

                    local geom = c:geometry()

                    -- We have to make sure we're not on the last visible
                    -- client where we have to use different settings.
                    local wfact, wfact_x, wfact_y
                    if (geom.y + geom.height + useless_gap + 15) > (wa.y + wa.height) then
                        wfact_y = (geom.y + geom.height - coords.y) / wa.height
                    else
                        wfact_y = (coords.y - geom.y) / wa.height
                    end

                    if (geom.x + geom.width + useless_gap + 15) > (wa.x + wa.width) then
                        wfact_x = (geom.x + geom.width - coords.x) / wa.width
                    else
                        wfact_x = (coords.x - geom.x) / wa.width
                    end

                    if orientation == "tile" then
                        new_mwfact = fact_x
                        wfact      = wfact_y
                    elseif orientation == "left" then
                        new_mwfact = 1 - fact_x
                        wfact      = wfact_y
                    elseif orientation == "bottom" then
                        new_mwfact = fact_y
                        wfact      = wfact_x
                    else
                        new_mwfact = 1 - fact_y
                        wfact      = wfact_x
                    end

                    c.screen.selected_tag.master_width_factor =
                        math.min(math.max(new_mwfact, 0.01), 0.99)
                    require("awful.client").setwfact(
                        math.min(math.max(wfact, 0.01), 0.99), c)
                    return true
                end
            end
            return (prev_coords.x == coords.x) and (prev_coords.y == coords.y)
        end, cursor)
    end

    local function build(orientation)
        local is_horiz     = (orientation == "right" or orientation == "left")
        local outer        = is_horiz and layout.row or layout.column
        local inner        = is_horiz and layout.column or layout.row
        local size_key     = is_horiz and "width" or "height"
        local master_first = (orientation == "right" or orientation == "top")

        return clay.layout {
            name           = NAMES[orientation],
            body_signature = "context",
            skip_gap       = tile_skip_gap,
            body           = function(ctx)
                local clients = ctx.children
                local nmaster = math.min(ctx.props.master_count, #clients)

                if #clients == 1 then
                    return outer { layout.client(clients[1]) }
                end

                -- Master-only or master-saturates-all: collapse to a
                -- single inner pane carrying every client.
                if nmaster == 0 or nmaster >= #clients then
                    return inner { children = layout.all() }
                end

                local master_pane = inner {
                    [size_key] = layout.percent(
                        layout.props.master_width_factor * 100),
                    children   = layout.first_n(layout.props.master_count),
                }
                local slave_pane = inner {
                    grow     = true,
                    children = layout.rest_after(layout.props.master_count),
                }

                if master_first then
                    return outer { master_pane, slave_pane }
                end
                return outer { slave_pane, master_pane }
            end,
        }
    end

    clay.tile        = build("right")
    clay.tile.left   = build("left")
    clay.tile.top    = build("top")
    clay.tile.bottom = build("bottom")

    -- right is the canonical tile; expose it as both clay.tile and
    -- clay.tile.right (same table identity) so both surfaces work.
    clay.tile.right = clay.tile

    clay.tile.resize_jump_to_corner = resize_jump_to_corner
    function clay.tile.mouse_resize_handler(c, corner, x, y)
        return mouse_resize_handler(c, corner, x, y)
    end
    function clay.tile.left.mouse_resize_handler(c, corner, x, y)
        return mouse_resize_handler(c, corner, x, y, "left")
    end
    function clay.tile.bottom.mouse_resize_handler(c, corner, x, y)
        return mouse_resize_handler(c, corner, x, y, "bottom")
    end
    function clay.tile.top.mouse_resize_handler(c, corner, x, y)
        return mouse_resize_handler(c, corner, x, y, "top")
    end
end

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
