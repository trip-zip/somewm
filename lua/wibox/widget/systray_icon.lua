---------------------------------------------------------------------------
--- A widget to display a single systray icon.
--
-- This widget wraps a `systray_item` object and displays its icon.
-- Unlike the traditional systray widget, each tray icon is a proper widget
-- that can be individually styled, positioned, and animated.
--
-- @author somewm contributors
-- @copyright 2024
-- @widgetmod wibox.widget.systray_icon
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------


local base = require("wibox.widget.base")
local gtable = require("gears.table")
local gfs = require("gears.filesystem")
local beautiful = require("beautiful")
local setmetatable = setmetatable

--- The urgent background color.
-- Shown when the systray item status is "NeedsAttention".
-- Similar to AwesomeWM's bg_urgent for clients/tags.
-- @beautiful beautiful.systray_urgent_bg
-- @tparam[opt=nil] string systray_urgent_bg

--- The urgent indicator color.
-- @beautiful beautiful.systray_urgent_color
-- @tparam[opt="#ff3333"] string systray_urgent_color

--- The urgent indicator outline color.
-- @beautiful beautiful.systray_urgent_outline_color
-- @tparam[opt="#ffffff"] string systray_urgent_outline_color

--- The urgent indicator style.
-- @beautiful beautiful.systray_urgent_style
-- @tparam[opt="none"] string systray_urgent_style One of "dot", "ring", "glow", or "none"

--- The hover scale factor.
-- @beautiful beautiful.systray_hover_scale
-- @tparam[opt=1.0] number systray_hover_scale Scale multiplier on hover (e.g., 1.1 for 10% larger)

--- The hover background color.
-- @beautiful beautiful.systray_hover_bg
-- @tparam[opt=nil] string systray_hover_bg Background color on hover

--- Per-icon style overrides.
-- Can be a function that receives the systray_item and returns a style table,
-- or a table mapping item.id or item.app_name to style tables.
--
-- Style tables can contain:
-- - `icon_override`: path to custom icon
-- - `hover_scale`: scale on hover
-- - `hover_bg`: background color on hover
-- - `urgent_bg`: background color when urgent
-- - `urgent_color`: urgent indicator color
-- - `urgent_outline_color`: urgent indicator outline
-- - `urgent_style`: "dot", "ring", "glow", or "none"
-- - `urgent_position`: "top_right", "top_left", "bottom_right", "bottom_left"
-- - `urgent_size`: number, ratio if <= 1, pixels if > 1
-- - `urgent_shape`: gears.shape function (default: gears.shape.circle)
-- - `icon_change_triggers_urgent`: boolean, icon changes trigger urgent
-- - `overlay_triggers_urgent`: boolean, overlay presence triggers urgent styling
-- - `overlay_position`: "bottom_right", "bottom_left", "top_right", "top_left"
-- - `overlay_size`: number, ratio if <= 1, pixels if > 1
-- - `overlay_bg`: background color for overlay
-- - `overlay_shape`: "circle", "rounded_rect", "rect"
-- - `overlay_padding`: padding around overlay within background
--
-- @beautiful beautiful.systray_icon_style
-- @tparam[opt=nil] function|table systray_icon_style

--- Context menu foreground color.
-- @beautiful beautiful.systray_menu_fg_normal
-- @tparam[opt=beautiful.menu_fg_normal] string systray_menu_fg_normal

--- Context menu background color.
-- @beautiful beautiful.systray_menu_bg_normal
-- @tparam[opt=beautiful.menu_bg_normal] string systray_menu_bg_normal

--- Context menu focused foreground color.
-- @beautiful beautiful.systray_menu_fg_focus
-- @tparam[opt=beautiful.menu_fg_focus] string systray_menu_fg_focus

--- Context menu focused background color.
-- @beautiful beautiful.systray_menu_bg_focus
-- @tparam[opt=beautiful.menu_bg_focus] string systray_menu_bg_focus

--- Context menu border color.
-- @beautiful beautiful.systray_menu_border_color
-- @tparam[opt=beautiful.menu_border_color] string systray_menu_border_color

--- Context menu border width.
-- @beautiful beautiful.systray_menu_border_width
-- @tparam[opt=beautiful.menu_border_width] number systray_menu_border_width

--- Context menu font.
-- @beautiful beautiful.systray_menu_font
-- @tparam[opt=beautiful.menu_font] string systray_menu_font

--- Context menu width.
-- @beautiful beautiful.systray_menu_width
-- @tparam[opt=beautiful.menu_width] number systray_menu_width

--- Context menu height.
-- @beautiful beautiful.systray_menu_height
-- @tparam[opt=beautiful.menu_height] number systray_menu_height

