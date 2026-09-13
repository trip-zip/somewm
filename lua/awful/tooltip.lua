-------------------------------------------------------------------------
--- Tooltip module for awesome objects.
--
-- A tooltip is a small hint displayed when the mouse cursor
-- hovers over a specific item.
-- In awesome, a tooltip can be linked with almost any
-- object having a `:connect_signal()` method and receiving
-- `mouse::enter` and `mouse::leave` signals.
--
-- How to create a tooltip?
-- ---
--
-- @DOC_awful_tooltip_textclock_EXAMPLE@
--
-- Alternatively, you can use `mouse::enter` signal:
--
-- @DOC_awful_tooltip_textclock2_EXAMPLE@
--
-- How to create a tooltip without objects?
-- ---
--
-- @DOC_awful_tooltip_mouse_EXAMPLE@
--
-- How to add the same tooltip to multiple objects?
-- ---
--
--     myclock_t:add_to_object(obj1)
--     myclock_t:add_to_object(obj2)
--
-- Now the same tooltip is attached to `myclock`, `obj1`, `obj2`.
--
-- How to remove a tooltip from several objects?
-- ---
--
--     myclock_t:remove_from_object(obj1)
--     myclock_t:remove_from_object(obj2)
--
-- Now the same tooltip is only attached to `myclock`.
--
-- @author Sébastien Gross &lt;seb•ɱɩɲʋʃ•awesome•ɑƬ•chezwam•ɖɵʈ•org&gt;
-- @copyright 2009 Sébastien Gross
-- @popupmod awful.tooltip
-- @supermodule wibox
-------------------------------------------------------------------------

local timer = require("gears.timer")
local gtable = require("gears.table")
local object = require("gears.object")
local color = require("gears.color")
local wibox = require("wibox")
local attachment = require("awful._attachment")
local a_button = require("awful.button")
local shape = require("gears.shape")
local beautiful = require("beautiful")
local dpi = require("beautiful").xresources.apply_dpi
local setmetatable = setmetatable
local ipairs = ipairs
local capi = {mouse=mouse, awesome=awesome}

local tooltip = { mt = {} }

--- The tooltip border color.
-- @beautiful beautiful.tooltip_border_color
-- @param color

--- The tooltip background color.
-- @beautiful beautiful.tooltip_bg
-- @param color

--- The tooltip foregound (text) color.
-- @beautiful beautiful.tooltip_fg
-- @param color

--- The tooltip font.
-- @beautiful beautiful.tooltip_font
-- @param string

--- The tooltip border width.
-- @beautiful beautiful.tooltip_border_width
-- @param number

--- The tooltip opacity.
-- @beautiful beautiful.tooltip_opacity
-- @tparam number opacity Between 0 and 1

--- The tooltip margins.
-- @beautiful beautiful.tooltip_gaps
-- @param table

--- The default tooltip shape.
-- The default shape for all tooltips is a rectangle. However, by setting
-- this variable they can default to rounded rectangle or stretched octagons.
-- @beautiful beautiful.tooltip_shape
-- @tparam[opt=gears.shape.rectangle] gears.shape shape A `gears.shape`
--  compatible function
-- @see shape
-- @see gears.shape

-- Content sizes itself; the opener and input gap are all placement needs.
local function set_geometry(self)
    local w = self:get_wibox()
    local gaps = self._private.gaps
    local pos = self.preferred_positions
    local anchors = self.preferred_alignments
    if self.mode == 'mouse' and not self._private.preferred_positions then
        -- Default tooltips open inward from the hover input snapshot. These
        -- select attachment points only; no tooltip or sibling rectangle is
        -- measured or corrected after the solve. Explicit positions win.
        pos = {self._private.hover_position or 'bottom'}
        if not self._private.preferred_alignments then
            anchors = {self._private.hover_anchor or 'front'}
        end
    end
    local direction = type(pos)=='table' and pos[1] or pos or 'bottom'
    local gap = type(gaps)=='number' and gaps or (gaps and gaps[direction]) or 0
    local offset = {x=direction=='left' and -gap or direction=='right' and gap or 0,
        y=direction=='top' and -gap or direction=='bottom' and gap or 0}
    self.current_position = attachment.next_to(w, self._private.target or capi.mouse.current_widget,
        pos or {'bottom'}, anchors or {'middle'}, offset, 2)
    local a=w.drawin.attachment
    a.passthrough=true; a.hover=true
    w.drawin.attachment=a
