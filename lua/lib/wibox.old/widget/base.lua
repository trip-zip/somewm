---------------------------------------------------------------------------
--- Base widget class and utilities.
---
--- This module provides the foundation for all wibox widgets.
--- All widgets must implement the widget protocol defined here.
---
--- @module wibox.widget.base
---------------------------------------------------------------------------

local object = require("gears.object")
local gtable = require("gears.table")
local gdebug = require("gears.debug")

local base = {}

--- Widget marker constant
base.is_widget = true

---------------------------------------------------------------------------
-- Widget Protocol
---------------------------------------------------------------------------

--[[
Every widget must follow this protocol:

Required:
  - is_widget = true (marker)

Optional methods:
  - fit(context, width, height) -> w, h
      Calculate size requirements
  - layout(context, width, height) -> placements
      Position children (for containers)
  - draw(context, cr, width, height)
      Draw the widget
  - before_draw_children(context, cr, width, height)
      Hook called before drawing children
  - after_draw_children(context, cr, width, height)
      Hook called after drawing children

Inherited from base (via make_widget):
  - connect_signal(name, callback)
  - disconnect_signal(name, callback)
  - emit_signal(name, ...)
  - get_children()
  - set_children(children)
--]]

---------------------------------------------------------------------------
-- Widget Creation
---------------------------------------------------------------------------

--- Check if an object is a valid widget
--
-- @tparam table widget Widget to check
-- @treturn boolean True if widget is valid
-- @staticfct wibox.widget.base.check_widget
function base.check_widget(widget)
  if type(widget) ~= "table" then
    return false
  end

  if not widget.is_widget then
    return false
  end

  return true
end

--- Create a new widget
--
-- @tparam[opt] table proxy Proxy object (for metatable inheritance)
-- @tparam[opt] string widget_name Widget name for debugging
-- @tparam[opt] table args Additional arguments
-- @treturn table New widget
-- @staticfct wibox.widget.base.make_widget
function base.make_widget(proxy, widget_name, args)
  args = args or {}

  -- Create widget using gears.object for signals
  local widget = proxy or object()

  -- Mark as widget
  widget.is_widget = true

  -- Initialize private state
  widget._private = widget._private or {}
  widget._private.widget_name = widget_name

  -- Default properties
  widget._private.visible = true
  widget._private.opacity = 1.0
  widget._private.forced_width = nil
  widget._private.forced_height = nil

  -- Property getters/setters

  --- Get widget visibility
  function widget:get_visible()
    return self._private.visible
  end

  --- Set widget visibility
  function widget:set_visible(visible)
    if self._private.visible ~= visible then
      self._private.visible = visible
      self:emit_signal("widget::layout_changed")
    end
  end

  --- Get widget opacity
  function widget:get_opacity()
    return self._private.opacity
  end

  --- Set widget opacity (0.0 to 1.0)
  function widget:set_opacity(opacity)
    opacity = math.max(0, math.min(1, opacity))
    if self._private.opacity ~= opacity then
      self._private.opacity = opacity
      self:emit_signal("widget::redraw_needed")
    end
  end

  --- Get forced width
  function widget:get_forced_width()
    return self._private.forced_width
  end

  --- Set forced width
  function widget:set_forced_width(width)
    if self._private.forced_width ~= width then
      self._private.forced_width = width
      self:emit_signal("widget::layout_changed")
    end
  end

  --- Get forced height
  function widget:get_forced_height()
    return self._private.forced_height
  end

  --- Set forced height
  function widget:set_forced_height(height)
    if self._private.forced_height ~= height then
      self._private.forced_height = height
      self:emit_signal("widget::layout_changed")
    end
  end

  --- Get children (default: none)
  function widget:get_children()
    return {}
  end

  --- Set children (default: no-op, override in containers)
  function widget:set_children(children)
    -- Override in container widgets
  end

  return widget
end

---------------------------------------------------------------------------
-- Widget Placement
---------------------------------------------------------------------------

--- Create a widget placement
--
-- @tparam table widget Widget to place
-- @tparam number x X coordinate
-- @tparam number y Y coordinate
-- @tparam number width Width
-- @tparam number height Height
-- @treturn table Placement table
-- @staticfct wibox.widget.base.place_widget_at
function base.place_widget_at(widget, x, y, width, height)
  return {
    _widget = widget,
    _x = x,
    _y = y,
    _width = width,
    _height = height,
  }
end

---------------------------------------------------------------------------
-- Widget Sizing (Fit)
---------------------------------------------------------------------------

--- Fit a widget into given space
--
-- This wraps the widget's :fit() method with property handling.
--
-- @tparam table parent Parent widget
-- @tparam table context Widget context
-- @tparam table widget Widget to fit
-- @tparam number width Available width
-- @tparam number height Available height
-- @treturn number width Widget width
-- @treturn number height Widget height
-- @staticfct wibox.widget.base.fit_widget
function base.fit_widget(parent, context, widget, width, height)
  if not base.check_widget(widget) then
    gdebug.print_warning("Attempted to fit non-widget")
    return 0, 0
  end

  -- Honor visibility
  if not widget:get_visible() then
    return 0, 0
  end

  -- Check for forced dimensions
  local forced_width = widget:get_forced_width()
  local forced_height = widget:get_forced_height()

  if forced_width and forced_height then
    return forced_width, forced_height
  end

  -- Call widget's fit method
  local w, h = 0, 0

  if widget.fit then
    w, h = widget:fit(context, width, height)
  else
    -- No fit method - use available space
    w, h = width, height
  end

  -- Apply forced dimensions if specified
  w = forced_width or w
  h = forced_height or h

  -- Clamp to available space
  w = math.min(w, width)
  h = math.min(h, height)

  return w, h
