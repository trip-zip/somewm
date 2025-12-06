---------------------------------------------------------------------------
-- A widget displaying an image
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @widgetmod wibox.widget.imagebox
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local surface = require("gears.surface")
local lgi = require("lgi")
local cairo = lgi.cairo

local imagebox = { mt = {} }

--- Draw the imagebox
local function draw(self, context, cr, width, height)
  local img = self._private.image
  if not img then
    return
  end

  -- Get image dimensions
  local img_width = img:get_width()
  local img_height = img:get_height()

  if img_width == 0 or img_height == 0 then
    return
  end

  -- Calculate scaling
  local scale_x = 1
  local scale_y = 1
  local offset_x = 0
  local offset_y = 0

  local resize = self._private.resize or true
  local horizontal_fit_policy = self._private.horizontal_fit_policy or "auto"
  local vertical_fit_policy = self._private.vertical_fit_policy or "auto"

  if resize then
    -- Calculate scale factors
    local scale_w = width / img_width
    local scale_h = height / img_height

    -- Determine scaling based on fit policy
    if horizontal_fit_policy == "fit" and vertical_fit_policy == "fit" then
      -- Fit within bounds (maintain aspect ratio, may have empty space)
      scale_x = math.min(scale_w, scale_h)
      scale_y = scale_x
    elseif horizontal_fit_policy == "cover" or vertical_fit_policy == "cover" then
      -- Cover entire area (maintain aspect ratio, may crop)
      scale_x = math.max(scale_w, scale_h)
      scale_y = scale_x
    else
      -- Auto: fit within bounds
      scale_x = math.min(scale_w, scale_h)
      scale_y = scale_x
    end

    -- Calculate centering offset
    local scaled_width = img_width * scale_x
    local scaled_height = img_height * scale_y

    if self._private.halign == "center" then
      offset_x = (width - scaled_width) / 2
    elseif self._private.halign == "right" then
      offset_x = width - scaled_width
    else
      -- left or nil
      offset_x = 0
    end

    if self._private.valign == "center" then
      offset_y = (height - scaled_height) / 2
    elseif self._private.valign == "bottom" then
      offset_y = height - scaled_height
    else
      -- top or nil
      offset_y = 0
    end
  else
    -- No resize - just center if needed
    if self._private.halign == "center" then
      offset_x = (width - img_width) / 2
    elseif self._private.halign == "right" then
      offset_x = width - img_width
    end

    if self._private.valign == "center" then
      offset_y = (height - img_height) / 2
    elseif self._private.valign == "bottom" then
      offset_y = height - img_height
    end
  end

  -- Clip to bounds
  cr:save()
  cr:rectangle(0, 0, width, height)
  cr:clip()

  -- Apply transformations
  cr:translate(offset_x, offset_y)
  cr:scale(scale_x, scale_y)

  -- Draw image
  cr:set_source_surface(img, 0, 0)

  local pattern = cr:get_source()
  if self._private.resize then
    -- Use best quality filtering
    pattern:set_filter("BEST")
  else
    -- Use nearest neighbor for pixel-perfect rendering
    pattern:set_filter("NEAREST")
  end

  cr:paint()

  cr:restore()
end

--- Fit the imagebox
local function fit(self, context, width, height)
  local img = self._private.image
  if not img then
    return 0, 0
  end

  local img_width = img:get_width()
  local img_height = img:get_height()

  if not self._private.resize then
    return img_width, img_height
  end

  -- Calculate aspect ratio
  local aspect = img_width / img_height
  local fit_width, fit_height

  -- Fit within available space maintaining aspect ratio
  if width / aspect <= height then
    fit_width = width
    fit_height = width / aspect
  else
    fit_width = height * aspect
    fit_height = height
  end

  return fit_width, fit_height
end

--- Set the image
-- @param image The image (can be a file path, cairo surface, or nil)
function imagebox:set_image(image)
  local img

  if type(image) == "string" then
    -- Load from file path
    img = surface.load(image)
  elseif type(image) == "userdata" or (type(image) == "table" and image.get_width) then
    -- Already a cairo surface
    img = image
  elseif image == nil then
    img = nil
  else
    error("Invalid image type: expected string path or cairo surface")
    return
  end

  self._private.image = img
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::image", image)
end

--- Get the image
-- @return The cairo surface or nil
function imagebox:get_image()
  return self._private.image
end

--- Set whether the image should be resized to fit
-- @param resize Boolean
function imagebox:set_resize(resize)
  if self._private.resize == resize then
    return
  end
  self._private.resize = resize
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::resize", resize)
end

--- Get whether the image is resized
-- @return Boolean
function imagebox:get_resize()
  return self._private.resize ~= false
end

--- Set the horizontal alignment
-- @param align "left", "center", or "right"
function imagebox:set_halign(align)
  if self._private.halign == align then
    return
  end
  self._private.halign = align
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::halign", align)
end

--- Get the horizontal alignment
-- @return The horizontal alignment
function imagebox:get_halign()
  return self._private.halign or "left"
end

--- Set the vertical alignment
-- @param align "top", "center", or "bottom"
function imagebox:set_valign(align)
  if self._private.valign == align then
    return
  end
  self._private.valign = align
  self:emit_signal("widget::redraw_needed")
  self:emit_signal("property::valign", align)
end

--- Get the vertical alignment
-- @return The vertical alignment
function imagebox:get_valign()
  return self._private.valign or "top"
end

--- Set the horizontal fit policy
-- @param policy "auto", "fit", "cover", or "none"
function imagebox:set_horizontal_fit_policy(policy)
  if self._private.horizontal_fit_policy == policy then
    return
  end
  self._private.horizontal_fit_policy = policy
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::horizontal_fit_policy", policy)
end

--- Get the horizontal fit policy
-- @return The horizontal fit policy
function imagebox:get_horizontal_fit_policy()
  return self._private.horizontal_fit_policy or "auto"
end

--- Set the vertical fit policy
-- @param policy "auto", "fit", "cover", or "none"
function imagebox:set_vertical_fit_policy(policy)
  if self._private.vertical_fit_policy == policy then
    return
  end
  self._private.vertical_fit_policy = policy
  self:emit_signal("widget::layout_changed")
  self:emit_signal("property::vertical_fit_policy", policy)
end

--- Get the vertical fit policy
-- @return The vertical fit policy
function imagebox:get_vertical_fit_policy()
  return self._private.vertical_fit_policy or "auto"
end

--- Create a new imagebox widget
-- @tparam[opt] string|table image The image (file path or cairo surface)
-- @tparam[opt] boolean resize Whether to resize the image (default: true)
-- @treturn table A new imagebox widget
local function new(image, resize)
  local ret = base.make_widget(nil, nil, {
    enable_properties = true,
  })

  -- Private state
  ret._private = {}

  -- Set up methods
  ret.draw = draw
  ret.fit = fit

  -- Add getters/setters
  for _, prop in ipairs({
    "image",
    "resize",
    "halign",
    "valign",
    "horizontal_fit_policy",
    "vertical_fit_policy",
  }) do
    ret["set_" .. prop] = imagebox["set_" .. prop]
    ret["get_" .. prop] = imagebox["get_" .. prop]
  end

  -- Apply initial values
  if image then
    ret:set_image(image)
  end
  if resize ~= nil then
    ret:set_resize(resize)
  end

  return ret
end

function imagebox.mt:__call(...)
  return new(...)
end

return setmetatable(imagebox, imagebox.mt)
