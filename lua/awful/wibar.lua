---------------------------------------------------------------------------
--- The main AwesomeWM "bar" module.
--
-- This module allows you to easily create wibox and attach them to the edge of
-- a screen.
--
--@DOC_awful_wibar_default_EXAMPLE@
--
-- You can even have vertical bars too.
--
--@DOC_awful_wibar_left_EXAMPLE@
--
-- @author Emmanuel Lepage Vallee &lt;elv1313@gmail.com&gt;
-- @copyright 2016 Emmanuel Lepage Vallee
-- @popupmod awful.wibar
-- @supermodule awful.popup
---------------------------------------------------------------------------

-- Grab environment we need
local capi =
{
    screen = screen,
    client = client
}
local setmetatable = setmetatable
local tostring = tostring
local ipairs = ipairs
local error = error
local wibox = require("wibox")
local beautiful = require("beautiful")
local gtable = require("gears.table")

local function get_screen(s)
    return s and capi.screen[s]
end

local awfulwibar = { mt = {} }

--- Array of table with wiboxes inside.
-- It's an array so it is ordered.
local wiboxes = setmetatable({}, {__mode = "v"})

local align_map = {
    top      = "left",
    left     = "top",
    bottom   = "right",
    right    = "bottom",
    centered = "centered"
}

--- If the wibar needs to be stretched to fill the screen.
--
-- @DOC_awful_wibar_stretch_EXAMPLE@
--
-- @property stretch
-- @tparam[opt=true] boolean|nil stretch
-- @propbeautiful
-- @propemits true false
-- @see align

--- How to align non-stretched wibars.
--
--  @DOC_awful_wibar_align_EXAMPLE@
--
-- @property align
-- @tparam[opt="centered"] string|nil align
-- @propertyvalue "top"
-- @propertyvalue "bottom"
-- @propertyvalue "left"
-- @propertyvalue "right"
-- @propertyvalue "centered"
-- @propbeautiful
-- @propemits true false
-- @see stretch

--- Margins on each side of the wibar.
--
-- It can either be a table with `top`, `bottom`, `left` and `right`
-- properties, or a single number that applies to all four sides.
--
-- @DOC_awful_wibar_margins_EXAMPLE@
--
-- @property margins
-- @tparam[opt=0] number|table|nil margins
-- @tparam[opt=0] number margins.left
-- @tparam[opt=0] number margins.right
-- @tparam[opt=0] number margins.top
-- @tparam[opt=0] number margins.bottom
-- @negativeallowed true
-- @propertytype number A single value for each side.
-- @propertytype table A different value for each side.
-- @propertytype nil Fallback to `beautiful.wibar_margins`.
-- @propertyunit pixel
-- @propbeautiful
-- @propemits true false

--- If the wibar needs to be stretched to fill the screen.
--
-- @beautiful beautiful.wibar_stretch
-- @tparam boolean stretch

--- Allow or deny the tiled clients to cover the wibar.
--
-- In the example below, we can see that the first screen workarea
-- shrunk by the height of the wibar while the second screen is
-- unchanged.
--
-- @DOC_screen_wibar_workarea_EXAMPLE@
--
-- @property restrict_workarea
-- @tparam[opt=true] boolean restrict_workarea
-- @propemits true false
-- @see client.struts
-- @see screen.workarea

--- The wibar border width.
-- @beautiful beautiful.wibar_border_width
-- @tparam integer border_width

--- The wibar border color.
-- @beautiful beautiful.wibar_border_color
-- @tparam string border_color

--- If the wibar is to be on top of other windows.
-- @beautiful beautiful.wibar_ontop
-- @tparam boolean ontop

--- The wibar's mouse cursor.
-- @beautiful beautiful.wibar_cursor
-- @tparam string cursor

--- The wibar opacity, between 0 and 1.
-- @beautiful beautiful.wibar_opacity
-- @tparam number opacity

--- The window type (desktop, normal, dock, …).
-- @beautiful beautiful.wibar_type
-- @tparam string type

--- The wibar's width.
-- @beautiful beautiful.wibar_width
-- @tparam integer width

--- The wibar's height.
-- @beautiful beautiful.wibar_height
-- @tparam integer height

