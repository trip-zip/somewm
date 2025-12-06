---------------------------------------------------------------------------
-- A container wrapping a widget with background color, foreground color,
-- shape, and border.
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @containermod wibox.container.background
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local color = require("gears.color")
local shape = require("gears.shape")
local lgi = require("lgi")
local cairo = lgi.cairo

local background = { mt = {} }

--- Draw this widget's background
local function draw_shape(self, context, cr, width, height)
  local bg = self._private.bg
  local shape_func = self._private.shape
  local shape_border_width = self._private.shape_border_width or 0
  local shape_border_color = self._private.shape_border_color

  -- Early return if nothing to draw
  if not bg and not shape_border_width then
    return
  end

  -- Apply shape if specified
  if shape_func then
    -- Create the shape path
    shape_func(cr, width, height)

    -- Fill background
    if bg then
      cr:save()
      local pattern = color.create_pattern(bg)
      cr:set_source(pattern)
      if shape_border_width > 0 then
        cr:fill_preserve()
      else
        cr:fill()
      end
      cr:restore()
    end

    -- Draw border
    if shape_border_width > 0 and shape_border_color then
      cr:save()
      local pattern = color.create_pattern(shape_border_color)
      cr:set_source(pattern)
      cr:set_line_width(shape_border_width)
      cr:stroke()
      cr:restore()
    end
  else
    -- No shape - simple rectangle
    if bg then
      cr:save()
      local pattern = color.create_pattern(bg)
      cr:set_source(pattern)
      cr:rectangle(0, 0, width, height)
      cr:fill()
      cr:restore()
    end
  end
end

--- Draw this widget (called before children are drawn)
local function draw(self, context, cr, width, height)
  -- Clip to shape if specified
  if self._private.shape and self._private.shape_clip then
    cr:save()
    self._private.shape(cr, width, height)
    cr:clip()
  end

  -- Draw the background
  draw_shape(self, context, cr, width, height)

  -- Set foreground color if specified (will apply to children)
  if self._private.fg then
    local pattern = color.create_pattern(self._private.fg)
    cr:set_source(pattern)
  end
end

--- Called before children are drawn
local function before_draw_children(self, context, cr, width, height)
  if self._private.before_draw_children then
    cr:save()
    self._private.before_draw_children(self, context, cr, width, height)
    cr:restore()
  end
end

--- Called after children are drawn
local function after_draw_children(self, context, cr, width, height)
  if self._private.after_draw_children then
    cr:save()
    self._private.after_draw_children(self, context, cr, width, height)
    cr:restore()
  end

  -- Restore clip if we set it
  if self._private.shape and self._private.shape_clip then
    cr:restore()
  end
end

--- Fit this widget into the given space
local function fit(self, context, width, height)
  local child = self._private.widget
  if not child then
    return 0, 0
  end

  -- Account for border width
  local border = (self._private.shape_border_width or 0) * 2
  local w = math.max(0, width - border)
  local h = math.max(0, height - border)

  -- Fit the child
  local child_width, child_height = base.fit_widget(self, context, child, w, h)

  -- Add border back
  return child_width + border, child_height + border
end

--- Layout this widget
local function layout(self, context, width, height)
  local child = self._private.widget
  if not child then
    return
  end

  -- Account for border width
  local border = self._private.shape_border_width or 0
  local x = border
  local y = border
  local w = math.max(0, width - border * 2)
  local h = math.max(0, height - border * 2)

  -- Return child layout
  return { base.place_widget_at(child, x, y, w, h) }
end

--- Set the background color
-- @param bg The background color (string or gradient table)
function background:set_bg(bg)
  if self._private.bg == bg then
    return
  end
  self._private.bg = bg
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::bg", bg)
end

--- Get the background color
-- @return The background color
function background:get_bg()
  return self._private.bg
end

--- Set the foreground color
-- @param fg The foreground color (string or gradient table)
function background:set_fg(fg)
  if self._private.fg == fg then
    return
  end
  self._private.fg = fg
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::fg", fg)
end

--- Get the foreground color
-- @return The foreground color
function background:get_fg()
  return self._private.fg
end

--- Set the background shape
-- @param shape A shape function from gears.shape
function background:set_shape(shape)
  if self._private.shape == shape then
    return
  end
  self._private.shape = shape
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::shape", shape)
end

--- Get the background shape
-- @return The shape function
function background:get_shape()
  return self._private.shape
end

--- Set whether the shape should clip children
-- @param clip Boolean - true to clip children to shape
function background:set_shape_clip(clip)
  if self._private.shape_clip == clip then
    return
  end
  self._private.shape_clip = clip
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::shape_clip", clip)
end

--- Get whether the shape clips children
-- @return Boolean
function background:get_shape_clip()
  return self._private.shape_clip
end

--- Set the border width for the shape
-- @param width The border width in pixels
function background:set_shape_border_width(width)
  if self._private.shape_border_width == width then
    return
  end
  self._private.shape_border_width = width
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::shape_border_width", width)
end

--- Get the border width
-- @return The border width
function background:get_shape_border_width()
  return self._private.shape_border_width
end

--- Set the border color for the shape
-- @param color The border color (string or gradient table)
function background:set_shape_border_color(color)
  if self._private.shape_border_color == color then
    return
  end
  self._private.shape_border_color = color
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::shape_border_color", color)
end

--- Get the border color
-- @return The border color
function background:get_shape_border_color()
  return self._private.shape_border_color
end

--- Set the widget that is drawn inside the background
-- @param widget The widget to be wrapped
function background:set_widget(widget)
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

  -- Connect new widget signals (only if widget supports signals)
  if widget and widget.connect_signal then
    widget:connect_signal("widget::redraw_needed", self._redraw_callback)
    widget:connect_signal("widget::layout_changed", self._layout_callback)
  end

  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::widget", widget)
end

--- Get the child widget
-- @return The child widget
function background:get_widget()
  return self._private.widget
end

--- Get all children (for hierarchy)
function background:get_children()
  local child = self._private.widget
  if child then
    return { child }
  end
  return {}
end

--- Replace the child widget
function background:set_children(children)
  self:set_widget(children[1])
end

--- Create a new background container
-- @tparam[opt] table widget The widget to wrap
-- @tparam[opt] string bg The background color
-- @tparam[opt] string fg The foreground color
-- @tparam[opt] function shape The shape function
-- @treturn table A new background container
local function new(widget, bg, fg, shape)
  local ret = base.make_widget(nil, nil, {
    enable_properties = true,
  })

  -- Private state is already initialized by base.make_widget()
  -- Don't replace ret._private, just add our fields!

  -- Set up methods
  ret.draw = draw
  ret.fit = fit
  ret.layout = layout
  ret.before_draw_children = before_draw_children
  ret.after_draw_children = after_draw_children

  -- Add getters/setters
  for _, prop in ipairs({ "bg", "fg", "shape", "shape_clip", "shape_border_width", "shape_border_color", "widget" }) do
    ret["set_" .. prop] = background["set_" .. prop]
    ret["get_" .. prop] = background["get_" .. prop]
  end

  ret.get_children = background.get_children
  ret.set_children = background.set_children

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
  if bg then
    ret:set_bg(bg)
  end
  if fg then
    ret:set_fg(fg)
  end
  if shape then
    ret:set_shape(shape)
  end

  return ret
end

function background.mt:__call(...)
  return new(...)
end

return setmetatable(background, background.mt)
