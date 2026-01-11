---------------------------------------------------------------------------
-- Container for the various system tray icons.
--
-- This is a reimplementation for Wayland/SNI that uses individual widgets
-- for each systray icon, allowing full styling control unlike X11 XEmbed.
--
-- @author Uli Schlachter
-- @author somewm contributors
-- @copyright 2010 Uli Schlachter
-- @widgetmod wibox.widget.systray
-- @supermodule wibox.layout.fixed
---------------------------------------------------------------------------

local fixed = require("wibox.layout.fixed")
local drawable = require("wibox.drawable")
local beautiful = require("beautiful")
local gtable = require("gears.table")
local gcolor = require("gears.color")
local base = require("wibox.widget.base")
local capi = {
    awesome = awesome,
    screen = screen,
    systray_item = systray_item,
}
local setmetatable = setmetatable

local systray = { mt = {} }

local instance = nil
local horizontal = true
local base_size = nil
local reverse = false
local display_on_screen = "primary"

--- The systray background color.
--
-- @beautiful beautiful.bg_systray
-- @tparam string bg_systray The color (string like "#ff0000" only)

--- The maximum number of rows for systray icons.
--
-- @beautiful beautiful.systray_max_rows
-- @tparam[opt=1] integer systray_max_rows The positive number of rows.

--- The systray icon spacing.
--
-- @beautiful beautiful.systray_icon_spacing
-- @tparam[opt=0] integer systray_icon_spacing The icon spacing

--- The systray paddings (space around icons).
--
-- @beautiful beautiful.systray_paddings
-- @tparam[opt=0] integer systray_paddings The padding around the systray

local function should_display_on(s)
    if display_on_screen == "primary" then
        return s == capi.screen.primary
    end
    return s == display_on_screen
end

-- Check if the function was called like :foo() or .foo() and do the right thing
local function get_args(self, ...)
    if self == instance then
        return ...
    end
    return self, ...
end

--- Set the size of a single icon.
--
-- If this is set to nil, then the size is picked dynamically based on the
-- available space. Otherwise, any single icon has a size of `size`x`size`.
--
-- @property base_size
-- @tparam[opt=nil] integer|nil base_size
-- @propertytype integer The size.
-- @propertytype nil Select the size based on the availible space.
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false

function systray:set_base_size(size)
    base_size = get_args(self, size)
    if instance then
        instance:_update_icon_sizes()
        instance:emit_signal("widget::layout_changed")
        instance:emit_signal("property::base_size", size)
    end
end

--- Decide between horizontal or vertical display.
--
-- @property horizontal
-- @tparam[opt=true] boolean horizontal
-- @propemits true false

function systray:set_horizontal(horiz)
    horizontal = get_args(self, horiz)
    if instance then
        -- Note: Changing direction after creation requires recreating the widget
        -- The horizontal setting primarily affects widget creation
        instance:emit_signal("widget::layout_changed")
        instance:emit_signal("property::horizontal", horiz)
    end
end

--- Should the systray icons be displayed in reverse order?
--
-- @property reverse
-- @tparam[opt=false] boolean reverse
-- @propemits true false

function systray:set_reverse(rev)
    reverse = get_args(self, rev)
    if instance then
        instance:_sync_items()
        instance:emit_signal("property::reverse", rev)
    end
end

--- Set the screen that the systray should be displayed on.
--
-- This can either be a screen, in which case the systray will be displayed on
-- exactly that screen, or the string `"primary"`, in which case it will be
-- visible on the primary screen. The default value is "primary".
--
-- @property screen
-- @tparam[opt=nil] screen|nil screen
-- @propertytype nil Valid as long as the `systray` widget is only being displayed
--  on a single screen.
-- @propemits true false

function systray:set_screen(s)
    display_on_screen = get_args(self, s)
    if instance then
        instance:emit_signal("widget::layout_changed")
        instance:emit_signal("property::screen", s)
    end
end

--- Private API. Called when systray is removed from a drawable.
-- @method _kickout
-- @hidden
function systray:_kickout(context)
    -- For SNI-based systray, we don't need to do anything special
    -- as each icon is a separate widget
end

--- Update icon sizes based on base_size setting.
-- @method _update_icon_sizes
-- @hidden
function systray:_update_icon_sizes()
    local size = base_size or 24
    local spacing = beautiful.systray_icon_spacing or 0

    self:set_spacing(spacing)

    for _, widget in ipairs(self:get_children()) do
        if widget.set_forced_size then
            widget:set_forced_size(size)
        end
    end
end

--- Sync child widgets with current systray items.
-- @method _sync_items
-- @hidden
function systray:_sync_items()
    -- Lazy-load systray_icon to avoid circular dependency
    local systray_icon = require("wibox.widget.systray_icon")

    local items = capi.systray_item and capi.systray_item.get_items() or {}
    local current_widgets = self._private.icon_widgets or {}
    local new_widgets = {}

    -- Build set of current item IDs
    local item_set = {}
    for _, item in ipairs(items) do
        item_set[item] = true
    end

    -- Remove widgets for items that no longer exist
    for item, widget in pairs(current_widgets) do
        if not item_set[item] then
            self:remove_widgets(widget)
        else
            new_widgets[item] = widget
        end
    end

    -- Add widgets for new items
    for _, item in ipairs(items) do
        if not new_widgets[item] then
            local widget = systray_icon(item)
            local size = base_size or 24
            widget:set_forced_size(size)
            new_widgets[item] = widget
        end
    end

    -- Clear and re-add in correct order
    self:reset()

    local ordered_items = items
    if reverse then
        ordered_items = {}
        for i = #items, 1, -1 do
            table.insert(ordered_items, items[i])
        end
    end

    for _, item in ipairs(ordered_items) do
        local widget = new_widgets[item]
        if widget then
            self:add(widget)
        end
    end

    self._private.icon_widgets = new_widgets
    self:_update_icon_sizes()