--- Context menu callback for customization.
-- Called with (item, menu_items) before showing menu. Can modify menu_items.
-- @beautiful beautiful.systray_menu_callback
-- @tparam[opt=nil] function systray_menu_callback

--- Whether to show overlay icons.
-- Overlay icons are small badges displayed on top of the main icon,
-- typically used to show status (like number of notifications).
-- @beautiful beautiful.systray_show_overlay
-- @tparam[opt=true] boolean systray_show_overlay

--- Whether overlay presence triggers urgent styling.
-- When true, icons with an overlay will be rendered with urgent styling
-- even if their status is not "NeedsAttention".
-- @beautiful beautiful.systray_overlay_triggers_urgent
-- @tparam[opt=false] boolean systray_overlay_triggers_urgent

--- The position of overlay icons on systray items.
-- @beautiful beautiful.systray_overlay_position
-- @tparam[opt="bottom_right"] string systray_overlay_position
--   One of "bottom_right", "bottom_left", "top_right", "top_left"

--- The size of overlay icons relative to the main icon.
-- If value is <= 1, treated as a ratio (e.g., 0.33 = 33% of icon size).
-- If value is > 1, treated as absolute pixels.
-- @beautiful beautiful.systray_overlay_size
-- @tparam[opt=0.33] number systray_overlay_size

--- Background color for overlay icons.
-- Draws a background shape behind the overlay icon for better visibility.
-- @beautiful beautiful.systray_overlay_bg
-- @tparam[opt=nil] string systray_overlay_bg

--- Shape for overlay background.
-- @beautiful beautiful.systray_overlay_shape
-- @tparam[opt="circle"] string systray_overlay_shape One of "circle", "rounded_rect", "rect"

--- Padding around overlay icon within its background.
-- @beautiful beautiful.systray_overlay_padding
-- @tparam[opt=2] number systray_overlay_padding

--- Whether icon changes trigger urgent styling.
-- When an app changes its icon (e.g., Slack adding a notification badge),
-- this triggers urgent styling instead. Best used with icon_override to
-- show a clean icon while still getting notification indicators.
-- @beautiful beautiful.systray_icon_change_triggers_urgent
-- @tparam[opt=false] boolean systray_icon_change_triggers_urgent

--- Position of urgent indicators (dot style).
-- @beautiful beautiful.systray_urgent_position
-- @tparam[opt="top_right"] string systray_urgent_position
--   One of "top_right", "top_left", "bottom_right", "bottom_left"

--- Size of urgent indicator dot.
-- If value is <= 1, treated as a ratio of icon size.
-- If value is > 1, treated as absolute pixels.
-- @beautiful beautiful.systray_urgent_size
-- @tparam[opt=0.25] number systray_urgent_size

--- Shape function for urgent indicators.
-- Used with "dot" and "ring" styles. Receives (cr, width, height).
-- @beautiful beautiful.systray_urgent_shape
-- @tparam[opt=gears.shape.circle] function systray_urgent_shape

-- For icon name lookup
local icon_theme_module = nil
local function get_icon_theme()
    if not icon_theme_module then
        local ok, mod = pcall(require, "menubar.icon_theme")
        if ok then
            icon_theme_module = mod
        end
    end
    return icon_theme_module
end

local systray_icon = { mt = {} }

-- Get the systray module for icon surface lookup
local function get_systray()
    local ok, mod = pcall(require, "awful.systray")
    if ok then return mod end
    return nil
end




--- Look up an icon by freedesktop name.
-- @tparam string icon_name The icon name (e.g., "network-wired")
-- @tparam number size The desired size
-- @tparam[opt] string theme_path Custom icon theme path from SNI IconThemePath
-- @treturn string|nil Path to the icon file, or nil if not found
local function lookup_icon_by_name(icon_name, size, theme_path)
    if not icon_name or icon_name == "" then
        return nil
    end

    -- If it's already a path, just return it
    if icon_name:sub(1, 1) == "/" then
        if gfs.file_readable(icon_name) then
            return icon_name
        end
        return nil
    end

    -- If app provides custom icon theme path, check there first
    if theme_path and theme_path ~= "" then
        -- Try common icon locations within the custom path
        local extensions = {"png", "svg", "xpm"}
        local sizes = {size or 24, 48, 32, 24, 22, 16}
        for _, s in ipairs(sizes) do
            for _, ext in ipairs(extensions) do
                -- Try hicolor-style path
                local path = string.format("%s/hicolor/%dx%d/apps/%s.%s",
                    theme_path, s, s, icon_name, ext)
                if gfs.file_readable(path) then
                    return path
                end
                -- Try scalable
                path = string.format("%s/hicolor/scalable/apps/%s.%s",
                    theme_path, icon_name, ext)
                if gfs.file_readable(path) then
                    return path
                end
                -- Try direct path
                path = string.format("%s/%s.%s", theme_path, icon_name, ext)
                if gfs.file_readable(path) then
                    return path
                end
            end
        end
    end

    -- Try using the icon theme module
    local icon_theme = get_icon_theme()
    if icon_theme then
        local theme_name = beautiful.icon_theme or "hicolor"
        local it = icon_theme(theme_name)
        local path = it:find_icon_path(icon_name, size or 24)
        if path then
            return path
        end
    end

    return nil
