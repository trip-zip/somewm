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
local layout = require("somewm.layout")
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

-- Build the systray's icon grid as a somewm.layout tree: a padded
-- row-of-columns when horizontal (icons fill each column top-to-bottom, then
-- columns left-to-right), a column-of-rows when vertical. Every icon is a
-- fixed icon_size cell, gaps are icon_spacing, the outer container insets by
-- padding. :layout solves this tree and :fit reports the same bounding box.
local function systray_grid(children, padding, icon_size, icon_spacing, max_rows, horiz)
    local n = #children
    local rows = math.min(n, max_rows)
    if rows < 1 then rows = 1 end
    local cols = math.ceil(n / rows)

    local lines = {}
    if horiz then
        for c = 0, cols - 1 do
            local cell = {}
            for r = 0, rows - 1 do
                local idx = c * rows + r + 1
                if idx <= n then
                    cell[#cell + 1] = layout.widget(children[idx],
                        { width = icon_size, height = icon_size })
                end
            end
            lines[#lines + 1] = layout.column { width = icon_size, gap = icon_spacing, cell }
        end
        return layout.row { padding = padding, gap = icon_spacing, lines }
    end

    for r = 0, rows - 1 do
        local cell = {}
        for c = 0, cols - 1 do
            local idx = r * cols + c + 1
            if idx <= n then
                cell[#cell + 1] = layout.widget(children[idx],
                    { width = icon_size, height = icon_size })
            end
        end
        lines[#lines + 1] = layout.row { height = icon_size, gap = icon_spacing, cell }
    end
    return layout.column { padding = padding, gap = icon_spacing, lines }
end

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

    local all_items = capi.systray_item and capi.systray_item.get_items() or {}

    -- BEH-8: Hide items with Passive status
    local items = {}
    local item_set = {}
    for _, item in ipairs(all_items) do
        if item.status ~= "Passive" then
            table.insert(items, item)
            item_set[item] = true
        end
    end

    local current_widgets = self._private.icon_widgets or {}
    local new_widgets = {}

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

    -- Lay icons out as a padded grid through somewm.layout. One descriptor
    -- feeds both :layout and :fit, so size and placement agree by
    -- construction (and there's no positional-tuple misread of placements).
    function ret:layout(_context, width, height)
        local children = self:get_children()
        if #children == 0 then return {} end

        local padding      = beautiful.systray_paddings or 0
        local max_rows     = math.floor(tonumber(beautiful.systray_max_rows) or 1)
        local icon_spacing = beautiful.systray_icon_spacing or 0
        local icon_size    = base_size or 24

        local tree = systray_grid(children, padding, icon_size, icon_spacing,
            max_rows, horizontal)
        return base.place_rects(layout.solve {
            source = "wibox",
            width  = width,
            height = height,
            root   = tree,
        }.placements)
    end

    -- Report the same bounding box the grid tree solves to. Empty: reserve
    -- one padded icon slot so the tray stays visible.
    function ret:fit(_context, _width, _height)
        local children     = self:get_children()
        local n            = #children
        local padding      = beautiful.systray_paddings or 0
        local max_rows     = math.floor(tonumber(beautiful.systray_max_rows) or 1)
        local icon_spacing = beautiful.systray_icon_spacing or 0
        local icon_size    = base_size or 24
        local min_size     = padding * 2 + icon_size

        if n == 0 then
            return min_size, min_size
        end

        local rows = math.min(n, max_rows)
        if rows < 1 then rows = 1 end
        local cols = math.ceil(n / rows)

        local along  = cols * icon_size + (cols - 1) * icon_spacing + padding * 2
        local across = rows * icon_size + (rows - 1) * icon_spacing + padding * 2
        if horizontal then
            return along, across
        else
            return across, along
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
