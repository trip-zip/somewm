-- lib/wibox/widget/textbox.lua - Simple textbox widget
-- Displays text using Pango for rendering

local setmetatable = setmetatable
local type = type
local error = error

local textbox = {}

-- Create a new textbox widget
-- @param text Initial text (optional)
-- @return A textbox widget instance
function textbox.new(text)
  local self = {
    _text = text or "",
    _visible = true,
    _font = "Sans 12",
    _color = { 1, 1, 1, 1 }, -- RGBA, default white
    is_widget = true, -- Widget marker for compatibility
  }

  -- Draw method - called by wibox to render the widget
  -- Signature: draw(context, cr, width, height)
  function self:draw(context_or_cr, cr_or_width, width_or_height, height)
    print(string.format("[textbox] draw() called with %d args, text='%s'", height and 4 or 3, tostring(self._text)))

    -- Handle both old (cr, width, height) and new (context, cr, width, height) signatures
    local context, cr, width
    if height then
      -- New signature: (context, cr, width, height)
      context = context_or_cr
      cr = cr_or_width
      width = width_or_height
    else
      -- Old signature: (cr, width, height)
      cr = context_or_cr
      width = cr_or_width
      height = width_or_height
    end

    if not self._visible or not self._text or self._text == "" then
      print("[textbox] Skipping draw: visible=" .. tostring(self._visible) .. " text='" .. tostring(self._text) .. "'")
      return
    end

    print("[textbox] Proceeding with draw")

    -- Get LGI modules for text rendering
    local lgi = require("lgi")
    local Pango = lgi.Pango
    local PangoCairo = lgi.PangoCairo

    -- Set text color
    cr:set_source_rgba(self._color[1], self._color[2], self._color[3], self._color[4])

    -- Create Pango layout for text rendering
    local layout = PangoCairo.create_layout(cr)
    layout:set_text(self._text)

    -- Set font
    if self._font then
      local font_desc = Pango.FontDescription.from_string(self._font)
      layout:set_font_description(font_desc)
    end

    -- Get text dimensions
    local text_width, text_height = layout:get_pixel_size()

    -- Center text vertically
    local y_offset = (height - text_height) / 2

    -- Position and draw text
    cr:move_to(5, y_offset) -- 5px padding from left
    PangoCairo.show_layout(cr, layout)
  end

  -- Fit method - calculate required size
  -- Signature: fit(context, width, height)
  function self:fit(context_or_width, width_or_height, height)
    -- Handle both old (width, height) and new (context, width, height) signatures
    local width, height_val
    if height then
      -- New signature: (context, width, height)
      width = width_or_height
      height_val = height
    else
      -- Old signature: (width, height)
      width = context_or_width
      height_val = width_or_height
    end

    if not self._text or self._text == "" then
      return 0, 0
    end

    -- Get LGI modules for text measurement
    local lgi = require("lgi")
    local Pango = lgi.Pango
    local PangoCairo = lgi.PangoCairo
    local cairo = lgi.cairo

    -- Create temporary surface for measurement
    local surface = cairo.ImageSurface.create("ARGB32", 1, 1)
    local cr = cairo.Context.create(surface)

    -- Create Pango layout
    local layout = PangoCairo.create_layout(cr)
    layout:set_text(self._text)

    -- Set font
    if self._font then
      local font_desc = Pango.FontDescription.from_string(self._font)
      layout:set_font_description(font_desc)
    end

    -- Get text dimensions
    local text_width, text_height = layout:get_pixel_size()

    -- Add padding
    return text_width + 10, text_height
  end

  -- Set text
  function self:set_text(text)
    if type(text) ~= "string" then
      error("textbox text must be a string")
    end
    self._text = text
  end

  -- Get text
  function self:get_text()
    return self._text
  end

  -- Set font
  function self:set_font(font)
    if type(font) ~= "string" then
      error("textbox font must be a string")
    end
    self._font = font
  end

  -- Get font
  function self:get_font()
    return self._font
  end

  -- Set color (RGBA table)
  function self:set_color(color)
    if type(color) ~= "table" then
      error("textbox color must be a table {r, g, b, a}")
    end
    self._color = color
  end

  -- Get color
  function self:get_color()
    return self._color
  end

  -- Show/hide
  function self:set_visible(visible)
    self._visible = visible
  end

  function self:get_visible()
    return self._visible
  end

  -- Get forced width (nil means not forced)
  function self:get_forced_width()
    return nil
  end

  -- Get forced height (nil means not forced)
  function self:get_forced_height()
    return nil
  end

  -- Get markup geometry - measure text with Pango markup
  -- This is used by hotkeys_popup for column layout calculations
  -- @param markup String with Pango markup (e.g., "<b>text</b>")
  -- @param font Optional font description (uses widget font if not provided)
  -- @return width, height in pixels
  function self:get_markup_geometry(markup, font)
    if not markup or markup == "" then
      return 0, 0
    end

    -- Get LGI modules for text measurement
    local lgi = require("lgi")
    local Pango = lgi.Pango
    local PangoCairo = lgi.PangoCairo
    local cairo = lgi.cairo

    -- Create temporary surface for measurement
    local surface = cairo.ImageSurface.create("ARGB32", 1, 1)
    local cr = cairo.Context.create(surface)

    -- Create Pango layout
    local layout = PangoCairo.create_layout(cr)
    layout:set_markup(markup, -1) -- -1 means auto-detect length

    -- Set font
    local font_to_use = font or self._font
    if font_to_use then
      local font_desc = Pango.FontDescription.from_string(font_to_use)
      layout:set_font_description(font_desc)
    end

    -- Get text dimensions
    local text_width, text_height = layout:get_pixel_size()

    return text_width, text_height
  end

  -- Metatable for property access
  local mt = {
    __index = function(t, k)
      if k == "text" then
        return t:get_text()
      elseif k == "font" then
        return t:get_font()
      elseif k == "color" then
        return t:get_color()
      elseif k == "visible" then
        return t:get_visible()
      end
    end,
    __newindex = function(t, k, v)
      if k == "text" then
        t:set_text(v)
      elseif k == "font" then
        t:set_font(v)
      elseif k == "color" then
        t:set_color(v)
      elseif k == "visible" then
        t:set_visible(v)
      else
        rawset(t, k, v)
      end
    end,
  }
  setmetatable(self, mt)

  return self
end

-- Constructor for convenience
setmetatable(textbox, {
  __call = function(_, text)
    return textbox.new(text)
  end,
})

return textbox
