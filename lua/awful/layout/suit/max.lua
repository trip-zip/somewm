---------------------------------------------------------------------------
--- Maximized and fullscreen layouts module for awful
--
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2008 Julien Danjou
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local ipairs = ipairs
local client = require("awful.client")

local max = {}

--- The max layout layoutbox icon.
-- @beautiful beautiful.layout_max
-- @param surface
-- @see gears.surface

--- The fullscreen layout layoutbox icon.
-- @beautiful beautiful.layout_fullscreen
-- @param surface
-- @see gears.surface

local function describe(s, fullscreen)
  local floating = {}
  local gap = s.selected_tag.gap_single_client == false and 0 or s.selected_tag.gap
  for _, c in ipairs(client.tiled(s)) do
    if not c.ontop and not c.above and not c.below then
      floating[c] = {attach_to = fullscreen and "output" or "workarea", padding = gap}
    end
  end
  return {role = "WORKAREA", direction = "row", children = {}, floating = floating}
end

-- Public method shape is retained; awful.layout schedules native declarations.
local function arrange() end

--- Maximized layout.
-- @clientlayout awful.layout.suit.max
-- @usebeautiful beautiful.layout_max
max.name = "max"
max.arrange = arrange
max._clay = function(s) return describe(s, false) end
function max.skip_gap(nclients, t) -- luacheck: no unused args
  return true
end

--- Fullscreen layout.
-- @clientlayout awful.layout.suit.max.fullscreen
-- @usebeautiful beautiful.layout_fullscreen
max.fullscreen = {}
max.fullscreen.name = "fullscreen"
max.fullscreen.skip_gap = max.skip_gap
max.fullscreen.arrange = arrange
max.fullscreen._clay = function(s) return describe(s, true) end

return max

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