--- The wibar's background color.
-- @beautiful beautiful.wibar_bg
-- @tparam color bg

--- The wibar's background image.
-- @beautiful beautiful.wibar_bgimage
-- @tparam surface bgimage

--- The wibar's foreground (text) color.
-- @beautiful beautiful.wibar_fg
-- @tparam color fg

--- The wibar's shape.
-- @beautiful beautiful.wibar_shape
-- @tparam gears.shape shape

--- The wibar's margins.
-- @beautiful beautiful.wibar_margins
-- @tparam number|table margins

--- The wibar's alignments.
-- @beautiful beautiful.wibar_align
-- @tparam string align


-- Tell the C side what the bar is (declare.c): the edge it sits at,
-- whether it reserves its space there, its margins, and how a bar that does
-- not stretch sits along the edge. The output declares the bar in its flow
-- at that edge, the margins as the slot's padding, and the bar's geometry
-- is what the frame solves.
local function attach(wb)
    local align = wb._private.align
    wb.drawin.bar = {
        edge    = wb.position,
        reserve = wb._private.restrict_workarea,
        margins = wb._private.margins,
        stretch = wb._stretch,
        align   = (align == "left" or align == "top") and "start"
            or (align == "right" or align == "bottom") and "end" or "centered",
    }
end

--- The wibox position.
--
-- @DOC_awful_wibar_position_EXAMPLE@
--
-- @property position
-- @tparam[opt="top"] string position
-- @propertyvalue "left"
-- @propertyvalue "right"
-- @propertyvalue "top"
-- @propertyvalue "bottom"
-- @propemits true false

function awfulwibar.get_position(wb)
    return wb._position or "top"
end

function awfulwibar.set_position(wb, position)
    if position == wb._position then return end

    -- In case the position changed, it may be necessary to reset the size
    if (wb._position == "left" or wb._position == "right")
      and (position == "top" or position == "bottom") then
        wb.height = math.ceil(beautiful.get_font_height(wb.font) * 1.5)
    elseif (wb._position == "top" or wb._position == "bottom")
      and (position == "left" or position == "right") then
        wb.width = math.ceil(beautiful.get_font_height(wb.font) * 1.5)
    end

    wb._position = position
    attach(wb)

    wb:emit_signal("property::position", position)
end

function awfulwibar.get_stretch(w)
    return w._stretch
end

function awfulwibar.set_stretch(w, value)
    w._stretch = value

    attach(w)

    w:emit_signal("property::stretch", value)
end


function awfulwibar.get_restrict_workarea(w)
    return w._private.restrict_workarea
end

function awfulwibar.set_restrict_workarea(w, value)
    w._private.restrict_workarea = value

    attach(w)

    w:emit_signal("property::restrict_workarea", value)
end


function awfulwibar.set_margins(w, value)
    if type(value) == "number" then
        value = {
            top = value,
            bottom = value,
            right = value,
            left = value,
        }
    end

    local old = gtable.crush({
        left   = 0,
        right  = 0,
        top    = 0,
        bottom = 0
    }, w._private.margins or {}, true)

   value = gtable.crush(old, value or {}, true)

    w._private.margins = value

    attach(w)

    w:emit_signal("property::margins", value)
end

-- Allow each margins to be set individually.
local function meta_margins(self)
    return setmetatable({}, {
        __index = self._private.margins,
        __newindex = function(_, k, v)
            self._private.margins[k] = v
            awfulwibar.set_margins(self, self._private.margins)
        end
    })
end

function awfulwibar.get_margins(self)
    return self._private.meta_margins
end


function awfulwibar.get_align(self)
    return self._private.align
end

function awfulwibar.set_align(self, value)
    assert(align_map[value])

    self._private.align = value

    attach(self)

    self:emit_signal("property::align", value)
end

--- Remove a wibar.
-- @method remove
-- @noreturn

function awfulwibar.remove(self)
    self.visible = false
    self.drawin.bar = nil

    for k, w in ipairs(wiboxes) do
        if w == self then
            table.remove(wiboxes, k)
        end
    end

    self._screen = nil
end


