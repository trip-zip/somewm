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

local lgi = require("lgi")
local cairo = lgi.cairo

local base = require("wibox.widget.base")
local surface = require("gears.surface")
local gtable = require("gears.table")
local gdebug = require("gears.debug")
local gfs = require("gears.filesystem")
local gcolor = require("gears.color")
local beautiful = require("beautiful")
local setmetatable = setmetatable
local math = math

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

--- Get per-icon style overrides.
-- Checks beautiful.systray_icon_style (function or table) for item-specific styling.
-- @tparam systray_item item The systray item
-- @tparam string key The style property to look up
-- @treturn any The style value, or nil if not overridden
local function get_icon_style(item, key)
    if not item then return nil end

    local style_config = beautiful.systray_icon_style
    if not style_config then return nil end

    local style_table = nil

    if type(style_config) == "function" then
        -- Call function with item to get style table
        local ok, result = pcall(style_config, item)
        if ok and type(result) == "table" then
            style_table = result
        end
    elseif type(style_config) == "table" then
        -- Look up by item.id first, then by item.app_name
        local item_id = item.id
        local app_name = item.app_name

        if item_id and style_config[item_id] then
            style_table = style_config[item_id]
        elseif app_name and style_config[app_name] then
            style_table = style_config[app_name]
        end
    end

    if style_table and key then
        return style_table[key]
    end

    return style_table
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

--- Draw the systray icon.
-- @method draw
-- @hidden
function systray_icon:draw(context, cr, width, height)
    if width == 0 or height == 0 then return end

    local item = self._private.item
    if not item then return end

    local is_hovered = self._private.is_hovered

    -- Get per-icon style overrides (check item-specific first, then beautiful defaults)
    local hover_bg = get_icon_style(item, "hover_bg") or beautiful.systray_hover_bg
    local hover_scale_val = get_icon_style(item, "hover_scale") or beautiful.systray_hover_scale or 1.0

    -- Draw hover background if set
    if is_hovered and hover_bg then
        cr:set_source(gcolor(hover_bg))
        cr:rectangle(0, 0, width, height)
        cr:fill()
    end

    -- Apply hover scale transform (scale from center)
    local hover_scale = is_hovered and hover_scale_val or 1.0
    if hover_scale ~= 1.0 then
        cr:save()
        -- Scale around center: translate to center, scale, translate back
        cr:translate(width / 2, height / 2)
        cr:scale(hover_scale, hover_scale)
        cr:translate(-width / 2, -height / 2)
    end

    -- Draw urgent background if status is NeedsAttention (AwesomeWM-style)
    if item.status == "NeedsAttention" then
        local urgent_bg = get_icon_style(item, "urgent_bg") or beautiful.systray_urgent_bg
        if urgent_bg then
            cr:set_source(gcolor(urgent_bg))
            cr:rectangle(0, 0, width, height)
            cr:fill()
        end
    end

    local icon_drawn = false

    -- Check for per-icon icon_override first
    local icon_override = get_icon_style(item, "icon_override")
    if icon_override then
        local override_path = lookup_icon_by_name(icon_override, math.floor(math.min(width, height)))
        if override_path then
            local icon_surface = surface.load_silently(override_path)
            if icon_surface then
                local iw = cairo.ImageSurface.get_width(icon_surface)
                local ih = cairo.ImageSurface.get_height(icon_surface)
                if iw > 0 and ih > 0 then
                    local scale = math.min(width / iw, height / ih)
                    local dx = (width - iw * scale) / 2
                    local dy = (height - ih * scale) / 2
                    cr:save()
                    cr:translate(dx, dy)
                    cr:scale(scale, scale)
                    cr:set_source_surface(icon_surface, 0, 0)
                    cr:paint()
                    cr:restore()
                    icon_drawn = true
                end
            end
        end
    end

    -- Use the C method to draw the icon directly (for pixmap icons)
    -- This avoids the lightuserdata -> lgi surface conversion issue
    if not icon_drawn then
        local ok, result = pcall(function()
            return item:draw_icon(cr._native or cr, width, height)
        end)
        icon_drawn = ok and result
    end

    -- If no pixmap, try icon_name via theme lookup
    if not icon_drawn then
        local icon_name = item.icon_name
        if icon_name and icon_name ~= "" then
            local icon_path = lookup_icon_by_name(icon_name, math.floor(math.min(width, height)), item.icon_theme_path)
            if icon_path then
                local icon_surface = surface.load_silently(icon_path)
                if icon_surface then
                    local iw = cairo.ImageSurface.get_width(icon_surface)
                    local ih = cairo.ImageSurface.get_height(icon_surface)
                    if iw > 0 and ih > 0 then
                        local scale = math.min(width / iw, height / ih)
                        local dx = (width - iw * scale) / 2
                        local dy = (height - ih * scale) / 2
                        cr:save()
                        cr:translate(dx, dy)
                        cr:scale(scale, scale)
                        cr:set_source_surface(icon_surface, 0, 0)
                        cr:paint()
                        cr:restore()
                        icon_drawn = true
                    end
                end
            end
        end
    end

    -- Fallback: draw placeholder if nothing else worked
    if not icon_drawn then
        cr:set_source_rgb(0.3, 0.3, 0.3)
        cr:rectangle(2, 2, width - 4, height - 4)
        cr:fill()
    end

    -- Restore from hover scale transform
    if hover_scale ~= 1.0 then
        cr:restore()
    end

    -- Draw overlay icon if present (small badge in bottom-right corner)
    local show_overlay = beautiful.systray_show_overlay
    if show_overlay == nil then show_overlay = true end  -- default to true

    if show_overlay and item.overlay_icon then
        -- Draw overlay at ~1/3 size in bottom-right corner
        local overlay_size = math.floor(math.min(width, height) / 3)
        local overlay_x = width - overlay_size
        local overlay_y = height - overlay_size

        local ok = pcall(function()
            item:draw_overlay(cr._native or cr, overlay_x, overlay_y, overlay_size)
        end)
        -- If C draw_overlay failed, try icon_name lookup
        if not ok and item.overlay_icon_name and item.overlay_icon_name ~= "" then
            local overlay_path = lookup_icon_by_name(item.overlay_icon_name, overlay_size, item.icon_theme_path)
            if overlay_path then
                local overlay_surface = surface.load_silently(overlay_path)
                if overlay_surface then
                    local ow = cairo.ImageSurface.get_width(overlay_surface)
                    local oh = cairo.ImageSurface.get_height(overlay_surface)
                    if ow > 0 and oh > 0 then
                        local scale = overlay_size / math.max(ow, oh)
                        cr:save()
                        cr:translate(overlay_x, overlay_y)
                        cr:scale(scale, scale)
                        cr:set_source_surface(overlay_surface, 0, 0)
                        cr:paint()
                        cr:restore()
                    end
                end
            end
        end
    end

    -- Draw urgent indicator when status is NeedsAttention
    local urgent_style = get_icon_style(item, "urgent_style") or beautiful.systray_urgent_style or "none"
    if item.status == "NeedsAttention" and urgent_style ~= "none" then
        local urgent_color = get_icon_style(item, "urgent_color") or beautiful.systray_urgent_color or "#ff3333"
        local outline_color = get_icon_style(item, "urgent_outline_color") or beautiful.systray_urgent_outline_color or "#ffffff"

        if urgent_style == "dot" then
            local dot_radius = math.max(3, width / 8)
            local dot_x = width - dot_radius - 1
            local dot_y = dot_radius + 1

            -- Draw outline for visibility
            cr:set_source(gcolor(outline_color))
            cr:arc(dot_x, dot_y, dot_radius + 1, 0, 2 * math.pi)
            cr:fill()

            -- Draw urgent dot
            cr:set_source(gcolor(urgent_color))
            cr:arc(dot_x, dot_y, dot_radius, 0, 2 * math.pi)
            cr:fill()

        elseif urgent_style == "ring" then
            -- Draw ring around the icon
            local ring_width = 2
            cr:set_source(gcolor(urgent_color))
            cr:set_line_width(ring_width)
            cr:arc(width / 2, height / 2, math.min(width, height) / 2 - ring_width, 0, 2 * math.pi)
            cr:stroke()

        elseif urgent_style == "glow" then
            -- Draw glow effect (colored border)
            local glow_size = 3
            cr:set_source(gcolor(urgent_color))
            cr:rectangle(0, 0, width, glow_size)  -- top
            cr:rectangle(0, height - glow_size, width, glow_size)  -- bottom
            cr:rectangle(0, 0, glow_size, height)  -- left
            cr:rectangle(width - glow_size, 0, glow_size, height)  -- right
            cr:fill()
        end
    end
