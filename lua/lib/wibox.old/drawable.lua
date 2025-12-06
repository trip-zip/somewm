---------------------------------------------------------------------------
--- Drawable rendering coordinator.
---
--- This module coordinates widget rendering by managing the hierarchy,
--- handling backgrounds, and calling C primitives for buffer operations.
---
--- Layer 2 (Lua Libraries): Implements rendering policy
--- Uses Layer 1 (C Primitives): get_surface(), update()
---
--- @module wibox.drawable
---------------------------------------------------------------------------

local hierarchy = require("wibox.hierarchy")
local base = require("wibox.widget.base")
local gcolor = require("gears.color")
local beautiful = require("beautiful")
local lgi = require("lgi")
local cairo = lgi.cairo

local drawable = {}
local drawable_mt = {}
drawable_mt.__index = drawable_mt

--- Create a new drawable
--
-- @tparam table c_wibox C wibox object (with get_surface/update methods)
-- @tparam number width Drawable width
-- @tparam number height Drawable height
-- @treturn table New drawable
-- @staticfct wibox.drawable.new
function drawable.new(c_wibox, width, height)
  local self = setmetatable({}, drawable_mt)

  self._wibox = c_wibox
  self._width = width or 0
  self._height = height or 0
  self._widget = nil
  self._hierarchy = nil
  self._bg = nil
  self._fg = nil
  self._need_update = true

  return self
end

--- Get widget context
--
-- Creates the context table passed to widgets
--
-- @treturn table Widget context
local function get_widget_context(self)
  -- Get screen (simplified - assume screen 1 for now)
  local screen = 1

  local context = {
    screen = screen,
    dpi = beautiful.xresources.dpi or 96,
    drawable = self,
  }

  return context
end

--- Redraw the drawable
--
-- This is the main rendering function.
-- Coordinates: background → hierarchy → buffer sync
--
-- @staticfct
function drawable_mt:_redraw()
  print("[drawable] _redraw() called")
  if not self._wibox then
    print("[drawable] No wibox")
    return
  end

  -- Get Cairo surface from C primitive
  local surface_ptr = _wibox.get_surface(self._wibox)
  if not surface_ptr then
    print("[drawable] Failed to get surface from C")
    return
  end
  print("[drawable] Got surface_ptr")

  -- Wrap C pointer with LGI Cairo surface
  local surface = cairo.Surface(surface_ptr, false) -- false = don't manage lifecycle
  if not surface then
    print("[drawable] Failed to wrap surface")
    return
  end

  -- Create Cairo context
  local cr = cairo.Context.create(surface)

  -- Clear to transparent
  cr:save()
  cr:set_operator("CLEAR")
  cr:paint()
  cr:restore()

  -- Draw background if specified
  if self._bg then
    local pattern = gcolor(self._bg)
    if pattern then
      cr:set_source(pattern)
      cr:paint()
    end
  end

  -- Get widget context
  local context = get_widget_context(self)

  -- Create or update hierarchy
  if self._widget then
    print("[drawable] Have widget, creating/updating hierarchy")
    if not self._hierarchy then
      print("[drawable] Creating new hierarchy")
      self._hierarchy = hierarchy.new(context, self._widget, self._width, self._height)
    end

    -- Update layout
    print("[drawable] Updating hierarchy layout")
    self._hierarchy:update(context, self._widget, self._width, self._height)

    -- Draw hierarchy
    print("[drawable] Drawing hierarchy")
    self._hierarchy:draw(context, cr)
    print("[drawable] Hierarchy draw complete")
  else
    print("[drawable] No widget set!")
  end

  -- Flush Cairo operations
  surface:flush()

  -- Sync buffer to screen via C primitive
  _wibox.update(self._wibox)

  self._need_update = false
end

--- Set background color
--
-- @tparam string|table bg Background color specification
-- @staticfct
function drawable_mt:set_bg(bg)
  if self._bg ~= bg then
    self._bg = bg
    self._need_update = true
    self:_redraw()
  end
end

--- Get background color
--
-- @treturn string|table Background color
-- @staticfct
function drawable_mt:get_bg()
  return self._bg
end

--- Set foreground color
--
-- @tparam string|table fg Foreground color specification
-- @staticfct
function drawable_mt:set_fg(fg)
  if self._fg ~= fg then
    self._fg = fg
    -- Foreground is stored for widget context, no immediate redraw needed
  end
end

--- Get foreground color
--
-- @treturn string|table Foreground color
-- @staticfct
function drawable_mt:get_fg()
  return self._fg
end

--- Set root widget
--
-- @tparam table widget Widget to display
-- @staticfct
function drawable_mt:set_widget(widget)
  if self._widget ~= widget then
    self._widget = widget
    self._hierarchy = nil -- Force hierarchy recreation
    self._need_update = true

    -- Connect to widget signals
    if widget and widget.connect_signal then
      widget:connect_signal("widget::layout_changed", function()
        self._hierarchy = nil
        self:_redraw()
      end)

      widget:connect_signal("widget::redraw_needed", function()
        self:_redraw()
      end)
    end

    self:_redraw()
  end
end

--- Get root widget
--
-- @treturn table Root widget
-- @staticfct
function drawable_mt:get_widget()
  return self._widget
end

--- Set drawable size
--
-- @tparam number width Width
-- @tparam number height Height
-- @staticfct
function drawable_mt:set_size(width, height)
  if self._width ~= width or self._height ~= height then
    self._width = width
    self._height = height
    self._hierarchy = nil -- Force recreation with new size
    self._need_update = true
    self:_redraw()
  end
end

--- Get drawable size
--
-- @treturn number width
-- @treturn number height
-- @staticfct
function drawable_mt:get_size()
  return self._width, self._height
end

return drawable

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
