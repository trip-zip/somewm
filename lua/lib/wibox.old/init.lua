-- lib/wibox/init.lua - Wibox (widget container) implementation
-- Provides boxes that can contain widgets and be drawn on screen

local setmetatable = setmetatable
local error = error
local type = type

local drawable = require("wibox.drawable")
local base = require("wibox.widget.base")

local wibox = {}

-- Create a new wibox
-- @param args Table with { x, y, width, height, visible, widget }
-- @return A wibox instance
function wibox.new(args)
  args = args or {}

  -- Validate arguments
  local x = args.x or 0
  local y = args.y or 0
  local width = args.width or 100
  local height = args.height or 30
  local visible = args.visible or false

  if type(x) ~= "number" or type(y) ~= "number" then
    error("wibox x and y must be numbers")
  end
  if type(width) ~= "number" or type(height) ~= "number" then
    error("wibox width and height must be numbers")
  end
  if width <= 0 or height <= 0 then
    error("wibox width and height must be positive")
  end

  -- Create the C-level wibox
  local c_wibox = _wibox.create({
    x = x,
    y = y,
    width = width,
    height = height,
    visible = visible,
  })

  if not c_wibox then
    error("Failed to create C wibox")
  end

  -- Create drawable
  local drw = drawable.new(c_wibox, width, height)

  -- Create Lua wrapper
  local self = {
    _c_wibox = c_wibox,
    _drawable = drw,
    _widget = args.widget or nil,
    x = x,
    y = y,
    width = width,
    height = height,
    bg = args.bg or nil,
    fg = args.fg or nil,
  }

  -- Set initial properties
  if args.bg then
    drw:set_bg(args.bg)
  end
  if args.fg then
    drw:set_fg(args.fg)
  end
  if args.widget then
    drw:set_widget(args.widget)
  end

  -- Methods
  function self:show()
    if not _wibox.is_visible(self._c_wibox) then
      _wibox.show(self._c_wibox)
    end
  end

  function self:hide()
    if _wibox.is_visible(self._c_wibox) then
      _wibox.hide(self._c_wibox)
    end
  end

  function self:toggle()
    if _wibox.is_visible(self._c_wibox) then
      self:hide()
    else
      self:show()
    end
  end

  function self:destroy()
    _wibox.destroy(self._c_wibox)
    self._c_wibox = nil
    self._drawable = nil
    self._widget = nil
  end

  -- Declarative widget setup
  function self:setup(args)
    local widget = base.make_widget_declarative(args)
    if widget then
      self.widget = widget
    end
  end

  -- Property forwarding metatable
  local mt = {
    __index = function(t, k)
      if k == "widget" then
        return t._drawable:get_widget()
      elseif k == "visible" then
        return _wibox.is_visible(t._c_wibox)
      elseif k == "bg" then
        return t._drawable:get_bg()
      elseif k == "fg" then
        return t._drawable:get_fg()
      end
    end,
    __newindex = function(t, k, v)
      if k == "widget" then
        t._drawable:set_widget(v)
      elseif k == "visible" then
        if v then
          t:show()
        else
          t:hide()
        end
      elseif k == "bg" then
        t._drawable:set_bg(v)
      elseif k == "fg" then
        t._drawable:set_fg(v)
      else
        rawset(t, k, v)
      end
    end,
  }
  setmetatable(self, mt)

  return self
end

-- Constructor for convenience
setmetatable(wibox, {
  __call = function(_, args)
    return wibox.new(args)
  end,
})

return wibox
