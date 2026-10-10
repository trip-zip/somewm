---------------------------------------------------------------------------
--- Maximized and fullscreen layouts module for awful
--
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2008 Julien Danjou
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local ipairs = ipairs
local capi = { client = client }
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

-- Each tiled client floats over the workarea, or the output, bottom first.
local function describe(s, fullscreen)
  local gap = s.selected_tag.gap_single_client == false and 0 or s.selected_tag.gap
  local tiled, children = {}, {}
  for _, c in ipairs(client.tiled(s)) do tiled[c] = true end
  local stacked = capi.client.get(s, true)
  for i = #stacked, 1, -1 do
    if tiled[stacked[i]] then
      children[#children + 1] = {client = stacked[i], float = true, w = "grow", h = "grow",
        pad = {gap, gap, gap, gap}, _attach = fullscreen and "output" or nil}
    end
  end
  return {name = "WORKAREA", dir = "x", children = children}
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