end

-- Show a tooltip.
--
-- @tparam tooltip self The tooltip to show.
local function show(self)
    -- do nothing if the tooltip is already shown
    if self._private.visible then return end
    local input = capi.mouse.coords()
    local output = capi.mouse.screen.geometry
    self._private.hover_position = input.y-output.y < output.height/2 and 'bottom' or 'top'
    self._private.hover_anchor = input.x-output.x < output.width/2 and 'front' or 'back'
    if self.timer then
        if not self.timer.started then
            self.timer:start()
            self:timer_function()
        end
    end
    set_geometry(self)
    self.wibox.visible = true
    self._private.visible = true
    self:emit_signal("property::visible")
end

-- Hide a tooltip.
--
-- @tparam tooltip self The tooltip to hide.
local function hide(self)
    -- do nothing if the tooltip is already hidden
    if not self._private.visible then return end
    if self.timer then
        if self.timer.started then
            self.timer:stop()
        end
    end
    self.wibox.visible = false
    self._private.visible = false
    self:emit_signal("property::visible")
end

--- The wibox containing the tooltip widgets.
-- @property wibox
-- @tparam wibox wibox
-- @propertydefault Autogenerated.

function tooltip:get_wibox()
    if self._private.wibox then
        return self._private.wibox
    end

    local wb = wibox(self.wibox_properties)
    wb._drawable._attachment_fit = true
    wb:set_widget(self.widget)
    wb.input_passthrough = true

    -- Close the tooltip when clicking it.  This gets done on release, to not
    -- emit the release event on an underlying object, e.g. the titlebar icon.
    wb.buttons = {
        a_button({}, 1, nil, self.hide)
    }

    self._private.wibox = wb

    return wb
end

--- Is the tooltip visible?
-- @property visible
-- @tparam[opt=true] boolean visible
-- @propemits true false

function tooltip:get_visible()
    return self._private.visible
end

function tooltip:set_visible(value)
    if self._private.visible == value then return end

    if value then
        show(self)
    else
        hide(self)
    end

    self:emit_signal("property::visible", value)
end

--- The horizontal alignment.
--
-- This is valid for the mouse mode only. For the outside mode, use
-- `preferred_positions`.
--
-- @DOC_awful_tooltip_align_EXAMPLE@
--
-- @DOC_awful_tooltip_align2_EXAMPLE@
--
-- @property align
-- @tparam[opt="right"] string|nil align
-- @propertyvalue "top_left"
-- @propertyvalue "left"
-- @propertyvalue "bottom_left"
-- @propertyvalue "right"
-- @propertyvalue "top_right"
-- @propertyvalue "bottom_right"
-- @propertyvalue "bottom"
-- @propertyvalue "top"
-- @propemits true false
-- @propbeautiful
-- @see mode
-- @see preferred_positions

--- The default tooltip alignment.
-- @beautiful beautiful.tooltip_align
-- @tparam string tooltip_align
-- @see align

function tooltip:get_align()
    return self._private.align
end

function tooltip:set_align(value)
    if not align_convert[value] then
        return
    end

    self._private.align = value

    set_geometry(self)
    self:emit_signal("property::align", value)
end

--- The shape of the tooltip window.
--
-- @DOC_awful_tooltip_shape_EXAMPLE@
--
-- @property shape
-- @tparam[opt=gears.shape.rectangle] shap|nil shape
-- @see gears.shape
-- @propemits true false
-- @propbeautiful

function tooltip:set_shape(s)
    self.backgroundbox:set_shape(s)

    self:emit_signal("property::shape", s)
end

--- Set the tooltip positioning mode.
-- Tooltips attach to their widget. The default mouse mode chooses inward
-- attachment points from the pointer input captured when opening. Outside
-- mode uses the preferred positions and alignments. Explicit preferred
-- positions also override the default mouse policy.
--
-- **mouse:**
--
-- @DOC_awful_tooltip_mode_EXAMPLE@
--
-- **outside:**
--
-- @DOC_awful_tooltip_mode2_EXAMPLE@
--
-- @property mode
-- @tparam[opt="mouse"] string mode
-- @propertyvalue "mouse" Attach inward using the opening pointer input.
-- @propertyvalue "outside" Outside of the widget.
-- @propemits true false

function tooltip:set_mode(mode)
    self._private.mode = mode

    set_geometry(self)
    self:emit_signal("property::mode", mode)
