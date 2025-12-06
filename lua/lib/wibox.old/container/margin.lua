---------------------------------------------------------------------------
-- A container adding margins around a widget.
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @containermod wibox.container.margin
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local setmetatable = setmetatable
local type = type

local margin = { mt = {} }

--- Layout this widget
local function layout(self, context, width, height)
  local child = self._private.widget
  if not child then
    return
  end

  local left = self._private.left or 0
  local right = self._private.right or 0
  local top = self._private.top or 0
  local bottom = self._private.bottom or 0

  local x = left
  local y = top
  local w = math.max(0, width - left - right)
  local h = math.max(0, height - top - bottom)

  return { base.place_widget_at(child, x, y, w, h) }
end

--- Fit this widget into the given space
local function fit(self, context, width, height)
  local child = self._private.widget
  if not child then
    return 0, 0
  end

  local left = self._private.left or 0
  local right = self._private.right or 0
  local top = self._private.top or 0
  local bottom = self._private.bottom or 0

  local child_width = math.max(0, width - left - right)
  local child_height = math.max(0, height - top - bottom)

  local w, h = base.fit_widget(self, context, child, child_width, child_height)

  return w + left + right, h + top + bottom
end

--- Set all margins to the same value
-- @param value The margin value in pixels
function margin:set_margins(value)
  if type(value) ~= "number" then
    return
  end

  if
    self._private.left == value
    and self._private.right == value
    and self._private.top == value
    and self._private.bottom == value
  then
    return
  end

  self._private.left = value
  self._private.right = value
  self._private.top = value
  self._private.bottom = value

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::margins", value)
end

--- Get the margins (returns the left margin as representative)
function margin:get_margins()
  return self._private.left or 0
end

--- Set the left margin
-- @param value The margin value in pixels
function margin:set_left(value)
  if self._private.left == value then
    return
  end
  self._private.left = value
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::left", value)
end

--- Get the left margin
function margin:get_left()
  return self._private.left or 0
end

--- Set the right margin
-- @param value The margin value in pixels
function margin:set_right(value)
  if self._private.right == value then
    return
  end
  self._private.right = value
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::right", value)
end

--- Get the right margin
function margin:get_right()
  return self._private.right or 0
end

--- Set the top margin
-- @param value The margin value in pixels
function margin:set_top(value)
  if self._private.top == value then
    return
  end
  self._private.top = value
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::top", value)
end

--- Get the top margin
function margin:get_top()
  return self._private.top or 0
end

--- Set the bottom margin
-- @param value The margin value in pixels
function margin:set_bottom(value)
  if self._private.bottom == value then
    return
  end
  self._private.bottom = value
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::bottom", value)
end

--- Get the bottom margin
function margin:get_bottom()
  return self._private.bottom or 0
end

--- Set the widget that is drawn with margins
-- @param widget The widget to be wrapped
function margin:set_widget(widget)
  if self._private.widget == widget then
    return
  end

  -- Disconnect old widget signals
  if self._private.widget and self._private.widget.disconnect_signal then
    self._private.widget:disconnect_signal("widget::redraw_needed", self._redraw_callback)
    self._private.widget:disconnect_signal("widget::layout_changed", self._layout_callback)
  end

  -- Set new widget
  self._private.widget = widget

  -- Connect new widget signals
  if widget and widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::widget", widget)
end

--- Get the child widget
-- @return The child widget
function margin:get_widget()
  return self._private.widget
end

--- Get all children
function margin:get_children()
  local child = self._private.widget
  if child then
    return { child }
  end
  return {}
end

--- Replace the child widget
function margin:set_children(children)
  self:set_widget(children[1])
end

--- Create a new margin container
-- @tparam[opt] table widget The widget to wrap
-- @tparam[opt] number left Left margin
-- @tparam[opt] number right Right margin
-- @tparam[opt] number top Top margin
-- @tparam[opt] number bottom Bottom margin
-- @treturn table A new margin container
local function new(widget, left, right, top, bottom)
  local ret = base.make_widget(nil, nil, {
    enable_properties = true,
  })

  -- Private state is already initialized by base.make_widget()
  -- Don't replace ret._private, just add our fields!

  -- Set up methods
  ret.fit = fit
  ret.layout = layout

  -- Add getters/setters
  for _, prop in ipairs({ "left", "right", "top", "bottom", "margins", "widget" }) do
    ret["set_" .. prop] = margin["set_" .. prop]
    ret["get_" .. prop] = margin["get_" .. prop]
  end

  ret.get_children = margin.get_children
  ret.set_children = margin.set_children

  -- Set up signal callbacks
  ret._redraw_callback = function()
    ret:emit_signal("widget::redraw_needed")
  end
  ret._layout_callback = function()
    ret:emit_signal("widget::layout_changed")
  end

  -- Apply initial values
  if widget then
    ret:set_widget(widget)
  end

  -- Handle different constructor signatures
  if type(left) == "number" then
    if right == nil and top == nil and bottom == nil then
      -- Single number: set all margins
      ret:set_margins(left)
    else
      -- Individual margins
      ret:set_left(left or 0)
      ret:set_right(right or 0)
      ret:set_top(top or 0)
      ret:set_bottom(bottom or 0)
    end
  end

  return ret
end

function margin.mt:__call(...)
  return new(...)
end

return setmetatable(margin, margin.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
