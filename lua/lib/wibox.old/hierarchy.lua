---------------------------------------------------------------------------
--- Widget hierarchy management.
---
--- This module manages the widget tree, handles transformations,
--- and coordinates drawing.
---
--- @module wibox.hierarchy
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local lgi = require("lgi")
local cairo = lgi.cairo

local hierarchy = {}

---------------------------------------------------------------------------
-- Hierarchy Object
---------------------------------------------------------------------------

local hierarchy_mt = {}
hierarchy_mt.__index = hierarchy_mt

--- Create a new hierarchy
--
-- @tparam table context Widget context
-- @tparam table widget Root widget
-- @tparam number width Available width
-- @tparam number height Available height
-- @treturn table New hierarchy
-- @staticfct wibox.hierarchy.new
function hierarchy.new(context, widget, width, height)
  local self = setmetatable({}, hierarchy_mt)

  self._widget = widget
  self._context = context
  self._width = width
  self._height = height
  self._children = {}
  self._matrix = nil -- Transformation matrix (Cairo matrix)
  self._draw_extents = { x = 0, y = 0, width = width, height = height }

  return self
end

--- Update the hierarchy
--
-- Relayouts the widget tree and updates transformations.
--
-- @tparam table context Widget context
-- @tparam table widget Root widget
-- @tparam number width Available width
-- @tparam number height Available height
-- @staticfct
function hierarchy_mt:update(context, widget, width, height)
  if not widget then
    print("[hierarchy.update] WARNING: widget is nil!")
    return
  end

  self._context = context
  self._widget = widget
  self._width = width
  self._height = height

  -- Clear old children
  self._children = {}

  -- Fit the widget
  local w, h = base.fit_widget(nil, context, widget, width, height)

  -- Store actual size
  self._width = w
  self._height = h

  -- Layout children
  local placements = base.layout_widget(nil, context, widget, w, h)

  -- Create child hierarchies
  for _, placement in ipairs(placements) do
    local child_widget = placement._widget

    -- Skip nil widgets
    if not child_widget then
      print("[hierarchy] WARNING: placement has nil widget, skipping")
      goto continue
    end

    local child_x = placement._x or 0
    local child_y = placement._y or 0
    local child_w = placement._width or 0
    local child_h = placement._height or 0

    -- Create child hierarchy
    local child_hierarchy = hierarchy.new(context, child_widget, child_w, child_h)
    child_hierarchy:update(context, child_widget, child_w, child_h)

    -- Set child position via matrix
    child_hierarchy._matrix = cairo.Matrix.create_translate(child_x, child_y)

    table.insert(self._children, child_hierarchy)

    ::continue::
  end

  -- Connect widget signals
  -- (For now, we skip signal disconnection optimization)
  if widget and widget.connect_signal then
    widget:connect_signal("widget::layout_changed", function()
      -- Trigger redraw
      if self._context and self._context.drawable then
        self._context.drawable:_redraw()
      end
    end)

    widget:connect_signal("widget::redraw_needed", function()
      -- Trigger redraw
      if self._context and self._context.drawable then
        self._context.drawable:_redraw()
      end
    end)
  end
end

--- Draw the hierarchy
--
-- Recursively draws the widget tree with transformations.
--
-- @tparam table context Widget context
-- @tparam cairo.Context cr Cairo context
-- @staticfct
function hierarchy_mt:draw(context, cr)
  if not self._widget then
    print("[hierarchy] No widget")
    return
  end

  print(
    string.format(
      "[hierarchy] Drawing widget, has draw=%s, children=%d",
      tostring(self._widget.draw ~= nil),
      #self._children
    )
  )

  -- Honor visibility
  if self._widget.get_visible and not self._widget:get_visible() then
    print("[hierarchy] Widget not visible, skipping")
    return
  end

  -- Save cairo state for transformation and outer clip
  cr:save()

  -- Apply transformation matrix if present
  if self._matrix then
    cr:transform(self._matrix)
  end

  -- Clip to draw extents (bounds of widget + children)
  -- Note: We use _width and _height as draw extents for now
  -- AwesomeWM calculates this more precisely, but this should work
  cr:rectangle(0, 0, self._width, self._height)
  cr:clip()

  -- Apply opacity
  local opacity = 1.0
  if self._widget.get_opacity then
    opacity = self._widget:get_opacity()
  end

  if opacity < 1.0 then
    cr:push_group()
  end

  -- Draw the widget itself with its own clip region
  cr:save() -- Inner save for widget-only clip
  cr:rectangle(0, 0, self._width, self._height)
  cr:clip()

  if self._widget.draw then
    print(string.format("[hierarchy] Calling widget:draw(%dx%d)", self._width, self._height))
    self._widget:draw(context, cr, self._width, self._height)
  else
    print("[hierarchy] Widget has no draw method")
  end

  cr:restore() -- Restore immediately after widget draws (removes widget clip)

  -- Clear any path left by the widget
  cr:new_path()

  -- Call before_draw_children hook
  if self._widget.before_draw_children then
    self._widget:before_draw_children(context, cr, self._width, self._height)
  end

  -- Draw children (they inherit transform + outer clip, but not widget clip)
  for _, child in ipairs(self._children) do
    child:draw(context, cr)
  end

  -- Call after_draw_children hook
  if self._widget.after_draw_children then
    self._widget:after_draw_children(context, cr, self._width, self._height)
  end

  -- Clear any path left by children
  cr:new_path()

  -- Apply opacity
  if opacity < 1.0 then
    cr:pop_group_to_source()
    cr:paint_with_alpha(opacity)
  end

  -- Restore transformation and outer clip
  cr:restore()
end

--- Get the widget
--
-- @treturn table Widget
-- @staticfct
function hierarchy_mt:get_widget()
  return self._widget
end

--- Get the size
--
-- @treturn number width
-- @treturn number height
-- @staticfct
function hierarchy_mt:get_size()
  return self._width, self._height
end

--- Get the children
--
-- @treturn table List of child hierarchies
-- @staticfct
function hierarchy_mt:get_children()
  return self._children
end

return hierarchy

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