end

function tooltip:get_mode()
    return self._private.mode or "mouse"
end

--- The preferred positions when in `outside` mode.
--
-- @DOC_awful_tooltip_preferred_positions_EXAMPLE@
--
-- If the tooltip fits on multiple sides of the drawable, then this defines the
-- priority.
--
-- The valid table values are:
--
-- * "top"
-- * "right"
-- * "left"
-- * "bottom"
--
-- @property preferred_positions
-- @tparam table preferred_positions The position, ordered by priorities
-- @propertydefault `{"top", "right", "left", "bottom"}`
-- @tablerowtype A list of strings.
-- @propemits true false
-- @see align
-- @see mode
-- @see preferred_alignments

function tooltip:get_preferred_positions()
    return self._private.preferred_positions or
        {"top", "right", "left", "bottom"}
end

function tooltip:set_preferred_positions(value)
    self._private.preferred_positions = value

    set_geometry(self)

    self:emit_signal("property::preferred_positions", value)
end

--- The preferred alignment when using the `outside` mode.
--
-- The values of the table are ordered by priority, the first one that fits
-- will be used.
--
-- **front:**
--
-- @DOC_awful_tooltip_preferred_alignment_EXAMPLE@
--
-- **middle:**
--
-- @DOC_awful_tooltip_preferred_alignment2_EXAMPLE@
--
-- **back:**
--
-- @DOC_awful_tooltip_preferred_alignment3_EXAMPLE@
--
-- The valid table values are:
--
-- * "front"
-- * "middle"
-- * "back"
--
-- @property preferred_alignments
-- @tparam table preferred_alignments
-- @tablerowtype A list of strings.
-- @propertydefault `{"front", "back", "middle"}`
-- @propemits true false
-- @see preferred_positions

function tooltip:get_preferred_alignments()
    return self._private.preferred_alignments or
        {"front", "back", "middle"}
end

function tooltip:set_preferred_alignments(value)
    self._private.preferred_alignments = value

    set_geometry(self)

    self:emit_signal("property::preferred_alignments", value)
end

--- Change displayed text.
--
-- @property text
-- @tparam[opt=""] string text New tooltip text, passed to
--   `wibox.widget.textbox.set_text`.
-- @propemits true false
-- @see wibox.widget.textbox

function tooltip:set_text(text)
    self.textbox:set_text(text)
    if self._private.visible then
        set_geometry(self)
    end

    self:emit_signal("property::text", text)
end

--- Change displayed markup.
--
-- @property markup
-- @tparam[opt=""] string markup New tooltip markup, passed to
--   `wibox.widget.textbox.set_markup`.
-- @propemits true false
-- @see wibox.widget.textbox

function tooltip:set_markup(text)
    self.textbox:set_markup(text)
    if self._private.visible then
        set_geometry(self)
    end

    self:emit_signal("property::markup", text)
end

--- Change the tooltip's update interval.
--
-- @property timeout
-- @tparam[opt=1] number timeout
-- @negativeallowed false
-- @propertyunit second
-- @propemits true false

function tooltip:set_timeout(timeout)
    if self.timer then
        self.timer.timeout = timeout
    end
    self:emit_signal("property::timeout", timeout)
end

--- Set all margins around the tooltip textbox.
--
-- @DOC_awful_tooltip_margins_EXAMPLE@
--
-- @property margins
-- @tparam[opt=0] number|table margins
-- @tparam[opt=0] number margins.top
-- @tparam[opt=0] number margins.bottom
-- @tparam[opt=0] number margins.left
-- @tparam[opt=0] number margins.right
-- @negativeallowed true
-- @propertyunit pixel
-- @propertytype number A single value for each sides.
-- @propertytype table A different value for each side.
-- @propemits true false

function tooltip:set_margins(val)
    self.marginbox:set_margins(val)
    self:emit_signal("property::margins", val)
end

--- The border width.
--
-- @DOC_awful_tooltip_border_width_EXAMPLE@
--
-- @property border_width
-- @tparam[opt=0] number|nil border_width
-- @negativeallowed false
-- @propertyunit pixel
-- @propemits true false
-- @propbeautiful

function tooltip:set_border_width(val)
    self.widget.border_width = val
    self:emit_signal("property::border_width", val)
end

