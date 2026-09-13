---------------------------------------------------------------------------
--- Fair layouts module for awful.
--
-- @author Josh Komoroske
-- @copyright 2012 Josh Komoroske
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local ipairs = ipairs
local math = math
local client = require("awful.client")

--- The fairh layout layoutbox icon.
-- @beautiful beautiful.layout_fairh
-- @param surface
-- @see gears.surface

--- The fairv layout layoutbox icon.
-- @beautiful beautiful.layout_fairv
-- @param surface
-- @see gears.surface

local fair = {}

local function describe(s, horizontal)
  local t = s.selected_tag
  local clients = {}
  for _, c in ipairs(client.tiled(s)) do
    if not c.ontop and not c.above and not c.below then
      clients[#clients + 1] = c
    end
  end
  local n = #clients
  local rows = n == 2 and 1 or math.ceil(math.sqrt(n))
  local columns = n > 0 and math.ceil(n / rows) or 0
  local gap = n == 1 and t.gap_single_client == false and 0 or t.gap
  local groups = {}
  for column = 1, columns do
    local items = {}
    for i = (column - 1) * rows + 1, math.min(column * rows, n) do
      local item = {client = clients[i], contain_size = true}
      if gap > 0 then
        item = {role = "CELL", direction = "row", padding = gap,
          children = {item}}
      end
      items[#items + 1] = item
    end
    groups[#groups + 1] = #items == 1 and items[1] or {
      role = "ROW", direction = horizontal and "row" or "column",
      ceil_grow = true, children = items}
  end
  return {role = "WORKAREA", direction = horizontal and "column" or "row",
    ceil_grow = true, children = groups}
end

-- Preserve public method shape; awful.layout schedules native declarations.
local function arrange() end

-- Horizontal fair layout.
-- @param screen The screen to arrange.
fair.horizontal = {}
fair.horizontal.name = "fairh"

fair.horizontal.arrange = arrange
fair.horizontal._clay = function(s) return describe(s, true) end

-- Vertical fair layout.
-- @param screen The screen to arrange.
fair.name = "fairv"
fair.arrange = arrange
fair._clay = function(s) return describe(s, false) end

--- The fair layout.
-- Try to give all clients the same size.
-- @clientlayout awful.layout.suit.fair
-- @usebeautiful beautiful.layout_fairv

--- The horizontal fair layout.
-- Try to give all clients the same size.
-- @clientlayout awful.layout.suit.fair.horizontal
-- @usebeautiful beautiful.layout_fairh

return fair

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
