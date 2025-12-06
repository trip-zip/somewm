---------------------------------------------------------------------------
-- A layout aligning widgets in three slots: left/center/right or top/middle/bottom
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @layoutmod wibox.layout.align
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local gtable = require("gears.table")

local align = {}

--- Layout the align layout
local function layout_align(self, context, width, height)
  local result = {}
  local is_y = self._private.dir == "y"
  local is_x = not is_y

  local first = self._private.first
  local second = self._private.second
  local third = self._private.third

  local size_first, size_third = 0, 0
  local size_second_x, size_second_y = 0, 0

  -- Determine sizes
  if is_x then
    -- Horizontal layout (left, center, right)
    if first then
      size_first = base.fit_widget(self, context, first, width, height)
    end

    if third then
      size_third = base.fit_widget(self, context, third, width, height)
    end

    -- Middle widget gets remaining space
    if second then
      local remaining = math.max(0, width - size_first - size_third)
      size_second_x, size_second_y = base.fit_widget(self, context, second, remaining, height)
    end

    -- Expand middle to fill if expand is set
    if self._private.expand == "inside" or self._private.expand == "outside" then
      size_second_x = math.max(0, width - size_first - size_third)
    end

    -- Place widgets
    local pos = 0

    -- First (left)
    if first and size_first > 0 then
      table.insert(result, base.place_widget_at(first, pos, 0, size_first, height))
      pos = pos + size_first
    end

    -- Second (center)
    if second then
      local center_pos = pos + math.floor((width - size_first - size_third - size_second_x) / 2)
      table.insert(result, base.place_widget_at(second, center_pos, 0, size_second_x, size_second_y))
    end

    -- Third (right)
    if third and size_third > 0 then
      local right_pos = width - size_third
      table.insert(result, base.place_widget_at(third, right_pos, 0, size_third, height))
    end
  else
    -- Vertical layout (top, middle, bottom)
    if first then
      local _, h = base.fit_widget(self, context, first, width, height)
      size_first = h
    end

    if third then
      local _, h = base.fit_widget(self, context, third, width, height)
      size_third = h
    end

    -- Middle widget gets remaining space
    if second then
      local remaining = math.max(0, height - size_first - size_third)
      size_second_x, size_second_y = base.fit_widget(self, context, second, width, remaining)
    end

    -- Expand middle to fill if expand is set
    if self._private.expand == "inside" or self._private.expand == "outside" then
      size_second_y = math.max(0, height - size_first - size_third)
    end

    -- Place widgets
    local pos = 0

    -- First (top)
    if first and size_first > 0 then
      table.insert(result, base.place_widget_at(first, 0, pos, width, size_first))
      pos = pos + size_first
    end

    -- Second (middle)
    if second then
      local center_pos = pos + math.floor((height - size_first - size_third - size_second_y) / 2)
      table.insert(result, base.place_widget_at(second, 0, center_pos, size_second_x, size_second_y))
    end

    -- Third (bottom)
    if third and size_third > 0 then
      local bottom_pos = height - size_third
      table.insert(result, base.place_widget_at(third, 0, bottom_pos, width, size_third))
    end
  end

  return result
end

--- Fit the align layout
local function fit_align(self, context, width, height)
  local is_y = self._private.dir == "y"
  local is_x = not is_y

  local first = self._private.first
  local second = self._private.second
  local third = self._private.third

  local w, h = 0, 0

  if is_x then
    -- Horizontal: sum widths, max height
    if first then
      local fw, fh = base.fit_widget(self, context, first, width, height)
      w = w + fw
      h = math.max(h, fh)
    end

    if second then
      local sw, sh = base.fit_widget(self, context, second, width - w, height)
      w = w + sw
      h = math.max(h, sh)
    end

    if third then
      local tw, th = base.fit_widget(self, context, third, width - w, height)
      w = w + tw
      h = math.max(h, th)
    end
  else
    -- Vertical: max width, sum heights
    if first then
      local fw, fh = base.fit_widget(self, context, first, width, height)
      w = math.max(w, fw)
      h = h + fh
    end

    if second then
      local sw, sh = base.fit_widget(self, context, second, width, height - h)
      w = math.max(w, sw)
      h = h + sh
    end

    if third then
      local tw, th = base.fit_widget(self, context, third, width, height - h)
      w = math.max(w, tw)
      h = h + th
    end
  end

  return w, h