end

---------------------------------------------------------------------------
-- Widget Layout
---------------------------------------------------------------------------

--- Layout a widget's children
--
-- This wraps the widget's :layout() method.
--
-- @tparam table parent Parent widget
-- @tparam table context Widget context
-- @tparam table widget Widget to layout
-- @tparam number width Widget width
-- @tparam number height Widget height
-- @treturn table List of placements
-- @staticfct wibox.widget.base.layout_widget
function base.layout_widget(parent, context, widget, width, height)
  print(string.format("[base.layout_widget] called, widget=%s, size=%dx%d", tostring(widget), width, height))

  if not base.check_widget(widget) then
    print("[base.layout_widget] NOT A WIDGET!")
    gdebug.print_warning("Attempted to layout non-widget")
    return {}
  end

  -- Honor visibility
  local visible = widget:get_visible()
  print(string.format("[base.layout_widget] visible=%s", tostring(visible)))
  if not visible then
    print("[base.layout_widget] Not visible, returning empty")
    return {}
  end

  -- Call widget's layout method if it exists
  if widget.layout then
    print("[base.layout_widget] Widget has layout method, calling it")
    local result = widget:layout(context, width, height)
    print(string.format("[base.layout_widget] layout() returned %d placements", result and #result or 0))
    return result or {}
  end

  -- No layout method - no children
  print("[base.layout_widget] No layout method, returning empty")
  return {}
end

--- Helper to draw a widget at a specific position
--
-- @tparam table context Widget context
-- @tparam object cr Cairo context
-- @tparam table widget Widget to draw
-- @tparam number x X position
-- @tparam number y Y position
-- @tparam number width Widget width
-- @tparam number height Widget height
-- @staticfct wibox.widget.base.draw_widget
function base.draw_widget(context, cr, widget, x, y, width, height)
  if not base.check_widget(widget) then
    return
  end

  -- Honor visibility
  if not widget:get_visible() then
    return
  end

  -- Apply transformation for position
  if x ~= 0 or y ~= 0 then
    cr:save()
    cr:translate(x, y)
  end

  -- Call widget's draw method if it exists
  if widget.draw then
    widget:draw(context, cr, width, height)
  end

  -- Restore transformation
  if x ~= 0 or y ~= 0 then
    cr:restore()
  end
end

--- Helper to create a placement specification for hierarchy
--
-- @tparam table widget Widget to place
---------------------------------------------------------------------------
-- Declarative Syntax Support
---------------------------------------------------------------------------

--- Make a widget from a declarative description
--
-- Simplified version for now - just handles basic widget construction.
--
-- @tparam table args Widget specification
-- @treturn table Created widget
-- @staticfct wibox.widget.base.make_widget_declarative
function base.make_widget_declarative(args)
  if not args then
    return nil
  end

  -- If it's already a widget, return it
  if base.check_widget(args) then
    return args
  end

  -- Must have a widget field specifying the constructor
  if not args.widget then
    gdebug.print_warning("Declarative widget missing 'widget' field")
    return nil
  end

  -- Call the widget constructor
  local widget_constructor = args.widget
  local widget

  if type(widget_constructor) == "function" then
    widget = widget_constructor()
  elseif type(widget_constructor) == "table" and widget_constructor.new then
    widget = widget_constructor.new()
  else
    gdebug.print_warning("Invalid widget constructor")
    return nil
  end

  if not widget then
    return nil
  end

  -- Apply properties
  for k, v in pairs(args) do
    if k ~= "widget" and k ~= "layout" then
      -- Try to set property
      local setter = widget["set_" .. k]
      if setter then
        setter(widget, v)
      else
        -- Direct assignment
        widget[k] = v
      end
    end
  end

  -- Handle layout (container-specific)
  if args.layout then
    -- The layout will be set by the container
    -- For now, just store it
    widget._private.layout = args.layout
  end

  return widget
end

--- Make a widget from various value types
--
-- @tparam any widget_or_value Widget, table, or value
-- @treturn table|nil Widget or nil
-- @staticfct wibox.widget.base.make_widget_from_value
function base.make_widget_from_value(widget_or_value)
  -- Already a widget
  if base.check_widget(widget_or_value) then
    return widget_or_value
  end

  -- Table - try declarative construction
  if type(widget_or_value) == "table" then
    return base.make_widget_declarative(widget_or_value)
  end

  -- String - create textbox widget
  if type(widget_or_value) == "string" then
    local textbox = require("wibox.widget.textbox")
    local w = textbox.new()
    w:set_text(widget_or_value)
    return w
  end

  return nil
end

---------------------------------------------------------------------------
-- Child Management
---------------------------------------------------------------------------

--- Get all children recursively
--
-- @tparam table widget Widget
-- @treturn table List of all children
-- @staticfct wibox.widget.base.get_all_children
function base.get_all_children(widget)
  local result = {}

  local children = widget:get_children()
  for _, child in ipairs(children) do
    table.insert(result, child)

    -- Recurse
    local grandchildren = base.get_all_children(child)
    for _, gc in ipairs(grandchildren) do
      table.insert(result, gc)
    end
  end

  return result
end

--- Get children by ID
--
-- @tparam table widget Widget to search
-- @tparam string id ID to find
-- @treturn table List of matching widgets
-- @staticfct wibox.widget.base.get_children_by_id
function base.get_children_by_id(widget, id)
  local result = {}

  -- Check this widget
  if widget.id == id or widget._private.id == id then
    table.insert(result, widget)
  end

  -- Check children
  local children = widget:get_children()
  for _, child in ipairs(children) do
    local matches = base.get_children_by_id(child, id)
    for _, match in ipairs(matches) do
      table.insert(result, match)
    end
  end

  return result
end

return base

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