end

--- Fit the widget to available space.
-- @method fit
-- @hidden
function systray_icon:fit(context, width, height)
    local item = self._private.item
    local size = self._private.forced_size or 24

    if item then
        -- Use item's icon dimensions if available
        local iw = item.icon_width
        local ih = item.icon_height
        if iw and iw > 0 and ih and ih > 0 then
            size = math.max(iw, ih)
        end
    end

    -- Respect forced_width/height
    local w = self._private.forced_width or size
    local h = self._private.forced_height or size

    local result_w, result_h = math.min(w, width), math.min(h, height)
    return result_w, result_h
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

        print("[SYSTRAY_ICON] Right-click on " .. tostring(item.title or item.id or "unknown"))
        print("[SYSTRAY_ICON]   menu_path = " .. tostring(item.menu_path))
        print("[SYSTRAY_ICON]   bus_name = " .. tostring(item.bus_name))

        if systray_mod and menu_mod and item.menu_path and item.menu_path ~= "" then
            -- Fetch and show DBusMenu
            print("[SYSTRAY_ICON] Trying DBusMenu fetch...")
            systray_mod.fetch_menu(item, function(menu_items, _)
                print("[SYSTRAY_ICON] DBusMenu callback, got " .. tostring(menu_items and #menu_items or 0) .. " items")
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
                    print("[SYSTRAY_ICON] No DBusMenu items, falling back to ContextMenu")
                    item:context_menu(screen_x + x, screen_y + y)
                end
            end)
        else
            -- No DBusMenu available, use D-Bus ContextMenu method
            print("[SYSTRAY_ICON] No DBusMenu available, calling ContextMenu")
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

return setmetatable(systray_icon, systray_icon.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
