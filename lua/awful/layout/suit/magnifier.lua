---------------------------------------------------------------------------
--- Magnifier layout module for awful
--
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2008 Julien Danjou
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local ipairs = ipairs
local math = math
local aclient = require("awful.client")
local capi = {
  client = client,
  screen = screen,
  mouse = mouse,
  mousegrabber = mousegrabber,
}

--- The magnifier layout layoutbox icon.
-- @beautiful beautiful.layout_magnifier
-- @param surface
-- @see gears.surface

local magnifier = {}

function magnifier.mouse_resize_handler(c, corner, x, y)
  capi.mouse.coords({ x = x, y = y })

  local wa = c.screen.workarea
  local center_x = wa.x + wa.width / 2
  local center_y = wa.y + wa.height / 2
  local maxdist_pow = (wa.width ^ 2 + wa.height ^ 2) / 4

  local prev_coords = {}
  capi.mousegrabber.run(function(position)
    if not c.valid then
      return false
    end

    for _, v in ipairs(position.buttons) do
      if v then
        prev_coords = { x = position.x, y = position.y }
        local dx = center_x - position.x
        local dy = center_y - position.y
        local dist = dx ^ 2 + dy ^ 2

        -- New master width factor
        local mwfact = dist / maxdist_pow
        c.screen.selected_tag.master_width_factor = math.min(math.max(0.01, mwfact), 0.99)
        return true
      end
    end
    return prev_coords.x == position.x and prev_coords.y == position.y
  end, corner .. "_corner")
end

-- Public method shape is retained; awful.layout schedules the native tree.
function magnifier.arrange() end

function magnifier._clay(s)
  local t = s.selected_tag
  local clients, focused = {}, nil
  for _, c in ipairs(aclient.tiled(s)) do
    if not c.ontop and not c.above and not c.below then
      clients[#clients + 1] = c
      if c == capi.client.focus then focused = #clients end
    end
  end
  local n = #clients
  local children, floating = {}, {}
  if n > 0 then
    focused = focused or 1
    local gap = n == 1 and t.gap_single_client == false and 0 or t.gap
    local share = n > 1 and math.sqrt(t.master_width_factor) or nil
    floating[clients[focused]] = {attach_to = "workarea", center = true,
      w = share, h = share, padding = gap}
    -- Background clients start after the focused client and wrap around.
    for offset = 1, n - 1 do
      local c = clients[(focused + offset - 1) % n + 1]
      local item = {client = c}
      if gap > 0 then
        item = {role = "CELL", direction = "row", padding = gap,
          children = {item}}
      end
      children[#children + 1] = item
    end
  end
  return {role = "WORKAREA", direction = "column", children = children,
    floating = floating}
end

--- The magnifier layout.
-- @clientlayout awful.layout.suit.magnifier
-- @usebeautiful beautiful.layout_magnifier

magnifier.name = "magnifier"

-- This layout handles the currently focused client specially and needs to be
-- called again when the focus changes.
magnifier.need_focus_update = true

return magnifier

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