--- The border color.
--
-- @DOC_awful_tooltip_border_color_EXAMPLE@
--
-- @property border_color
-- @tparam[opt=beautiful.tooltip_border_color or beautiful.border_color_normal or beautiful.fg_normal]
--  color|nil border_color
-- @propemits true false
-- @propbeautiful

function tooltip:set_border_color(val)
    self.widget.border_color = val
    self:emit_signal("property::border_color", val)
end

--- Set the margins around the left and right of the tooltip textbox.
--
-- @DOC_awful_tooltip_margins_leftright_EXAMPLE@
--
-- @property margins_leftright
-- @tparam[opt=0] number margins_leftright
-- @negativeallowed true
-- @propertyunit pixel
-- @propemits true false
-- @see margins
-- @see margins_topbottom

function tooltip:set_margin_leftright(val)
    self.marginbox:set_left(val)
    self.marginbox:set_right(val)
    self:emit_signal("property::margin_leftright", val)
end

--TODO v5 deprecate this
function tooltip:set_margins_leftright(val)
    self:set_margin_leftright(val)
end

--- Set the margins around the top and bottom of the tooltip textbox.
--
-- @DOC_awful_tooltip_margins_topbottom_EXAMPLE@
--
-- @property margins_topbottom
-- @tparam[opt=0] number margins_topbottom
-- @negativeallowed true
-- @propertyunit pixel
-- @propemits true false
-- @see margins
-- @see margins_leftright

function tooltip:set_margin_topbottom(val)
    self.marginbox:set_top(val)
    self.marginbox:set_bottom(val)
    self:emit_signal("property::margin_topbottom", val)
end

--TODO v5 deprecate this
function tooltip:set_margins_topbottom(val)
    self:set_margin_topbottom(val)
end

--- Set the margins between the tooltip and its parent.
--
-- @DOC_awful_tooltip_gaps_EXAMPLE@
--
-- @property gaps
-- @tparam[opt=0] number|table|nil gaps
-- @tparam[opt=0] number gaps.top
-- @tparam[opt=0] number gaps.bottom
-- @tparam[opt=0] number gaps.left
-- @tparam[opt=0] number gaps.right
-- @negativeallowed true
-- @propertytype number A single value for each sides.
-- @propertytype table A different value for each side.
-- @propertyunit pixel
-- @propemits true false
-- @propbeautiful

function tooltip:set_gaps(val)
    self._private.gaps = val
    if self._private.visible then set_geometry(self) end
end

function tooltip:get_gaps()
    return self._private.gaps
end

--- Add tooltip to an object.
--
-- @tparam gears.object obj An object with `mouse::enter` and
--   `mouse::leave` signals.
-- @noreturn
-- @method add_to_object
function tooltip:add_to_object(obj)
    if not obj then return end

    obj:connect_signal("mouse::enter", self.show)
    obj:connect_signal("mouse::leave", self.hide)
end

--- Remove tooltip from an object.
--
-- @tparam gears.object obj An object with `mouse::enter` and
--   `mouse::leave` signals.
-- @noreturn
-- @method remove_from_object
function tooltip:remove_from_object(obj)
    obj:disconnect_signal("mouse::enter", self.show)
    obj:disconnect_signal("mouse::leave", self.hide)
end

