---------------------------------------------------------------------------
-- A widget to display either plain or HTML text.
--
--@DOC_wibox_widget_defaults_textbox_EXAMPLE@
--
-- @author Uli Schlachter
-- @author dodo
-- @copyright 2010, 2011 Uli Schlachter, dodo
-- @widgetmod wibox.widget.textbox
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local clay = require("wibox.clay")
local base = require("wibox.widget.base")
local gdebug = require("gears.debug")
local beautiful = require("beautiful")
local lgi = require("lgi")
local lgi_core = require("lgi.core")
local capi = { awesome = _G.awesome }
local gtable = require("gears.table")
local Pango = lgi.Pango
local PangoCairo = lgi.PangoCairo
local setmetatable = setmetatable

local textbox = { mt = {} }

--- Set the DPI of a Pango layout
local function setup_dpi(box, dpi)
    assert(dpi, "No DPI provided")
    if box._private.dpi ~= dpi then
        box._private.dpi = dpi
        box._private.ctx:set_resolution(dpi)
        box._private.layout:context_changed()
    end
end



local function do_fit_return(self)
    local _, logical = self._private.layout:get_pixel_extents()
    if logical.width == 0 or logical.height == 0 then
        return 0, 0
    end
    return logical.width, logical.height
end


--- Get the preferred size of a textbox.
--
-- This returns the size that the textbox would use if infinite space were
-- available.
--
-- @method get_preferred_size
-- @tparam integer|screen s The screen on which the textbox will be displayed.
-- @treturn number The preferred width.
-- @treturn number The preferred height.
function textbox:get_preferred_size(s)
    return self:get_preferred_size_at_dpi(screen[s].dpi)
end

--- Get the preferred height of a textbox at a given width.
--
-- This returns the height that the textbox would use when it is limited to the
-- given width.
--
-- @method get_height_for_width
-- @tparam number width The available width.
-- @tparam integer|screen s The screen on which the textbox will be displayed.
-- @treturn number The needed height.
function textbox:get_height_for_width(width, s)
    return self:get_height_for_width_at_dpi(width, screen[s].dpi)
end

--- Get the preferred size of a textbox.
--
-- This returns the size that the textbox would use if infinite space were
-- available.
--
-- @method get_preferred_size_at_dpi
-- @tparam number dpi The DPI value to render at.
-- @treturn number The preferred width.
-- @treturn number The preferred height.
function textbox:get_preferred_size_at_dpi(dpi)
    local max_lines = 2^20
    setup_dpi(self, dpi)
    self._private.layout.width = -1 -- no width set
    self._private.layout.height = -max_lines -- show this many lines per paragraph
    return do_fit_return(self)
end

--- Get the preferred height of a textbox at a given width.
--
-- This returns the height that the textbox would use when it is limited to the
-- given width.
--
-- @method get_height_for_width_at_dpi
-- @tparam number width The available width.
-- @tparam number dpi The DPI value to render at.
-- @treturn number The needed height.
function textbox:get_height_for_width_at_dpi(width, dpi)
    local max_lines = 2^20
    setup_dpi(self, dpi)
    self._private.layout.width = Pango.units_from_double(width)
    self._private.layout.height = -max_lines -- show this many lines per paragraph
    local _, h = do_fit_return(self)
    return h
end

