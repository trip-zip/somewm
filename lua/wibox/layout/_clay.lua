---------------------------------------------------------------------------
-- Internal Clay backend for wibox layouts.
--
-- Provides shared helpers for building Clay trees and converting results
-- to standard placement objects. Each wibox.layout.* module calls these
-- to compute positions via Clay instead of bespoke geometry math.
--
-- @module wibox.layout._clay
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local clay_c = _somewm_clay

local _clay = {}

--- Run a Clay layout pass for widgets and return placement objects.
-- @tparam number width Available width
-- @tparam number height Available height
-- @tparam function tree_builder Function that builds the Clay tree
--   using clay_c.open_container/widget_element/close_container calls
-- @treturn table Array of placement objects (base.place_widget_at results)
function _clay.compute(width, height, tree_builder)
    clay_c.begin_layout(nil, width, height)
    tree_builder()
    local results = clay_c.end_layout_to_lua()

    local placements = {}
    for _, r in ipairs(results) do
        placements[#placements + 1] = base.place_widget_at(
            r.widget,
            math.floor(r.x),
            math.floor(r.y),
            math.floor(r.width),
            math.floor(r.height)
        )
    end
    return placements
end

--- Convert pre-computed positions to placement objects.
-- For layouts where positions are already known (stack, manual) but we
-- still want the output to go through the Clay pipeline format.
-- @tparam table entries Array of {widget, x, y, width, height}
-- @treturn table Array of placement objects
function _clay.from_positions(entries)
    local placements = {}
    for _, e in ipairs(entries) do
        placements[#placements + 1] = base.place_widget_at(
            e.widget,
            math.floor(e.x),
            math.floor(e.y),
            math.floor(e.width),
            math.floor(e.height)
        )
    end
    return placements
end

return _clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