--- Create a new tooltip and link it to a widget.
-- Tooltips emit `property::visible` when their visibility changes.
-- @tparam table args Arguments for tooltip creation.
-- @tparam function args.timer_function A function to dynamically set the
--   tooltip text.  Its return value will be passed to
--   `wibox.widget.textbox.set_markup`.
-- @tparam[opt=1] number args.timeout The timeout value for
--   `timer_function`.
-- @tparam[opt] table args.objects A list of objects linked to the tooltip.
-- @tparam[opt] number args.delay_show Delay showing the tooltip by this many
--   seconds.
-- @tparam[opt=apply_dpi(5)] integer args.margin_leftright The left/right margin for the text.
-- @tparam[opt=apply_dpi(3)] integer args.margin_topbottom The top/bottom margin for the text.
-- @tparam[opt=nil] gears.shape args.shape The shape.
-- @tparam[opt=beautiful.tooltip_bg] string args.bg The background color.
-- @tparam[opt=beautiful.tooltip_fg] string args.fg The foreground color.
-- @tparam[opt=beautiful.tooltip_border_color] string args.border_color The tooltip border color.
-- @tparam[opt=beautiful.tooltip_border_width] number args.border_width The tooltip border width.
-- @tparam[opt] string args.align The horizontal alignment.
-- @tparam[opt=beautiful.tooltip_font] string args.font The tooltip font.
-- @tparam[opt=beautiful.tooltip_opacity] number args.opacity The tooltip opacity.
-- @tparam[opt=beautiful.tooltip_gaps] table|number args.gaps The tooltip margins.
-- @treturn awful.tooltip The created tooltip.
-- @see add_to_object
-- @see timeout
-- @see text
-- @see markup
-- @see align
-- @constructorfct awful.tooltip
function tooltip.new(args)
    args = args or {}

    -- gears.object, properties are linked to set_/get_ functions
    local self = object {
        enable_properties = true,
    }

    rawset(self,"_private", {})

    self._private.visible = false
    self._private.align   = args.align or beautiful.tooltip_align  or "right"
    self._private.shape   = args.shape or beautiful.tooltip_shape
                                or shape.rectangle
    self._private.gaps  = args.gaps or beautiful.tooltip_gaps or {
        left = args.gaps or 0, right  = args.gaps or 0,
        top  = args.gaps or 0, bottom = args.gaps or 0
    }

    -- private data
    if args.delay_show then
        local delay_timeout

        delay_timeout = timer { timeout = args.delay_show }
        delay_timeout:connect_signal("timeout", function ()
            show(self)
            delay_timeout:stop()
        end)

        function self.show(other, geo)
            -- Retain the opener identity and its host across the show delay.
            self._private.target = geo or other

            if not delay_timeout.started then
                delay_timeout:start()
            end
        end
        function self.hide()
            if delay_timeout.started then
                delay_timeout:stop()
            end
            hide(self)
        end
    else
        function self.show(other, geo)
            self._private.target = geo or other

            show(self)
        end
        function self.hide()
            hide(self)
        end
    end

    -- export functions
    gtable.crush(self, tooltip, true)

    -- setup the timer action only if needed
    if args.timer_function then
        self.timer = timer { timeout = args.timeout and args.timeout or 1 }
        self.timer_function = function()
                self:set_markup(args.timer_function())
            end
        self.timer:connect_signal("timeout", self.timer_function)
    end

    -- collect tooltip properties
    -- wibox
    local fg = args.fg or beautiful.tooltip_fg or beautiful.fg_focus or "#000000"
    local opacity = args.opacity or beautiful.tooltip_opacity or 1
    -- textbox
    local font = args.font or beautiful.tooltip_font or beautiful.font
    -- marginbox
    local m_lr = args.margin_leftright or dpi(5)
    local m_tb = args.margin_topbottom or dpi(3)
    -- backgroundbox
    local bg = args.bg or beautiful.tooltip_bg
        or beautiful.bg_focus or "#ffcb60"
    local border_width = args.border_width or beautiful.tooltip_border_width or 0
    local border_color = args.border_color or beautiful.tooltip_border_color
        or beautiful.border_color_normal or "#ffcb60"

    -- Set wibox default properties
    self.wibox_properties = {
        visible = false,
        ontop = true,
        border_width = 0,
        fg = fg,
        bg = color.transparent,
        opacity = opacity,
        type = "tooltip",
    }

    self.widget = wibox.widget {
        {
            {
                id     = 'text_role',
                font   = font,
                widget = wibox.widget.textbox,
            },
            id     = 'margin_role',
            left   = m_lr,
            right  = m_lr,
            top    = m_tb,
            bottom = m_tb,
            widget = wibox.container.margin,
        },
        id           = 'background_role',
        bg           = bg,
        shape        = self._private.shape,
        border_width = border_width,
        border_color = border_color,
        widget       = wibox.container.background,
    }
    self.textbox = self.widget:get_children_by_id('text_role')[1]
    self.marginbox = self.widget:get_children_by_id('margin_role')[1]
    self.backgroundbox = self.widget:get_children_by_id('background_role')[1]

    -- Add tooltip to objects
    if args.objects then
        for _, obj in ipairs(args.objects) do
            self:add_to_object(obj)
        end
    end

    -- Apply the properties
    for k, v in pairs(args) do
        if tooltip["set_"..k] then
            self[k] = v
        end
    end

    return self
end

function tooltip.mt:__call(...)
    return tooltip.new(...)
end

--@DOC_object_COMMON@

return setmetatable(tooltip, tooltip.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
