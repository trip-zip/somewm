---------------------------------------------------------------------------
-- A layout arranging widgets in a row or column
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @layoutmod wibox.layout.fixed
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local gtable = require("gears.table")

local fixed = {}

--- Layout a fixed layout horizontally
local function layout_horizontal(self, context, width, height)
  local result = {}
  local spacing = self._private.spacing or 0
  local pos = 0
  local spacing_widget = self._private.spacing_widget
  local is_y = self._private.dir == "y"
  local is_x = not is_y

  local widgets = self._private.widgets or {}

  print(
    string.format(
      "[fixed.layout] called with %d widgets, dir=%s, is_y=%s, size=%dx%d",
      #widgets,
      tostring(self._private.dir),
      tostring(is_y),
      width,
      height
    )
  )

  for k, v in ipairs(widgets) do
    print(string.format("[fixed.layout] Processing widget %d/%d", k, #widgets))
    -- Fit the widget
    local w, h = base.fit_widget(self, context, v, width - pos, height)

    if is_x then
      if w > 0 then
        -- Place widget
        table.insert(result, base.place_widget_at(v, pos, 0, w, h))
        pos = pos + w

        -- Add spacing (except after last widget)
        if k < #widgets then
          if spacing_widget then
            local sw, sh = base.fit_widget(self, context, spacing_widget, width - pos, height)
            if sw > 0 then
              table.insert(result, base.place_widget_at(spacing_widget, pos, 0, sw, sh))
              pos = pos + sw
            end
          elseif spacing > 0 then
            pos = pos + spacing
          end
        end
      end
    else
      if h > 0 then
        -- Vertical layout (y direction)
        table.insert(result, base.place_widget_at(v, 0, pos, w, h))
        pos = pos + h

        -- Add spacing (except after last widget)
        if k < #widgets then
          if spacing_widget then
            local sw, sh = base.fit_widget(self, context, spacing_widget, width, height - pos)
            if sh > 0 then
              table.insert(result, base.place_widget_at(spacing_widget, 0, pos, sw, sh))
              pos = pos + sh
            end
          elseif spacing > 0 then
            pos = pos + spacing
          end
        end
      end
    end

    -- Stop if we've run out of space
    if pos >= (is_x and width or height) then
      break
    end
  end

  return result
end

--- Fit a fixed layout
local function fit_horizontal(self, context, orig_width, orig_height)
  local width, height = 0, 0
  local spacing = self._private.spacing or 0
  local spacing_widget = self._private.spacing_widget
  local is_y = self._private.dir == "y"
  local is_x = not is_y

  local widgets = self._private.widgets or {}

  for k, v in ipairs(widgets) do
    local w, h = base.fit_widget(
      self,
      context,
      v,
      is_x and (orig_width - width) or orig_width,
      is_y and (orig_height - height) or orig_height
    )

    if is_x then
      width = width + w
      height = math.max(height, h)

      -- Add spacing (except after last widget)
      if k < #widgets then
        if spacing_widget then
          local sw, sh = base.fit_widget(self, context, spacing_widget, orig_width - width, orig_height)
          width = width + sw
        else
          width = width + spacing
        end
      end
    else
      width = math.max(width, w)
      height = height + h

      -- Add spacing (except after last widget)
      if k < #widgets then
        if spacing_widget then
          local sw, sh = base.fit_widget(self, context, spacing_widget, orig_width, orig_height - height)
          height = height + sh
        else
          height = height + spacing
        end
      end
    end
  end

  return width, height
end

--- Add a widget to the layout
-- @param widget The widget to add
function fixed:add(widget)
  print("[fixed] add() called, widget=" .. tostring(widget))
  if not widget then
    print("[fixed] widget is nil, returning")
    return
  end

  local widgets = self._private.widgets or {}
  print(string.format("[fixed] Adding widget to layout, current count=%d", #widgets))
  table.insert(widgets, widget)
  self._private.widgets = widgets
  print(string.format("[fixed] Widget added, new count=%d", #widgets))

  -- Connect signals (only if widget supports signals)
  if widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::widgets")
end

--- Remove a widget from the layout
-- @param index The index of the widget to remove (1-based)
-- @return true if the widget was removed, false otherwise
function fixed:remove(index)
  local widgets = self._private.widgets or {}
  if not widgets[index] then
    return false
  end

  local widget = widgets[index]

  -- Disconnect signals (only if widget supports signals)
  if widget.disconnect_signal then
    widget:disconnect_signal("widget::redraw_needed", self._redraw_callback)
    widget:disconnect_signal("widget::layout_changed", self._layout_callback)
  end

  table.remove(widgets, index)
  self._private.widgets = widgets

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::widgets")

  return true
end

--- Remove all widgets from the layout
function fixed:reset()
  local widgets = self._private.widgets or {}

  -- Disconnect all signals (only if widgets support signals)
  for _, widget in ipairs(widgets) do
    if widget.disconnect_signal then
      widget:disconnect_signal("widget::redraw_needed", self._redraw_callback)
      widget:disconnect_signal("widget::layout_changed", self._layout_callback)
    end
  end

  self._private.widgets = {}

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::widgets")
end

--- Set the spacing between widgets
-- @param spacing The spacing in pixels
function fixed:set_spacing(spacing)
  if self._private.spacing == spacing then
    return
  end
  self._private.spacing = spacing
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::spacing", spacing)
end

--- Get the spacing between widgets
-- @return The spacing in pixels
function fixed:get_spacing()
  return self._private.spacing or 0
end

--- Set a widget to be drawn between each pair of widgets
-- @param widget The spacing widget (or nil to remove)
function fixed:set_spacing_widget(widget)
  if self._private.spacing_widget == widget then
    return
  end

  -- Disconnect old spacing widget (only if it supports signals)
  if self._private.spacing_widget and self._private.spacing_widget.disconnect_signal then
    self._private.spacing_widget:disconnect_signal("widget::redraw_needed", self._redraw_callback)
    self._private.spacing_widget:disconnect_signal("widget::layout_changed", self._layout_callback)
  end

  self._private.spacing_widget = widget

  -- Connect new spacing widget (only if it supports signals)
  if widget and widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::spacing_widget", widget)
end

--- Get the spacing widget
-- @return The spacing widget or nil
function fixed:get_spacing_widget()
  return self._private.spacing_widget
end

--- Get all children
function fixed:get_children()
  return self._private.widgets or {}
end

--- Replace all children
function fixed:set_children(children)
  self:reset()
  for _, widget in ipairs(children) do
    self:add(widget)
  end
end

--- Get the number of widgets
function fixed:get_widget_count()
  return #(self._private.widgets or {})
end

--- Create a new fixed layout
-- @tparam[opt] string dir The direction ("x" for horizontal, "y" for vertical)
-- @treturn table A new fixed layout
local function new(dir)
  local ret = base.make_widget(nil, nil, {
    enable_properties = true,
  })

  -- Private state (merge with base.make_widget's _private, don't replace!)
  ret._private.dir = dir or "x"
  ret._private.widgets = {}

  -- Set up methods
  ret.fit = fit_horizontal
  ret.layout = layout_horizontal

  -- Add methods to object
  for k, v in pairs(fixed) do
    if type(v) == "function" then
      ret[k] = v
    end
  end

  -- Set up signal callbacks
  ret._redraw_callback = function()
    ret:emit_signal("widget::redraw_needed")
  end
  ret._layout_callback = function()
    ret:emit_signal("widget::layout_changed")
  end

  return ret
end

--- Create a horizontal fixed layout
-- @treturn table A new horizontal fixed layout
-- @staticfct wibox.layout.fixed.horizontal
function fixed.horizontal()
  return new("x")
end

--- Create a vertical fixed layout
-- @treturn table A new vertical fixed layout
-- @staticfct wibox.layout.fixed.vertical
function fixed.vertical()
  return new("y")
end

return setmetatable(fixed, {
  __call = function(_, ...)
    return new(...)
  end,
})