end

--- Get the icon surface for the item.
-- Prefers pixmap surface from systray module, falls back to icon_name lookup.
-- @tparam systray_item item The systray item
-- @tparam number size Desired size for icon name lookup
-- @treturn cairo.Surface|string|nil A surface, path, or nil
local function get_item_icon(item, size)
    -- First try to get pixmap surface from systray module
    local systray_mod = get_systray()
    if systray_mod then
        local surface_icon = systray_mod.get_icon_surface(item)
        if surface_icon then
            return surface_icon
        end
    end

    -- Fall back to icon_name lookup
    local icon_name = item.icon_name
    if icon_name and icon_name ~= "" then
        return lookup_icon_by_name(icon_name, size, item.icon_theme_path)
    end

    return nil
end



--- Update the current icon.
-- @method _update_icon
-- @hidden
function systray_icon:_update_icon()
    local item = self._private.item
    if not item then
        self._private.current_icon = nil
        return
    end

    local size = self._private.forced_size or
                 self._private.forced_width or
                 self._private.forced_height or 24

    self._private.current_icon = get_item_icon(item, size)
    self:emit_signal("widget::redraw_needed")
end

--- The systray item to display.
--
-- @property item
-- @tparam[opt=nil] systray_item item The item object
-- @propemits true false

function systray_icon:set_item(item)
    local old = self._private.item

    -- Disconnect from old item
    if old then
        old:disconnect_signal("property::icon", self._private.icon_update_cb)
        old:disconnect_signal("property::icon_name", self._private.icon_update_cb)
        old:disconnect_signal("property::status", self._private.status_cb)
        old:disconnect_signal("property::overlay_icon", self._private.overlay_update_cb)
    end

    self._private.item = item

    -- Connect to new item
    if item then
        item:connect_signal("property::icon", self._private.icon_update_cb)
        item:connect_signal("property::icon_name", self._private.icon_update_cb)
        item:connect_signal("property::status", self._private.status_cb)
        item:connect_signal("property::overlay_icon", self._private.overlay_update_cb)
    end

    self:_update_icon()
    self:emit_signal("property::item", item)
    self:emit_signal("widget::layout_changed")
end

function systray_icon:get_item()
    return self._private.item
end

--- The icon size.
--
-- @property forced_size
-- @tparam[opt=24] number forced_size The size in pixels
-- @propemits true false

function systray_icon:set_forced_size(size)
    self._private.forced_size = size
    self:_update_icon()
    self:emit_signal("property::forced_size", size)
    self:emit_signal("widget::layout_changed")
end

function systray_icon:get_forced_size()
    return self._private.forced_size
end

-- Lazy-load awful.menu to avoid circular dependency issues
local awful_menu = nil
local function get_awful_menu()
    if not awful_menu then
        local ok, mod = pcall(require, "awful.menu")
        if ok then awful_menu = mod end
    end
    return awful_menu
end

-- Lazy-load awful.systray for DBusMenu support
local awful_systray = nil
local function get_awful_systray()
    if not awful_systray then
        local ok, mod = pcall(require, "awful.systray")
        if ok then awful_systray = mod end
    end
    return awful_systray
end