end

--- Create the systray widget.
--
-- Note that this widget can only exist once.
--
-- @tparam boolean reverse Show in the opposite direction
-- @treturn table The new `systray` widget
-- @constructorfct wibox.widget.systray
-- @usebeautiful beautiful.bg_systray
-- @usebeautiful beautiful.systray_icon_spacing
-- @usebeautiful beautiful.systray_max_rows

local function new(revers)
    -- Create a fixed layout as the base
    local ret = horizontal and fixed.horizontal() or fixed.vertical()

    gtable.crush(ret, systray, true)

    ret._private.icon_widgets = {}

    if revers then
        reverse = true
    end

    -- Set initial spacing
    local spacing = beautiful.systray_icon_spacing or 0
    ret:set_spacing(spacing)

    -- Override draw to paint background (beautiful.bg_systray)
    local orig_draw = ret.draw
    function ret:draw(context, cr, width, height)
        local bg = beautiful.bg_systray
        if bg then
            cr:set_source(gcolor(bg))
            cr:rectangle(0, 0, width, height)
            cr:fill()
        end
        -- Note: padding offset is handled in layout(), draw just paints bg
        if orig_draw then
            orig_draw(self, context, cr, width, height)
        end
    end

    -- Override layout for systray_max_rows grid arrangement + padding
    local orig_layout = ret.layout
    function ret:layout(context, width, height)
        local padding = beautiful.systray_paddings or 0
        local max_rows = math.floor(tonumber(beautiful.systray_max_rows) or 1)

        if max_rows <= 1 then
            -- Use original fixed layout behavior, but offset by padding
            local orig_result = orig_layout(self, context, width - padding * 2, height - padding * 2)
            if padding > 0 and orig_result then
                -- Offset all widgets by padding
                local result = {}
                for _, item in ipairs(orig_result) do
                    local widget, x, y, w, h = item[1], item[2], item[3], item[4], item[5]
                    table.insert(result, base.place_widget_at(widget, x + padding, y + padding, w, h))
                end
                return result
            end
            return orig_result
        end

        -- Grid layout for multiple rows
        local children = self:get_children()
        local num_entries = #children
        if num_entries == 0 then return {} end

        local icon_spacing = beautiful.systray_icon_spacing or 0
        local icon_size = base_size or 24

        -- Calculate rows/cols
        local rows = math.min(num_entries, max_rows)
        local cols = math.ceil(num_entries / rows)

        local result = {}
        for i, widget in ipairs(children) do
            local idx = i - 1
            local row, col
            if horizontal then
                -- Fill columns first (top to bottom, then left to right)
                col = math.floor(idx / rows)
                row = idx % rows
            else
                -- Fill rows first (left to right, then top to bottom)
                row = math.floor(idx / cols)
                col = idx % cols
            end

            local x = padding + col * (icon_size + icon_spacing)
            local y = padding + row * (icon_size + icon_spacing)

            table.insert(result, base.place_widget_at(widget, x, y, icon_size, icon_size))
        end
        return result
    end

    -- Override fit for systray_max_rows grid sizing + padding + minimum size
    local orig_fit = ret.fit
    function ret:fit(context, width, height)
        local padding = beautiful.systray_paddings or 0
        local max_rows = math.floor(tonumber(beautiful.systray_max_rows) or 1)
        local icon_size = base_size or 24

        -- Minimum size: at least show padding + one icon slot (for empty systray visibility)
        local min_size = padding * 2 + icon_size

        if max_rows <= 1 then
            -- Use original fixed layout behavior + padding
            local w, h = orig_fit(self, context, width, height)
            -- Add padding and ensure minimum size
            w = math.max(w + padding * 2, min_size)
            h = math.max(h + padding * 2, icon_size + padding * 2)
            return w, h
        end

        -- Grid fit for multiple rows
        local children = self:get_children()
        local num_entries = #children

        local icon_spacing = beautiful.systray_icon_spacing or 0

        -- If empty, return minimum size
        if num_entries == 0 then
            return min_size, icon_size + padding * 2
        end

        -- Calculate rows/cols
        local rows = math.min(num_entries, max_rows)
        local cols = math.ceil(num_entries / rows)

        local total_width = cols * icon_size + (cols - 1) * icon_spacing + padding * 2
        local total_height = rows * icon_size + (rows - 1) * icon_spacing + padding * 2

        if horizontal then
            return total_width, total_height
        else
            return total_height, total_width
        end
    end

    -- Sync items when systray updates
    capi.awesome.connect_signal("systray::update", function()
        ret:_sync_items()
    end)

    -- Handle primary screen changes
    capi.screen.connect_signal("primary_changed", function()
        if display_on_screen == "primary" then
            ret:emit_signal("widget::layout_changed")
        end
    end)

    -- Initial sync
    ret:_sync_items()

    -- Register with drawable system for AwesomeWM compatibility
    drawable._set_systray_widget(ret)

    return ret
end

function systray.mt:__call(...)
    if not instance then
        instance = new(...)
    end
    return instance
end

return setmetatable(systray, systray.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
