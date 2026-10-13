---------------------------------------------------------------------------
--- Dwindle and spiral layouts
--
-- @author Uli Schlachter &lt;psychon@znc.in&gt;
-- @copyright 2009 Uli Schlachter
-- @copyright 2008 Julien Danjou
--
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local ipairs = ipairs
local client = require("awful.client")

--- The spiral layout layoutbox icon.
-- @beautiful beautiful.layout_spiral
-- @param surface
-- @see gears.surface

--- The dwindle layout layoutbox icon.
-- @beautiful beautiful.layout_dwindle
-- @param surface
-- @see gears.surface

local spiral = {}

-- Membership and dimensionless shares only. The native tree owns every box.
-- A nonzero gap is the existing per-client inset, represented by a real
-- cell so it does not alter the percentage split of its parent region.
local function describe(s, is_spiral)
    local t = s.selected_tag
    local clients = client.tiled(s)
    local n = #clients
    local gap = n == 1 and t.gap_single_client == false and 0 or t.gap
    local function leaf(c)
        local item = {client = c, w = "grow", h = "grow"}
        if gap > 0 then
            return {name = "CELL", dir = "x", pad = {gap, gap, gap, gap},
                w = "grow", h = "grow", children = {item}}
        end
        return item
    end
    local tail = n > 0 and leaf(clients[n]) or nil
    for i = n - 1, 1, -1 do
        local horizontal = i % 2 == 1
        local head = leaf(clients[i])
        local axis = horizontal and "w" or "h"
        head[axis] = {percent = i == 1 and (t.master_width_factor + 0.5) / 2 or 0.5}
        head[axis .. "src"] = i == 1 and "user" or "theme"
        local reverse = is_spiral and (i % 4 == 3 or i % 4 == 0)
        tail = {name = i == 1 and "WORKAREA" or "STACK",
            dir = horizontal and "x" or "y", w = "grow", h = "grow",
            children = reverse and {tail, head} or {head, tail}}
    end
    if n < 2 then
        return {name = "WORKAREA", dir = "x", children = {tail}}
    end
    return tail
end

-- Retain the layout method's public shape; arrange is scheduled through
-- awful.layout and the native declaration producer below.
local function arrange() end

--- Dwindle layout.
-- @clientlayout awful.layout.suit.spiral.dwindle
-- @usebeautiful beautiful.layout_dwindle
spiral.dwindle = {}
spiral.dwindle.name = "dwindle"
spiral.dwindle.arrange = arrange
spiral.dwindle._clay = function(s) return describe(s, false) end

--- Spiral layout.
-- @clientlayout awful.layout.suit.spiral.name
-- @usebeautiful beautiful.layout_spiral
spiral.name = "spiral"
spiral.arrange = arrange
spiral._clay = function(s) return describe(s, true) end

return spiral

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
