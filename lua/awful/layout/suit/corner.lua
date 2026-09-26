---------------------------------------------------------------------------
-- Corner layout.
-- Display master client in a corner of the screen, and slaves in one
-- column and one row around the master.
-- @module awful.layout
-- @author Alexis Brenon &lt;brenon.alexis+awesomewm@gmail.com&gt;
-- @copyright 2015 Alexis Brenon

-- Grab environment we need
local ipairs = ipairs
local client = require("awful.client")

--- The cornernw layout layoutbox icon.
-- @beautiful beautiful.layout_cornernw
-- @param surface
-- @see gears.surface

--- The cornerne layout layoutbox icon.
-- @beautiful beautiful.layout_cornerne
-- @param surface
-- @see gears.surface

--- The cornersw layout layoutbox icon.
-- @beautiful beautiful.layout_cornersw
-- @param surface
-- @see gears.surface

--- The cornerse layout layoutbox icon.
-- @beautiful beautiful.layout_cornerse
-- @param surface
-- @see gears.surface

-- Membership and native composition only. The original alternating column
-- and row membership remains; each group now allocates its actual children.
local function describe(s, orientation)
  local t = s.selected_tag
  local clients = {}
  for _, c in ipairs(client.tiled(s)) do
    if not c.ontop and not c.above and not c.below then
      clients[#clients + 1] = c
    end
  end
  local n = #clients
  local row_privileged = t.master_count % 2 == 0
  local factor = t.master_width_factor
  local west, north = orientation:sub(2,2) == "W", orientation:sub(1,1) == "N"
  local gap = (t.gap_single_client ~= false
      or not (n == 1 and t.master_fill_policy == "expand")) and t.gap or 0
  local function leaf(c)
    local item = {client = c, w = 1, h = 1}
    if gap > 0 then
      item = {role = "CELL", direction = "row", w = 1, h = 1,
        padding = gap, children = {item}}
    end
    return item
  end
  local function group(direction, items)
    if #items == 1 then return items[1] end
    local axis = direction == "row" and "w" or "h"
    for _, item in ipairs(items) do item[axis] = 1 / #items end
    return {role = "STACK", direction = direction, w = 1, h = 1, children = items}
  end
  local function split(direction, first, second, forward)
    local axis = direction == "row" and "w" or "h"
    first[axis], second[axis] = factor, 1 - factor
    return {role = "STACK", direction = direction, w = 1, h = 1,
      children = forward and {first, second} or {second, first}}
  end
  local root = {role = "WORKAREA", direction = row_privileged and "column" or "row", children = {}}
  if n == 0 then return root end
  local master = leaf(clients[1])
  local axis = row_privileged and "h" or "w"
  if n == 1 then
    root.center = t.master_fill_policy ~= "expand"
    if root.center then master[axis] = factor end
    root.children = {master}
  elseif n == 2 then
    -- With only a slave, split along the privileged axis; there is no
    -- opposite group whose nonexistent count could divide a rectangle.
    root.children = split(root.direction, master, leaf(clients[2]),
      row_privileged and north or not row_privileged and west).children
  else
    local column, row = {}, {}
    for i = 2, n do
      local items = i % 2 == 0 and column or row
      items[#items + 1] = leaf(clients[i])
    end
    if row_privileged then
      local band = split("row", master, group("column", column), west)
      root.children = split("column", band, group("row", row), north).children
    else
      local band = split("column", master, group("row", row), north)
      root.children = split("row", band, group("column", column), west).children
    end
  end
  return root
end

-- Public method shape remains; awful.layout schedules the native producer.
local function arrange() end

local corner = {}
corner.row_privileged = false

function corner.skip_gap(nclients, t)
  return nclients == 1 and t.master_fill_policy == "expand"
end

--- Corner layout.
-- Display master client in a corner of the screen, and slaves in one
-- column and one row around the master.
-- @clientlayout awful.layout.suit.corner.nw
-- @usebeautiful beautiful.layout_cornernw
corner.nw = {
  name = "cornernw",
  arrange = arrange,
  _clay = function(s) return describe(s, "NW") end,
  skip_gap = corner.skip_gap,
}

--- Corner layout.
-- Display master client in a corner of the screen, and slaves in one
-- column and one row around the master.
-- @clientlayout awful.layout.suit.corner.ne
-- @usebeautiful beautiful.layout_cornerne
corner.ne = {
  name = "cornerne",
  arrange = arrange,
  _clay = function(s) return describe(s, "NE") end,
  skip_gap = corner.skip_gap,
}

--- Corner layout.
-- Display master client in a corner of the screen, and slaves in one
-- column and one row around the master.
-- @clientlayout awful.layout.suit.corner.sw
-- @usebeautiful beautiful.layout_cornersw
corner.sw = {
  name = "cornersw",
  arrange = arrange,
  _clay = function(s) return describe(s, "SW") end,
  skip_gap = corner.skip_gap,
}

--- Corner layout.
-- Display master client in a corner of the screen, and slaves in one
-- column and one row around the master.
-- @clientlayout awful.layout.suit.corner.se
-- @usebeautiful beautiful.layout_cornerse
corner.se = {
  name = "cornerse",
  arrange = arrange,
  _clay = function(s) return describe(s, "SE") end,
  skip_gap = corner.skip_gap,
}

return corner

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
