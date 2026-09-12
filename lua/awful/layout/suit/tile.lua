---------------------------------------------------------------------------
--- Tiled layouts module for awful
--
-- @author Donald Ephraim Curtis &lt;dcurtis@cs.uiowa.edu&gt;
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2009 Donald Ephraim Curtis
-- @copyright 2008 Julien Danjou
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local client = require("awful.client")
local ipairs = ipairs
local math = math
local capi = {
  mouse = mouse,
  screen = screen,
  mousegrabber = mousegrabber,
}

local tile = {}

--- The tile layout layoutbox icon.
-- @beautiful beautiful.layout_tile
-- @param surface
-- @see gears.surface

--- The tile top layout layoutbox icon.
-- @beautiful beautiful.layout_tiletop
-- @param surface
-- @see gears.surface

--- The tile bottom layout layoutbox icon.
-- @beautiful beautiful.layout_tilebottom
-- @param surface
-- @see gears.surface

--- The tile left layout layoutbox icon.
-- @beautiful beautiful.layout_tileleft
-- @param surface
-- @see gears.surface

--- Jump mouse cursor to the client's corner when resizing it.
-- @field awful.layout.suit.tile.resize_jump_to_corner
tile.resize_jump_to_corner = true

local function mouse_resize_handler(c, _, _, _, orientation)
  local t = c.screen.selected_tag
  local wa = c.screen.workarea -- last frame's solved workarea
  local vertical = orientation == "top" or orientation == "bottom"
  local reverse = orientation == "left" or orientation == "top"
  local axis, extent = vertical and "y" or "x", vertical and "height" or "width"
  local n = #client.tiled(c.screen)
  local gap = n == 1 and t.gap_single_client == false and 0 or t.gap
  local columns = math.min(t.column_count, math.max(0, n-t.master_count))
  local gaps = math.max(0, columns - (t.master_count == 0 and 1 or 0))
  local available = wa[extent] - 2*gap - gaps*gap
  local origin = wa[axis] + gap
  local split = reverse and 1-t.master_width_factor or t.master_width_factor
  local corner = { x = wa.x+wa.width/2, y = wa.y+wa.height/2 }
  corner[axis] = origin + available*split
  local delta = 0
  if tile.resize_jump_to_corner then
    capi.mouse.coords(corner)
  else
    delta = corner[axis] - capi.mouse.coords()[axis]
  end
  local pressed = false
  capi.mousegrabber.run(function(coords)
    if not c.valid then return false end
    for _, down in ipairs(coords.buttons) do
      if down then
        pressed = true
        local share = (coords[axis]+delta-origin)/math.max(1,available)
        if reverse then share=1-share end
        t.master_width_factor = math.min(math.max(share,0.01),0.99)
        return true
      end
    end
    return not pressed
  end, vertical and "sb_v_double_arrow" or "sb_h_double_arrow")
end

-- The layout contributes declarations only. Clay owns every rectangle.
local function describe(s, orientation)
  local t = s.selected_tag
  local clients = {}
  for _, c in ipairs(client.tiled(s)) do
    if not c.ontop and not c.above and not c.below then clients[#clients+1] = c end
  end
  local n = #clients
  local gap = n == 1 and t.gap_single_client == false and 0 or t.gap
  local vertical = orientation == "top" or orientation == "bottom"
  local reverse = orientation == "left" or orientation == "top"
  local axis = vertical and "h" or "w"
  local cross = vertical and "row" or "column"
  local root = { role = "WORKAREA", direction = vertical and "column" or "row",
      gap = gap, padding = gap, children = {} }
  local masters = math.min(t.master_count, n)
  root.center = masters == n and t.master_fill_policy ~= "expand"
  local function run(first, last, share, role)
    if first > last then return end
    local group = { role = role, direction = cross, gap = gap, children = {} }
    if first == last then group.client = clients[first] else
      for i = first, last do group.children[#group.children+1] = { client = clients[i] } end
    end
    group[axis] = share
    root.children[#root.children+1] = group
  end
  local function master()
    run(1, masters, (masters < n or root.center) and t.master_width_factor or nil, "MASTER")
  end
  if not reverse then master() end
  local columns = math.min(t.column_count, n-masters)
  local first = masters+1
  for col = 1, columns do
    local count = math.ceil((n-first+1)/(columns-col+1))
    run(first, first+count-1, nil, "STACK")
    first = first+count
  end
  if reverse then master() end
  return root
end

local function do_tile() end

function tile.skip_gap(nclients, t)
  return nclients == 1 and t.master_fill_policy == "expand"
end

--- The main tile algo, on the right.
-- @param screen The screen number to tile.
-- @clientlayout awful.layout.suit.tile.right
-- @usebeautiful beautiful.layout_tile
tile.right = {}
tile.right.name = "tile"
tile.right.arrange = do_tile
tile.right._clay = function(s) return describe(s, "tile") end
tile.right.skip_gap = tile.skip_gap
function tile.right.mouse_resize_handler(c, corner, x, y)
  return mouse_resize_handler(c, corner, x, y)
end

--- The main tile algo, on the left.
-- @param screen The screen number to tile.
-- @clientlayout awful.layout.suit.tile.left
-- @usebeautiful beautiful.layout_tileleft
tile.left = {}
tile.left.name = "tileleft"
tile.left.skip_gap = tile.skip_gap
tile.left._clay = function(s) return describe(s, "left") end
function tile.left.arrange(p)
  return do_tile(p, "left")
end
function tile.left.mouse_resize_handler(c, corner, x, y)
  return mouse_resize_handler(c, corner, x, y, "left")
end

--- The main tile algo, on the bottom.
-- @param screen The screen number to tile.
-- @clientlayout awful.layout.suit.tile.bottom
-- @usebeautiful beautiful.layout_tilebottom
tile.bottom = {}
tile.bottom.name = "tilebottom"
tile.bottom.skip_gap = tile.skip_gap
tile.bottom._clay = function(s) return describe(s, "bottom") end
function tile.bottom.arrange(p)
  return do_tile(p, "bottom")
end
function tile.bottom.mouse_resize_handler(c, corner, x, y)
  return mouse_resize_handler(c, corner, x, y, "bottom")
end

--- The main tile algo, on the top.
-- @param screen The screen number to tile.
-- @clientlayout awful.layout.suit.tile.top
-- @usebeautiful beautiful.layout_tiletop
tile.top = {}
tile.top.name = "tiletop"
tile.top.skip_gap = tile.skip_gap
tile.top._clay = function(s) return describe(s, "top") end
function tile.top.arrange(p)
  return do_tile(p, "top")
end
function tile.top.mouse_resize_handler(c, corner, x, y)
  return mouse_resize_handler(c, corner, x, y, "top")
end

tile._clay = tile.right._clay
tile.arrange = tile.right.arrange
tile.mouse_resize_handler = tile.right.mouse_resize_handler
tile.name = tile.right.name

return tile

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
