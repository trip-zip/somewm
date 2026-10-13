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
-- The layout accessors a textbox calls each time it changes, resolved once:
-- a method or property looked up on the layout goes through lgi's element
-- search, a string match per call.
local Layout = Pango.Layout
local get_layout_text, set_layout_text = Layout.get_text, Layout.set_text
local get_attributes, set_attributes = Layout.get_attributes, Layout.set_attributes
local get_font_description, get_justify, get_indent = Layout.get_font_description,
    Layout.get_justify, Layout.get_indent
local get_line_spacing, get_ellipsize, get_alignment = Layout.get_line_spacing,
    Layout.get_ellipsize, Layout.get_alignment

local textbox = { mt = {} }

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
    set_layout_text(self._private.layout, parsed)
    set_attributes(self._private.layout, attr)
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
    local layout = self._private.layout
    if get_layout_text(layout) == text and get_attributes(layout) == nil then
        return
    end
    self._private.markup = nil
    set_layout_text(layout, text)
    set_attributes(layout, nil)
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
-- Clay wraps text at words in every mode; "char" warns once that it does.
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
    if mode == "char" then clay.ignore(self, "wrap", 'is "char" and wraps at words') end
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

    self._private.layout:set_font_description(beautiful.get_font(font))
    self._private.font = font
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

    local function invalidate_text_inputs()
        ret._private.clay_text_inputs = nil
    end
    ret:connect_signal("widget::redraw_needed", invalidate_text_inputs)
    ret:connect_signal("widget::layout_changed", invalidate_text_inputs)

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

--- A Pango colour attribute, straight alpha 0-1.
local function attr_rgba(attr)
    local c = lgi_core.record.cast(attr, Pango.AttrColor).color

    return { c.red / 65535, c.green / 65535, c.blue / 65535, 1 }
end

local unsupported_attrs = { "RISE", "SHAPE", "SCALE", "LETTER_SPACING", "LINE_HEIGHT" }
local draw_attrs = { "FOREGROUND", "FOREGROUND_ALPHA", "BACKGROUND",
    "BACKGROUND_ALPHA", "UNDERLINE", "STRIKETHROUGH" }