--- Create a new wibox and attach it to a screen edge.
-- You can add also position key with value top, bottom, left or right.
-- You can also use width or height in % and set align to center, right or left.
-- You can also set the screen key with a screen number to attach the wibox.
-- If not specified, the primary screen is assumed.
-- @see wibox
-- @tparam[opt=nil] table args
-- @tparam string args.position The position.
-- @tparam string args.stretch If the wibar need to be stretched to fill the screen.
-- @tparam boolean args.restrict_workarea Allow or deny the tiled clients to cover the wibar.
-- @tparam string args.align How to align non-stretched wibars.
-- @tparam table|number args.margins The wibar margins.
--@DOC_wibox_constructor_COMMON@
-- @return The new wibar
-- @constructorfct awful.wibar
-- @usebeautiful beautiful.wibar_border_width
-- @usebeautiful beautiful.wibar_border_color
-- @usebeautiful beautiful.wibar_ontop
-- @usebeautiful beautiful.wibar_cursor
-- @usebeautiful beautiful.wibar_opacity
-- @usebeautiful beautiful.wibar_type
-- @usebeautiful beautiful.wibar_width
-- @usebeautiful beautiful.wibar_height
-- @usebeautiful beautiful.wibar_bg
-- @usebeautiful beautiful.wibar_bgimage
-- @usebeautiful beautiful.wibar_fg
-- @usebeautiful beautiful.wibar_shape
function awfulwibar.new(args)
    args = args or {}
    local position = args.position or "top"
    local has_to_stretch = true
    local screen = get_screen(args.screen or 1)

    args.type = args.type or "dock"

    if position ~= "top" and position ~="bottom"
            and position ~= "left" and position ~= "right" then
        error("Invalid position in awful.wibar(), you may only use"
            .. " 'top', 'bottom', 'left' and 'right'")
    end

    -- Set default size
    if position == "left" or position == "right" then
        args.width = args.width or beautiful["wibar_width"]
            or math.ceil(beautiful.get_font_height(args.font) * 1.5)
        if args.height then
            has_to_stretch = false
            if args.screen then
                local hp = tostring(args.height):match("(%d+)%%")
                if hp then
                    args.height = math.ceil(screen.geometry.height * hp / 100)
                end
            end
        end
    else
        args.height = args.height or beautiful["wibar_height"]
            or math.ceil(beautiful.get_font_height(args.font) * 1.5)
        if args.width then
            has_to_stretch = false
            if args.screen then
                local wp = tostring(args.width):match("(%d+)%%")
                if wp then
                    args.width = math.ceil(screen.geometry.width * wp / 100)
                end
            end
        end
    end

    args.screen = nil

    -- The C code scans the table directly, so metatable magic cannot be used.
    for _, prop in ipairs {
        "border_width", "border_color", "font", "opacity", "ontop", "cursor",
        "bgimage", "bg", "fg", "type", "stretch", "shape", "margins", "align",
        "shadow"
    } do
        if (args[prop] == nil) and beautiful["wibar_"..prop] ~= nil then
            args[prop] = beautiful["wibar_"..prop]
        end
    end

    local w = wibox(args)

    w._private.align = (args.align and align_map[args.align]) and args.align or "centered"

    w._private.margins = {
        left   = 0,
        right  = 0,
        top    = 0,
        bottom = 0
    }
    w._private.meta_margins = meta_margins(w)

    w._private.restrict_workarea = true

    w.screen   = screen
    w._screen  = screen --HACK When a screen is removed, then getbycoords won't work
    w._stretch = args.stretch
    if w._stretch == nil then
        w._stretch = has_to_stretch
    end

    if args.visible == nil then
        w.visible = true
    end

    gtable.crush(w, awfulwibar, true)
    gtable.crush(w, args, false)

    awfulwibar.set_margins(w, args.margins)
    table.insert(wiboxes, w)

    assert(w.buttons)

    return w
end

capi.screen.connect_signal("removed", function(s)
    local wibars = {}
    for _, wibar in ipairs(wiboxes) do
        if wibar._screen == s then
            table.insert(wibars, wibar)
        end
    end
    for _, wibar in ipairs(wibars) do
        wibar:remove()
    end
end)

function awfulwibar.mt:__call(...)
    return awfulwibar.new(...)
end

return setmetatable(awfulwibar, awfulwibar.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