--- Handle mouse button press events.
-- @method _handle_button
-- @hidden
local function handle_button(self, x, y, button, mods, geometry)
    local item = self._private.item
    if not item then return end

    -- Calculate screen coordinates for D-Bus methods
    local screen_x = geometry and geometry.x or 0
    local screen_y = geometry and geometry.y or 0

    if button == 1 then
        -- Primary click - if item_is_menu, show context menu instead
        if item.item_is_menu then
            -- Treat like right-click
            button = 3
        else
            item:activate(screen_x + x, screen_y + y)
            return
        end
    end

    if button == 2 then
        -- Middle click
        item:secondary_activate(screen_x + x, screen_y + y)
    elseif button == 3 then
        -- Right click - context menu
        -- Try DBusMenu first if available
        local systray_mod = get_awful_systray()
        local menu_mod = get_awful_menu()

        if systray_mod and menu_mod and item.menu_path and item.menu_path ~= "" then
            -- Fetch and show DBusMenu
            systray_mod.fetch_menu(item, function(menu_items, _)
                if menu_items and #menu_items > 0 then
                    -- Close any existing menu
                    if self._private.current_menu then
                        self._private.current_menu:hide()
                    end

                    -- Apply menu callback for customization if set
                    local menu_callback = beautiful.systray_menu_callback
                    if menu_callback and type(menu_callback) == "function" then
                        local ok, result = pcall(menu_callback, item, menu_items)
                        if ok and result then
                            menu_items = result
                        end
                    end

                    -- Build theme table for systray menus
                    local menu_theme = {
                        fg_normal = beautiful.systray_menu_fg_normal or beautiful.menu_fg_normal,
                        bg_normal = beautiful.systray_menu_bg_normal or beautiful.menu_bg_normal,
                        fg_focus = beautiful.systray_menu_fg_focus or beautiful.menu_fg_focus,
                        bg_focus = beautiful.systray_menu_bg_focus or beautiful.menu_bg_focus,
                        border_color = beautiful.systray_menu_border_color or beautiful.menu_border_color,
                        border_width = beautiful.systray_menu_border_width or beautiful.menu_border_width,
                        font = beautiful.systray_menu_font or beautiful.menu_font,
                        width = beautiful.systray_menu_width or beautiful.menu_width,
                        height = beautiful.systray_menu_height or beautiful.menu_height,
                    }

                    -- Create and show the menu at mouse position
                    local menu = menu_mod({ items = menu_items, theme = menu_theme })
                    menu:show()  -- Uses mouse.coords() automatically
                    self._private.current_menu = menu
                else
                    -- Fallback to D-Bus ContextMenu method
                    item:context_menu(screen_x + x, screen_y + y)
                end
            end)
        else
            -- No DBusMenu available, use D-Bus ContextMenu method
            item:context_menu(screen_x + x, screen_y + y)
        end
    elseif button == 4 then
        -- Scroll up
        item:scroll(1, "vertical")
    elseif button == 5 then
        -- Scroll down
        item:scroll(-1, "vertical")
    elseif button == 6 then
        -- Scroll left (if supported)
        item:scroll(-1, "horizontal")
    elseif button == 7 then
        -- Scroll right (if supported)
        item:scroll(1, "horizontal")
    end
end

--- Create a new systray_icon widget.
--
-- @constructorfct wibox.widget.systray_icon
-- @tparam[opt] systray_item item The systray item to display
-- @treturn wibox.widget.systray_icon A new systray_icon widget
local function new(item)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, systray_icon, true)

    ret._private.forced_size = 24

    -- Create callback functions that can be connected/disconnected
    ret._private.icon_update_cb = function()
        ret:_update_icon()
    end

    ret._private.status_cb = function()
        ret:emit_signal("property::status", ret._private.item and ret._private.item.status)
        ret:emit_signal("widget::redraw_needed")
    end

    ret._private.overlay_update_cb = function()
        ret:emit_signal("widget::redraw_needed")
    end

    -- Connect button press handler
    ret:connect_signal("button::press", function(self, x, y, button, mods, geometry)
        handle_button(self, x, y, button, mods, geometry)
    end)

    -- Add tooltip (lazy-load to avoid circular dependency)
    local tooltip_mod = require("awful.tooltip")
    local item_tooltip = tooltip_mod {
        objects = {ret},
        delay_show = 0.5,
    }
    ret._private.tooltip = item_tooltip

    -- Track hover state for hover effects
    ret._private.is_hovered = false

    -- Update tooltip text and hover state when hovering
    ret:connect_signal("mouse::enter", function()
        ret._private.is_hovered = true
        ret:emit_signal("widget::redraw_needed")

        local i = ret._private.item
        if i then
            local text = i.tooltip_title
            if not text or text == "" then text = i.tooltip_body end
            if not text or text == "" then text = i.title end
            if not text or text == "" then text = i.app_name end
            if not text or text == "" then text = i.id or "Unknown" end
            item_tooltip:set_text(text)
        end
    end)

    ret:connect_signal("mouse::leave", function()
        ret._private.is_hovered = false
        ret:emit_signal("widget::redraw_needed")
    end)

    if item then
        ret:set_item(item)
    end

    return ret
end

function systray_icon.mt:__call(...)
    return new(...)
end

-- One image leaf, centered: the item's icon.
require("wibox.clay").describe_class(systray_icon, require("wibox.clay").systray_icon)

return setmetatable(systray_icon, systray_icon.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