--- Keep the first font and collect metric-neutral attributes at byte ranges.
local function text_run(w, layout)
    local text = get_layout_text(layout) or ""
    local desc = get_font_description(layout)
    local attrs = get_attributes(layout)

    desc = desc or Pango.FontDescription.new()
    if not attrs then
        return text, desc, nil
    end

    local it = attrs:get_iterator()
    -- Plain calendar labels also come through set_markup, which retains an
    -- empty AttrList. Do not query every unsupported attribute/font override
    -- when Pango says this one empty range covers the whole text.
    local start, finish = it:range()
    if start == 0 and finish >= #text and #it:get_attrs() == 0 then
        return text, desc, nil
    end
    local run_desc, run_color, first
    local runs = {}

    first = true
    repeat
        local start, finish = it:range()

        if start < #text then
            for _, name in ipairs(unsupported_attrs) do
                if Pango.AttrType[name] and it:get(Pango.AttrType[name]) then
                    clay.ignore(w, "markup", "uses an attribute a text element has no field for, which is not drawn")
                end
            end

            for kind, name in ipairs(draw_attrs) do
                local attr = it:get(Pango.AttrType[name])
                if attr then
                    local value
                    if name == "FOREGROUND" or name == "BACKGROUND" then
                        value = attr_rgba(attr)
                    else
                        local v = lgi_core.record.cast(attr, Pango.AttrInt).value
                        if name == "FOREGROUND_ALPHA" or name == "BACKGROUND_ALPHA" then
                            v = v / 65535
                        end
                        value = { v, 0, 0, 0 }
                    end
                    runs[#runs + 1] = start
                    runs[#runs + 1] = math.min(finish, #text)
                    runs[#runs + 1] = kind - 1
                    for i = 1, 4 do runs[#runs + 1] = value[i] end
                end
            end

            local d = desc:copy()
            local fg = it:get(Pango.AttrType.FOREGROUND)
            local color = fg and attr_rgba(fg) or nil

            it:get_font(d, nil, nil)
            if first then
                run_desc, run_color, first = d, color, false
            elseif d:to_string() ~= run_desc:to_string() then
                clay.ignore(w, "markup", "has more than one run and is drawn as one")
            end
        end
    until not it:next()
    return text, run_desc or desc, run_color, #runs > 0 and runs or nil
end

--- wibox.widget.textbox -> an element aligning one CLAY_TEXT child, which
-- is what Clay's own examples make of a label: `CLAY({ .layout = {
-- .childAlignment } }) { CLAY_TEXT(text, CLAY_TEXT_CONFIG({ .fontId,
-- .textColor, .wrapMode, .textAlignment })) }`. The face is interned with
-- an absolute size at the context's dpi (render_text.h), since Clay's
-- fontSize is a whole number (third_party/clay.h:374-398). Clay wraps by
-- words and never by character, and the renderer ellipsizes a line at its
-- clip. Markup uses the first font; colour, alpha, background, underline and strikethrough spans
-- draw at raster time. Justify, indent and line spacing are not applied,
-- and start and middle ellipses use the end. Only a face that cannot be
-- interned is refused.
-- Pango inputs do not depend on a grid's natural/minimum/height offer.
-- Cache only the semantic text inputs, never declarations or solved geometry.
-- Widget signals invalidate content/style; DPI has its own cache key. Fit calls
-- only change Pango's measurement offer, not these semantic inputs.
local font_inputs = setmetatable({}, { __mode = "v" })

local function text_inputs(w, dpi)
    local p = w._private
    local layout = p.layout
    local cached = p.clay_text_inputs
    if cached and cached.dpi == dpi then
        return cached
    end

    -- An empty textbox draws nothing and takes no size of its own.
    if (get_layout_text(layout) or "") == "" then
        return {}
    end
    if get_justify(layout) then
        clay.ignore(w, "justify", "is not applied")
    end
    if get_indent(layout) ~= 0 then
        clay.ignore(w, "indent", "is not applied")
    end
    if get_line_spacing(layout) ~= 0 then
        clay.ignore(w, "line_spacing", "is not applied")
    end

    local ellipsize = get_ellipsize(layout)

    if ellipsize ~= "NONE" and ellipsize ~= "END" then
        clay.ignore(w, "ellipsize", "start and middle ellipsize at the end")
        ellipsize = "END"
    end

    local text, desc, color, attrs = text_run(w, layout)
    -- Equal descriptions at the same DPI name the same native font. Keep this
    -- immutable input alive with its textboxes; neither layout offers nor text
    -- content affect it. Copy before scaling so Pango's layout stays untouched.
    local font_key = tostring(dpi) .. ":" .. desc:to_string()
    local font_input = font_inputs[font_key]
    if not font_input or font_input.provider ~= capi.awesome._clay_font then
        local size = desc:get_size() / Pango.SCALE
        if size <= 0 then
            clay.ignore(w, "font", "has no size and the text is not drawn")
            return {}
        end
        if not desc:get_size_is_absolute() then size = size * dpi / 72 end
        desc = desc:copy()
        desc:set_absolute_size(size * Pango.SCALE)
        local font = capi.awesome._clay_font(desc:to_string())
        if not font then return clay.refuse(w, "font", "could not be interned") end
        font_input = {font = font, provider = capi.awesome._clay_font}
        font_inputs[font_key] = font_input
    end

    local halign = ({ LEFT = "left", CENTER = "center", RIGHT = "right" })
        [get_alignment(layout)] or "left"

    cached = { dpi = dpi, text = text, font = font_input.font, font_input = font_input,
        color = color, attrs = attrs, halign = halign, ellipsize = ellipsize == "END" }
    p.clay_text_inputs = cached
    return cached
end

local function describe_textbox(w, fg, st)
    local inputs = text_inputs(w, st.context.dpi)
    if not inputs then return nil end
    if not inputs.text then return {} end
    -- The compiler may fade the declaration's color; keep cached input private.
    local c = inputs.color
    if not c then
        -- Solid Cairo patterns have immutable RGBA, as do color strings.
        -- Color specification tables can be edited in place and are re-read.
        local cacheable = type(fg) == "string" or type(fg) == "userdata"
        if cacheable and inputs.fg == fg then
            c = inputs.fg_color
        else
            c = clay.solid_rgba(fg)
            if cacheable then inputs.fg, inputs.fg_color = fg, c end
        end
    end
    local color = c and { c[1], c[2], c[3], c[4] }
    if not color then
        clay.ignore(w, "fg", "is not solid and the text is transparent")
        color = { 0, 0, 0, 0 }
    end
    return { align = { x = inputs.halign, y = w._private.valign or "center" },
        specs = { { text = inputs.text, font = inputs.font, color = color, attrs = inputs.attrs, wrap = "words",
            halign = inputs.halign, ellipsize = inputs.ellipsize, name = "text" } } }
end

textbox._clay = { describe = describe_textbox }

return setmetatable(textbox, textbox.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