--- Set the text of the textbox.(with
-- [Pango markup](https://docs.gtk.org/Pango/pango_markup.html)).
--
-- @tparam string text The text to set. This can contain pango markup (e.g.
--   `<b>bold</b>`). You can use `gears.string.escape` to escape
--   parts of it.
-- @method set_markup_silently
-- @treturn[1] boolean true
-- @treturn[2] boolean false
-- @treturn[2] string Error message explaining why the markup was invalid.
function textbox:set_markup_silently(text)
    if self._private.markup == text then
        return true
    end

    local attr, parsed = Pango.parse_markup(text, -1, 0)
    -- In case of error, attr is false and parsed is a GLib.Error instance.
    if not attr then
        return false, parsed.message or tostring(parsed)
    end

    self._private.markup = text
    self._private.layout.text = parsed
    self._private.layout.attributes = attr
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::markup", text)
    return true
end

--- Set the HTML text of the textbox.
--
-- The main difference between `text` and `markup` is that `markup` is
-- able to render a small subset of HTML tags. See the
-- [Pango markup](https://docs.gtk.org/Pango/pango_markup.html)) documentation
-- to see what is and isn't valid in this property.
--
-- @DOC_wibox_widget_textbox_markup1_EXAMPLE@
--
-- The `wibox.widget.textbox` colors are usually set by wrapping into a
-- `wibox.container.background` widget, but can also be done using the
-- markup:
--
-- @DOC_wibox_widget_textbox_markup2_EXAMPLE@
--
-- @property markup
-- @tparam[opt=self.text] string markup The text to set. This can contain pango markup (e.g.
--   `<b>bold</b>`). You can use `gears.string.escape` to escape
--   parts of it.
-- @propemits true false
-- @see text

function textbox:set_markup(text)
    local success, message = self:set_markup_silently(text)
    if not success then
        gdebug.print_error(debug.traceback("Error parsing markup: "..message.."\nFailed with string: '"..text.."'"))
    end
end

function textbox:get_markup()
    return self._private.markup
end

--- Set a textbox plain text.
--
-- This property renders the text as-is, it does not interpret it:
--
-- @DOC_wibox_widget_textbox_text1_EXAMPLE@
--
-- One exception are the control characters, which are interpreted:
--
-- @DOC_wibox_widget_textbox_text2_EXAMPLE@
--
-- @property text
-- @tparam[opt=""] string text The text to display. Pango markup is ignored and shown
--  as-is.
-- @propemits true false
-- @see markup

function textbox:set_text(text)
    if self._private.layout.text == text and self._private.layout.attributes == nil then
        return
    end
    self._private.markup = nil
    self._private.layout.text = text
    self._private.layout.attributes = nil
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::text", text)
end

function textbox:get_text()
    return self._private.layout.text
end

--- Set the text ellipsize mode.
--
-- See Pango for additional details:
-- [Layout.set_ellipsize](https://docs.gtk.org/Pango/method.Layout.set_ellipsize.html)
--
--@DOC_wibox_widget_textbox_ellipsize_EXAMPLE@
--
-- @property ellipsize
-- @tparam[opt="end"] string ellipsize
-- @propertyvalue "start"
-- @propertyvalue "middle"
-- @propertyvalue "end"
-- @propertyvalue "none"
-- @propemits true false

function textbox:set_ellipsize(mode)
    local allowed = { none = "NONE", start = "START", middle = "MIDDLE", ["end"] = "END" }
    if allowed[mode] then
        if self._private.layout:get_ellipsize() == allowed[mode] then
            return
        end
        self._private.layout:set_ellipsize(allowed[mode])
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::ellipsize", mode)
    end
end

--- Set a textbox wrap mode.
--
-- @DOC_wibox_widget_textbox_wrap1_EXAMPLE@
--
-- @property wrap
-- @tparam[opt="word_char"] string wrap Where to wrap? After "word", "char" or "word_char".
-- @propertyvalue "word"
-- @propertyvalue "char"
-- @propertyvalue "word_char"
-- @propemits true false

function textbox:set_wrap(mode)
    local allowed = { word = "WORD", char = "CHAR", word_char = "WORD_CHAR" }
    if allowed[mode] then
        if self._private.layout:get_wrap() == allowed[mode] then
            return
        end
        self._private.layout:set_wrap(allowed[mode])
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::wrap", mode)
    end
end

--- The vertical text alignment.
--
-- This aligns the text within the widget's bounds. In some situations this may
-- differ from aligning the widget with `wibox.container.place`.
--
--@DOC_wibox_widget_textbox_valign1_EXAMPLE@
--
-- @property valign
-- @tparam[opt="center"] string valign
-- @propertyvalue "top"
-- @propertyvalue "center"
-- @propertyvalue "bottom"
-- @propemits true false

function textbox:set_valign(mode)
    local allowed = { top = true, center = true, bottom = true }
    if allowed[mode] then
        if self._private.valign == mode then
            return
        end
        self._private.valign = mode
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::valign", mode)
    end
end

--- The horizontal text alignment.
--
-- This aligns the text within the widget's bounds. In some situations this may
-- differ from aligning the widget with `wibox.container.place`.
--
--@DOC_wibox_widget_textbox_align1_EXAMPLE@
--
-- @property halign
-- @tparam[opt="left"] string halign
-- @propertyvalue "left"
-- @propertyvalue "center"
-- @propertyvalue "right"
-- @propemits true false

function textbox:set_halign(mode)
    local allowed = { left = "LEFT", center = "CENTER", right = "RIGHT" }
    if allowed[mode] then
        if self._private.layout:get_alignment() == allowed[mode] then
            return
        end
        self._private.layout:set_alignment(allowed[mode])
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::halign", mode)
    end
end

--- Set a textbox font.
--
-- There is multiple valid font string representation. The most precise is
-- [XFT](https://wiki.archlinux.org/title/X_Logical_Font_Description). It
-- is also possible to use the family name, followed by the face and size
-- such as `Monospace Bold 10`. This script lists the fonts present
-- on your system:
--
--    #!/usr/bin/env lua
--
--    local lgi = require("lgi")
--    local pangocairo = lgi.PangoCairo
--
--    local font_map = pangocairo.font_map_get_default()
--
--    for k, v in pairs(font_map:list_families()) do
--        print(v:get_name(), "monospace?: "..tostring(v:is_monospace()))
--        for k2, v2 in ipairs(v:list_faces()) do
--            print("    ".. v2:get_face_name())
--        end
--    end
--
-- Save this script somewhere on your system, `chmod +x` it and run it. It
-- will list something like:
--
--    Sans    monospace?: false
--        Regular
--        Bold
--        Italic
--        Bold Italic
--
-- In this case, the font could be `Sans 10` or `Sans Bold Italic 10`.
--
-- Here are examples of several font families:
--
--@DOC_wibox_widget_textbox_font1_EXAMPLE@
--
-- The font size is a number at the end of the font description string:
--
--@DOC_wibox_widget_textbox_font2_EXAMPLE@
--
-- @property font
-- @tparam[opt=beautiful.font] font font
-- @propemits true false
-- @usebeautiful beautiful.font The default font.

function textbox:set_font(font)
    if font == self._private.font then return end

    self._private.font = font

    self._private.layout:set_font_description(beautiful.get_font(font))
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::font", font)
end

function textbox:get_font()
    return self._private.font
end

--- Set the distance between the lines.
--
--@DOC_wibox_widget_textbox_line_spacing_EXAMPLE@
--
-- Please note that the Pango version (one of AwesomeWM dependency) must be at
-- least 1.44 for this to work.
--
-- @property line_spacing_factor
-- @tparam[opt=nil] number|nil line_spacing_factor
-- @propertyunit Distance between lines as a ratio of the line height. `1.0` means
--  no spacing. Less than `1.0` will squash the lines and more than `1.0` will move
--  them further apart.
-- @propertytype nil Automatic (most probably `1.0`).
-- @negativeallowed false
-- @propemits true false

function textbox:set_line_spacing_factor(spacing)
    if not pcall(function() return self._private.layout.set_line_spacing ~= nil end) then
        gdebug.print_error(debug.traceback(
            "Error your version of Pango is too old to support line_spacing"
        ))
    end

    spacing = spacing or 0
    self._private.layout:set_line_spacing(spacing)
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::line_spacing", spacing)
end

function textbox:get_line_spacing_factor()
    return self._private.layout:get_line_spacing()
end

--- Justify the text when there is more space.
--
--@DOC_wibox_widget_textbox_justify_EXAMPLE@
--
-- @property justify
-- @tparam[opt=false] boolean justify
-- @propemits true false

function textbox:set_justify(justify)
    self._private.layout:set_justify(justify)
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::justify", justify)
end

function textbox:get_justify()
    return self._private.layout:get_justify()
end

--- How to indent text with multiple lines.
--
-- Note that this does nothing if `halign == "center"`.
--
--@DOC_wibox_widget_textbox_indent_EXAMPLE@
--
-- @property indent
-- @tparam[opt=0.0] number indent
-- @propertyunit points
-- @negativeallowed true
-- @propemits true false

function textbox:set_indent(indent)
    self._private.layout:set_indent(Pango.units_from_double(indent))
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::indent", indent)
end

function textbox:get_indent()
    return self._private.layout:get_indent()
end

--- Create a new textbox.
--
-- @tparam[opt=""] string text The textbox content
-- @tparam[opt=false] boolean ignore_markup Ignore the pango/HTML markup
-- @treturn table A new textbox widget
-- @constructorfct wibox.widget.textbox
local function new(text, ignore_markup)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, textbox, true)

    ret._private.dpi = -1
    ret._private.ctx = PangoCairo.font_map_get_default():create_context()
    ret._private.layout = Pango.Layout.new(ret._private.ctx)
    ret._private.layout:set_font_description(beautiful.get_font(beautiful.font))

    ret:set_ellipsize("end")
    ret:set_wrap("word_char")
    ret:set_valign("center")
    ret:set_halign("left")

    if text then
        if ignore_markup then
            ret:set_text(text)
        else
            ret:set_markup(text)
        end
    end

    return ret
end

function textbox.mt.__call(_, ...)
    return new(...)
end

--- Get geometry of text label, as if textbox would be created for it on the screen.
--
-- @tparam string text The text content, pango markup supported.
-- @tparam[opt=nil] integer|screen s The screen on which the textbox would be displayed.
-- @tparam[opt=beautiful.font] string font The font description as string.
-- @treturn table Geometry (width, height) hashtable.
-- @staticfct wibox.widget.textbox.get_markup_geometry
function textbox.get_markup_geometry(text, s, font)
    font = font or beautiful.font
    local pctx = PangoCairo.font_map_get_default():create_context()
    local playout = Pango.Layout.new(pctx)
    playout:set_font_description(beautiful.get_font(font))
    local dpi_scale = beautiful.xresources.get_dpi(s)
    pctx:set_resolution(dpi_scale)
    playout:context_changed()
    local attr, parsed = Pango.parse_markup(text, -1, 0)
    playout.attributes, playout.text = attr, parsed
    local _, logical = playout:get_pixel_extents()
    return logical
end

--- The color a Pango foreground attribute names, straight alpha 0-1.
local function attr_rgba(attr)
    local c = lgi_core.record.cast(attr, Pango.AttrColor).color

    return { c.red / 65535, c.green / 65535, c.blue / 65535, 1 }
end

local function same_rgba(a, b)
    if not a or not b then
        return a == b
    end
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

--- Pango attributes a Clay text element has no field for.
local unsupported_attrs = {
    "UNDERLINE", "STRIKETHROUGH", "RISE", "SHAPE", "SCALE", "LETTER_SPACING",
    "BACKGROUND", "FOREGROUND_ALPHA", "BACKGROUND_ALPHA", "LINE_HEIGHT",
}

--- The text with the first run's font and color. Unsupported attributes
-- are ignored (third_party/clay.h:374-398). Pango's own
-- attribute iterator answers, so a `<span font_desc color>` around escaped
-- text, which is what the taglist and tasklist labels are, is one run.
local function text_run(w, layout)
    local text = layout.text or ""
    local desc = layout:get_font_description()
    local attrs = layout.attributes

    desc = desc and desc:copy() or Pango.FontDescription.new()
    if not attrs then
        return text, desc, nil
    end

    local it = attrs:get_iterator()
    local run_desc, run_color, first

    first = true
    repeat
        local start = it:range()

        if start < #text then
            for _, name in ipairs(unsupported_attrs) do
                if Pango.AttrType[name] and it:get(Pango.AttrType[name]) then
                    clay.ignore(w, "markup", "uses an attribute a text element has no field for, which is not drawn")
                end
            end

            local d = desc:copy()
            local fg = it:get(Pango.AttrType.FOREGROUND)
            local color = fg and attr_rgba(fg) or nil

            it:get_font(d, nil, nil)
            if first then
                run_desc, run_color, first = d, color, false
            elseif d:to_string() ~= run_desc:to_string()
                    or not same_rgba(color, run_color) then
                clay.ignore(w, "markup", "has more than one run and is drawn as one")
            end
        end
    until not it:next()
    return text, run_desc or desc, run_color
end

--- wibox.widget.textbox -> an element aligning one CLAY_TEXT child, which
-- is what Clay's own examples make of a label: `CLAY({ .layout = {
-- .childAlignment } }) { CLAY_TEXT(text, CLAY_TEXT_CONFIG({ .fontId,
-- .textColor, .wrapMode, .textAlignment })) }`. The face is interned with
-- an absolute size at the context's dpi (render_text.h), since Clay's
-- fontSize is a whole number (third_party/clay.h:374-398). Clay wraps by
-- words and never by character, and the renderer ellipsizes a line at its
-- clip. What a text config has no field for is ignored: markup uses the
-- first font and color, justify, indent and line spacing are not applied,
-- and start and middle ellipses use the end. Only a face that cannot be
-- interned is refused.
local function describe_textbox(w, fg, st)
    local p = w._private
    local layout = p.layout

    -- An empty textbox draws nothing and takes no size of its own.
    if (layout.text or "") == "" then
        return {}
    end
    if layout:get_justify() then
        clay.ignore(w, "justify", "is not applied")
    end
    if layout:get_indent() ~= 0 then
        clay.ignore(w, "indent", "is not applied")
    end
    if layout:get_line_spacing() ~= 0 then
        clay.ignore(w, "line_spacing", "is not applied")
    end

    local ellipsize = layout:get_ellipsize()

    if ellipsize ~= "NONE" and ellipsize ~= "END" then
        clay.ignore(w, "ellipsize", "start and middle ellipsize at the end")
        ellipsize = "END"
    end

    local text, desc, color = text_run(w, layout)
    color = color or clay.solid_rgba(fg)
    if not color then
        clay.ignore(w, "fg", "is not solid and the text is transparent")
        color = { 0, 0, 0, 0 }
    end

    local size = desc:get_size() / Pango.SCALE

    if size <= 0 then
        clay.ignore(w, "font", "has no size and the text is not drawn")
        return {}
    end
    if not desc:get_size_is_absolute() then
        size = size * st.context.dpi / 72
    end
    desc:set_absolute_size(size * Pango.SCALE)

    local font = capi.awesome._clay_font(desc:to_string())

    if not font then
        return clay.refuse(w, "font", "could not be interned")
    end

    local halign = ({ LEFT = "left", CENTER = "center", RIGHT = "right" })
        [layout:get_alignment()] or "left"

    return { align = { x = halign, y = p.valign or "center" },
        specs = { { text = text, font = font, color = color, wrap = "words",
            halign = halign, ellipsize = ellipsize == "END", class = "text" } } }
end

textbox._clay = { describe = describe_textbox }

return setmetatable(textbox, textbox.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