end

--- Set the first widget (left or top)
-- @param widget The widget to set
function align:set_first(widget)
  if self._private.first == widget then
    return
  end

  -- Disconnect old widget (only if it supports signals)
  if self._private.first and self._private.first.disconnect_signal then
    self._private.first:disconnect_signal("widget::redraw_needed", self._redraw_callback)
    self._private.first:disconnect_signal("widget::layout_changed", self._layout_callback)
  end

  self._private.first = widget

  -- Connect new widget (only if it supports signals)
  if widget and widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::first", widget)
end

--- Get the first widget
-- @return The first widget
function align:get_first()
  return self._private.first
end

--- Set the second widget (center or middle)
-- @param widget The widget to set
function align:set_second(widget)
  if self._private.second == widget then
    return
  end

  -- Disconnect old widget (only if it supports signals)
  if self._private.second and self._private.second.disconnect_signal then
    self._private.second:disconnect_signal("widget::redraw_needed", self._redraw_callback)
    self._private.second:disconnect_signal("widget::layout_changed", self._layout_callback)
  end

  self._private.second = widget

  -- Connect new widget (only if it supports signals)
  if widget and widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::second", widget)
end

--- Get the second widget
-- @return The second widget
function align:get_second()
  return self._private.second
end

--- Set the third widget (right or bottom)
-- @param widget The widget to set
function align:set_third(widget)
  if self._private.third == widget then
    return
  end

  -- Disconnect old widget (only if it supports signals)
  if self._private.third and self._private.third.disconnect_signal then
    self._private.third:disconnect_signal("widget::redraw_needed", self._redraw_callback)
    self._private.third:disconnect_signal("widget::layout_changed", self._layout_callback)
  end

  self._private.third = widget

  -- Connect new widget (only if it supports signals)
  if widget and widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::third", widget)
end

--- Get the third widget
-- @return The third widget
function align:get_third()
  return self._private.third
end

--- Set the expand mode for the middle widget
-- @param mode "none", "inside", or "outside"
function align:set_expand(mode)
  if self._private.expand == mode then
    return
  end
  self._private.expand = mode
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::expand", mode)
end

--- Get the expand mode
-- @return The expand mode
function align:get_expand()
  return self._private.expand or "none"
end

--- Get all children
function align:get_children()
  local ret = {}
  if self._private.first then
    table.insert(ret, self._private.first)
  end
  if self._private.second then
    table.insert(ret, self._private.second)
  end
  if self._private.third then
    table.insert(ret, self._private.third)
  end
  return ret
end

--- Replace all children
function align:set_children(children)
  self:set_first(children[1])
  self:set_second(children[2])
  self:set_third(children[3])
end

--- Aliases for horizontal layout
function align:set_left(widget)
  self:set_first(widget)
end

function align:get_left()
  return self:get_first()
end

function align:set_middle(widget)
  self:set_second(widget)
end

function align:get_middle()
  return self:get_second()
end

function align:set_right(widget)
  self:set_third(widget)
end

function align:get_right()
  return self:get_third()
end

--- Aliases for vertical layout
function align:set_top(widget)
  self:set_first(widget)
end

function align:get_top()
  return self:get_first()
end

function align:set_bottom(widget)
  self:set_third(widget)
end

function align:get_bottom()
  return self:get_third()
end

--- Create a new align layout
-- @tparam[opt] string dir The direction ("x" for horizontal, "y" for vertical)
-- @treturn table A new align layout
local function new(dir)
  local ret = base.make_widget(nil, nil, {
    enable_properties = true,
  })

  -- Private state
  ret._private = {
    dir = dir or "x",
  }

  -- Set up methods
  ret.fit = fit_align
  ret.layout = layout_align

  -- Add methods to object
  for k, v in pairs(align) do
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

--- Create a horizontal align layout
-- @treturn table A new horizontal align layout
-- @staticfct wibox.layout.align.horizontal
function align.horizontal()
  return new("x")
end

--- Create a vertical align layout
-- @treturn table A new vertical align layout
-- @staticfct wibox.layout.align.vertical
function align.vertical()
  return new("y")
end

return setmetatable(align, {
  __call = function(_, ...)
    return new(...)
  end,
})
