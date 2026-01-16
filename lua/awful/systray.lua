---------------------------------------------------------------------------
--- StatusNotifierItem (SNI) systray watcher for somewm.
--
-- This module implements a StatusNotifierHost that monitors the D-Bus
-- session bus for tray icons (StatusNotifierItems) and creates
-- systray_item objects for each one.
--
-- Unlike AwesomeWM's X11 XEmbed-based systray, this uses the D-Bus SNI
-- protocol which is native to Wayland compositors.
--
-- @author somewm contributors
-- @copyright 2024
-- @module awful.systray
---------------------------------------------------------------------------

local lgi = require("lgi")
local Gio = lgi.Gio
local GLib = lgi.GLib
local GObject = lgi.GObject
local cairo = lgi.cairo

local protected_call = require("gears.protected_call")
local gtable = require("gears.table")
local gdebug = require("gears.debug")
local gfs = require("gears.filesystem")

local capi = {
    awesome = awesome,
    systray_item = systray_item,
}

local systray = {
    -- Configuration
    config = {
        icon_size = 24,
    },
    -- Internal state
    _private = {
        initialized = false,
        bus = nil,
        watcher_proxy = nil,
        items = {},  -- item_key -> item object
        item_data = {},  -- item -> {item_key, icon_surface} (Lua-side data)
        host_registered = false,
    }
}

-- SNI D-Bus interface constants
local SNI_WATCHER_BUS = "org.kde.StatusNotifierWatcher"
local SNI_WATCHER_PATH = "/StatusNotifierWatcher"
local SNI_WATCHER_IFACE = "org.kde.StatusNotifierWatcher"
local SNI_ITEM_IFACE = "org.kde.StatusNotifierItem"

-- Our host name (unique per process)
local function get_host_name()
    local pid = GLib.getenv("SOMEWM_PID") or tostring(math.floor(os.clock() * 1000000))
    return "org.kde.StatusNotifierHost-" .. pid
end

---------------------------------------------------------------------------
-- Icon pixmap parsing (from D-Bus IconPixmap property)
---------------------------------------------------------------------------

--- Convert SNI IconPixmap data to cairo surface.
-- IconPixmap is an array of (width, height, pixel_data) where pixel_data
-- is ARGB32 in network byte order (big-endian).
-- @tparam table pixmaps Array of {width, height, data} tuples
-- @tparam number target_size Preferred icon size
-- @treturn cairo.ImageSurface|nil The icon surface, or nil on error
local function parse_icon_pixmap(pixmaps, target_size)
    if not pixmaps or #pixmaps == 0 then
        return nil
    end

    -- Find best matching size (prefer exact or next larger)
    local best = pixmaps[1]
    local best_diff = math.abs(best[1] - target_size)

    for i = 2, #pixmaps do
        local p = pixmaps[i]
        local diff = math.abs(p[1] - target_size)
        if diff < best_diff or (diff == best_diff and p[1] > best[1]) then
            best = p
            best_diff = diff
        end
    end

    local width, height = best[1], best[2]
    local data = best[3]

    if width <= 0 or height <= 0 or not data then
        return nil
    end

    -- Get raw bytes from GVariant data
    local raw_data
    if type(data) == "string" then
        raw_data = data
    elseif data.data then
        -- GVariant byte array
        raw_data = tostring(data.data)
    else
        return nil
    end

    local expected_size = width * height * 4
    if #raw_data < expected_size then
        gdebug.print_warning("systray: IconPixmap data too short: " ..
            #raw_data .. " < " .. expected_size)
        return nil
    end

    -- Create cairo surface
    local stride = cairo.Format.stride_for_width(cairo.Format.ARGB32, width)
    local surface = cairo.ImageSurface.create(cairo.Format.ARGB32, width, height)

    if surface.status ~= "SUCCESS" then
        return nil
    end

    -- Get surface data buffer
    local surf_data = surface:get_data()

    -- Convert from network byte order ARGB to native ARGB
    -- Network order: A R G B (bytes 0,1,2,3)
    -- Native little-endian: B G R A (bytes 0,1,2,3)
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local src_idx = (y * width + x) * 4 + 1  -- Lua 1-indexed
            local dst_idx = y * stride + x * 4

            local a = string.byte(raw_data, src_idx)
            local r = string.byte(raw_data, src_idx + 1)
            local g = string.byte(raw_data, src_idx + 2)
            local b = string.byte(raw_data, src_idx + 3)

            -- Native ARGB32 on little-endian is BGRA in memory
            surf_data[dst_idx] = b
            surf_data[dst_idx + 1] = g
            surf_data[dst_idx + 2] = r
            surf_data[dst_idx + 3] = a
        end
    end

    surface:mark_dirty()
    return surface
end

---------------------------------------------------------------------------
-- StatusNotifierItem monitoring
---------------------------------------------------------------------------

--- Fetch all properties from a StatusNotifierItem.
-- @tparam string service D-Bus service name
-- @tparam string path D-Bus object path
-- @tparam function callback Called with (props_table) or nil on error
local function fetch_item_properties(service, path, callback)
    systray._private.bus:call(
        service,
        path,
        "org.freedesktop.DBus.Properties",
        "GetAll",
        GLib.Variant("(s)", {SNI_ITEM_IFACE}),
        GLib.VariantType("(a{sv})"),
        Gio.DBusCallFlags.NONE,
        -1,  -- default timeout
        nil,  -- cancellable
        function(conn, result)
            local ok, ret = pcall(function()
                return conn:call_finish(result)
            end)

            if not ok or not ret then
                gdebug.print_warning("systray: Failed to get properties for " ..
                    service .. ": " .. tostring(ret))
                callback(nil)
                return
            end

            -- Unpack the (a{sv}) variant
            local props = {}
            local props_variant = ret:get_child_value(0)

            for i = 0, props_variant:n_children() - 1 do
                local entry = props_variant:get_child_value(i)
                local key = entry:get_child_value(0):get_string()
                local value = entry:get_child_value(1):get_variant()
                props[key] = value
            end

            callback(props)
        end
    )
end

-- Forward declaration (defined below, but needed by register_item's name watcher)
local unregister_item

--- Get PID from D-Bus connection name and resolve to process name.
-- Uses org.freedesktop.DBus.GetConnectionUnixProcessID to get the PID,
-- then reads /proc/<pid>/comm to get the process name.
-- @tparam string bus_name D-Bus connection name (e.g., ":1.264")
-- @tparam function callback Called with (app_name) or (nil) on error
local function get_app_name_from_bus(bus_name, callback)
    if not systray._private.bus or not bus_name then
        callback(nil)
        return
    end

    systray._private.bus:call(
        "org.freedesktop.DBus",           -- bus name
        "/org/freedesktop/DBus",          -- object path
        "org.freedesktop.DBus",           -- interface
        "GetConnectionUnixProcessID",     -- method
        GLib.Variant("(s)", {bus_name}),  -- parameters
        GLib.VariantType.new("(u)"),      -- reply type
        Gio.DBusCallFlags.NONE,
        -1,
        nil,
        function(conn, result)
            local ok, reply = pcall(function()
                return conn:call_finish(result)
            end)

            if not ok or not reply then
                callback(nil)
                return
            end

            local pid = reply:get_child_value(0):get_uint32()
            if not pid or pid == 0 then
                callback(nil)
                return
            end

            -- Read process name from /proc/<pid>/comm
            local f = io.open("/proc/" .. pid .. "/comm", "r")
            if f then
                local name = f:read("*l")
                f:close()
                if name and name ~= "" then
                    -- Capitalize first letter for nicer display
                    callback(name:sub(1,1):upper() .. name:sub(2))
                    return
                end
            end

            callback(nil)
        end
    )
end

--- Create and register a new systray item.
-- @tparam string service D-Bus service name (e.g., ":1.234" or "org.app.Name")
-- @tparam string path D-Bus object path (usually "/StatusNotifierItem")
local function register_item(service, path)
    -- Parse service name - can be "service_name" or "service_name/path"
    if service:find("/") then
        local parts = {}
        for part in service:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        service = parts[1]
        path = "/" .. table.concat(parts, "/", 2)
    end

    path = path or "/StatusNotifierItem"

    local item_key = service .. path
    if systray._private.items[item_key] then
        -- Already registered
        return
    end

    fetch_item_properties(service, path, function(props)
        if not props then
            return
        end

        -- Create systray_item C object and register it for tracking
        local item = capi.systray_item.register()

        -- Store Lua-side data
        local item_data = {
            item_key = item_key,
            icon_surface = nil,
        }
        systray._private.item_data[item] = item_data

        -- Set D-Bus identification on C object (these are now proper setters)
        item.bus_name = service
        item.object_path = path

        -- Try to derive app name from PID in service name
        -- Service names are like "org.kde.StatusNotifierItem-12345-1" where 12345 is PID
        local pid = service:match("%-(%d+)%-")
        if pid then
            local f = io.open("/proc/" .. pid .. "/comm", "r")
            if f then
                local name = f:read("*l")
                f:close()
                if name and name ~= "" then
                    -- Capitalize first letter
                    item.app_name = name:sub(1,1):upper() .. name:sub(2)
                end
            end
        elseif service:sub(1, 1) == ":" then
            -- Unique connection name (e.g., ":1.264") - query D-Bus for PID
            get_app_name_from_bus(service, function(app_name)
                if app_name then
                    item.app_name = app_name
                    -- Emit update signal so widgets can refresh
                    capi.awesome.emit_signal("systray::update")
                end
            end)
        end

        -- Extract properties from D-Bus response
        local function get_string(name)
            local v = props[name]
            if v then
                local ok, str = pcall(function() return v:get_string() end)
                if ok then return str end
            end
            return ""
        end

        -- Set properties on the item
        -- Note: Some of these emit signals, which is fine
        if props.Id then
            item.id = get_string("Id")
        end
        if props.Title then
            item.title = get_string("Title")
        end
        if props.Status then
            item.status = get_string("Status")
        end
        if props.Category then
            item.category = get_string("Category")
        end
        if props.Menu then
            item.menu_path = get_string("Menu")
        end

        -- Handle ItemIsMenu (some apps only have menus, no activate action)
        if props.ItemIsMenu then
            pcall(function()
                item.item_is_menu = props.ItemIsMenu:get_boolean()
            end)
        end

        -- Handle IconThemePath (custom icon theme search path)
        if props.IconThemePath then
            local path = get_string("IconThemePath")
            if path and path ~= "" then
                item.icon_theme_path = path
            end
        end

        -- Handle AttentionIconName/AttentionIconPixmap (shown when status == "NeedsAttention")
        if props.AttentionIconName then
            local name = get_string("AttentionIconName")
            if name and name ~= "" then
                item.attention_icon_name = name
            end
        elseif props.AttentionIconPixmap then
            -- AttentionIconPixmap is a(iiay) - array of (width, height, data)
            local ok, err = pcall(function()
                local pixmap_array = props.AttentionIconPixmap
                local target_size = systray.config.icon_size
                local best_w, best_h, best_data
                local best_diff = math.huge

                for i = 0, pixmap_array:n_children() - 1 do
                    local entry = pixmap_array:get_child_value(i)
                    local w = entry:get_child_value(0):get_int32()
                    local h = entry:get_child_value(1):get_int32()
                    local diff = math.abs(w - target_size)
                    if diff < best_diff or (diff == best_diff and w > (best_w or 0)) then
                        best_w, best_h = w, h
                        best_data = entry:get_child_value(2)
                        best_diff = diff
                    end
                end

                if best_w and best_h and best_data then
                    local data_bytes = best_data:get_data_as_bytes()
                    local raw_data = data_bytes:get_data()
                    if raw_data and #raw_data >= best_w * best_h * 4 then
                        item:set_attention_pixmap(best_w, best_h, raw_data)
                    end
                end
            end)
            if not ok then
                gdebug.print_warning("systray: AttentionIconPixmap error: " .. tostring(err))
            end
        end

        -- Handle OverlayIconName (small badge displayed on top of main icon)
        if props.OverlayIconName then
            local name = get_string("OverlayIconName")
            if name and name ~= "" then
                item.overlay_icon_name = name
            end
        elseif props.OverlayIconPixmap then
            -- OverlayIconPixmap is a(iiay) - array of (width, height, data)
            local ok, err = pcall(function()
                local pixmap_array = props.OverlayIconPixmap
                local target_size = math.floor(systray.config.icon_size / 3)  -- Overlay is ~1/3 size
                local best_w, best_h, best_data
                local best_diff = math.huge

                -- Find best matching size
                for i = 0, pixmap_array:n_children() - 1 do
                    local entry = pixmap_array:get_child_value(i)
                    local w = entry:get_child_value(0):get_int32()
                    local h = entry:get_child_value(1):get_int32()
                    local diff = math.abs(w - target_size)
                    if diff < best_diff or (diff == best_diff and w > (best_w or 0)) then
                        best_w, best_h = w, h
                        best_data = entry:get_child_value(2)
                        best_diff = diff
                    end
                end

                if best_w and best_h and best_data then
                    local data_bytes = best_data:get_data_as_bytes()
                    local raw_data = data_bytes:get_data()
                    if raw_data and #raw_data >= best_w * best_h * 4 then
                        item:set_overlay_pixmap(best_w, best_h, raw_data)
                    end
                end
            end)
            if not ok then
                gdebug.print_warning("systray: OverlayIconPixmap error: " .. tostring(err))
            end
        end

        -- Handle ToolTip property: (sa(iiay)ss) = (icon_name, icon_pixmaps, title, body)
        if props.ToolTip then
            pcall(function()
                local tt = props.ToolTip
                -- ToolTip is a struct, access fields by index
                -- [1] = icon name (string)
                -- [2] = icon pixmaps (array)
                -- [3] = title (string)
                -- [4] = body/description (string)
                if tt[3] then
                    item.tooltip_title = tt[3]
                end
                if tt[4] then
                    item.tooltip_body = tt[4]
                end
            end)
        end

        -- Handle icon (prefer IconName, fallback to IconPixmap)
        local icon_name = get_string("IconName")
        if icon_name and icon_name ~= "" then
            item.icon_name = icon_name
        elseif props.IconPixmap then
            -- IconPixmap is a(iiay) - array of (width, height, data)
            local ok, err = pcall(function()
                local pixmap_array = props.IconPixmap
                local target_size = systray.config.icon_size
                local best_w, best_h, best_data
                local best_diff = math.huge

                -- Find best matching size
                for i = 0, pixmap_array:n_children() - 1 do
                    local entry = pixmap_array:get_child_value(i)
                    local w = entry:get_child_value(0):get_int32()
                    local h = entry:get_child_value(1):get_int32()
                    local diff = math.abs(w - target_size)
                    if diff < best_diff or (diff == best_diff and w > (best_w or 0)) then
                        best_w, best_h = w, h
                        best_data = entry:get_child_value(2)
                        best_diff = diff
                    end
                end

                if best_w and best_h and best_data then
                    -- Extract raw bytes from GVariant byte array
                    local data_bytes = best_data:get_data_as_bytes()
                    local raw_data = data_bytes:get_data()
                    if raw_data and #raw_data >= best_w * best_h * 4 then
                        -- Use C function to set icon (handles byte order conversion)
                        item:set_icon_pixmap(best_w, best_h, raw_data)
                        -- Store icon surface for Lua-side widget drawing
                        local data = systray._private.item_data[item]
                        if data then
                            data.icon_surface = item.icon
                        end
                    end
                end
            end)
            if not ok then
                gdebug.print_warning("systray: IconPixmap error: " .. tostring(err))
            end
        end

        -- Store in our tracking table
        systray._private.items[item_key] = item

        -- Watch for this service to vanish (handles crashes / ungraceful exits)
        local watch_id = Gio.bus_watch_name(
            Gio.BusType.SESSION,
            service,
            Gio.BusNameWatcherFlags.NONE,
            nil,  -- appeared callback (don't care)
            GObject.Closure(function(conn, name)
                -- Service vanished - unregister this item
                unregister_item(service, path)
            end)
        )

        -- Store watch ID in item data so we can unwatch later
        local data = systray._private.item_data[item]
        if data then
            data.name_watch_id = watch_id
        end

        -- Connect to request::* signals to handle D-Bus method calls
        item:connect_signal("request::activate", function(_, x, y)
            -- Clear urgent flag on activation (user acknowledged the notification)
            -- Also set ignore_next_icon_change so when the app clears its badge
            -- (which fires NewIcon), we don't immediately show the indicator again
            local data = systray._private.item_data[item]
            if data then
                data.urgent_from_icon_change = false
                data.ignore_next_icon_change = true
            end
            systray._private.bus:call(
                service, path, SNI_ITEM_IFACE, "Activate",
                GLib.Variant("(ii)", {x or 0, y or 0}),
                nil, Gio.DBusCallFlags.NONE, -1, nil, nil
            )
            capi.awesome.emit_signal("systray::update")
        end)

        item:connect_signal("request::secondary_activate", function(_, x, y)
            systray._private.bus:call(
                service, path, SNI_ITEM_IFACE, "SecondaryActivate",
                GLib.Variant("(ii)", {x or 0, y or 0}),
                nil, Gio.DBusCallFlags.NONE, -1, nil, nil
            )
        end)

        item:connect_signal("request::context_menu", function(_, x, y)
            systray._private.bus:call(
                service, path, SNI_ITEM_IFACE, "ContextMenu",
                GLib.Variant("(ii)", {x or 0, y or 0}),
                nil, Gio.DBusCallFlags.NONE, -1, nil, nil
            )
        end)

        item:connect_signal("request::scroll", function(_, delta, orientation)
            systray._private.bus:call(
                service, path, SNI_ITEM_IFACE, "Scroll",
                GLib.Variant("(is)", {delta or 0, orientation or "vertical"}),
                nil, Gio.DBusCallFlags.NONE, -1, nil, nil
            )
        end)

        -- Subscribe to property change signals from the item
        systray._private.bus:signal_subscribe(
            service,  -- sender
            SNI_ITEM_IFACE,  -- interface
            nil,  -- member (all signals)
            path,  -- object path
            nil,  -- arg0
            Gio.DBusSignalFlags.NONE,
            function(conn, sender, obj_path, iface, signal_name, params)
                protected_call(function()
                    if signal_name == "NewTitle" then
                        fetch_item_properties(service, path, function(p)
                            if p and p.Title then
                                item.title = p.Title:get_string()
                            end
                        end)
                    elseif signal_name == "NewIcon" then
                        fetch_item_properties(service, path, function(p)
                            if p then
                                local name = p.IconName and p.IconName:get_string()
                                if name and name ~= "" then
                                    item.icon_name = name
                                elseif p.IconPixmap then
                                    -- Handle IconPixmap update
                                    pcall(function()
                                        local pixmap_array = p.IconPixmap
                                        local target_size = systray.config.icon_size
                                        local best_w, best_h, best_data
                                        local best_diff = math.huge

                                        for i = 0, pixmap_array:n_children() - 1 do
                                            local entry = pixmap_array:get_child_value(i)
                                            local w = entry:get_child_value(0):get_int32()
                                            local h = entry:get_child_value(1):get_int32()
                                            local diff = math.abs(w - target_size)
                                            if diff < best_diff or (diff == best_diff and w > (best_w or 0)) then
                                                best_w, best_h = w, h
                                                best_data = entry:get_child_value(2)
                                                best_diff = diff
                                            end
                                        end

                                        if best_w and best_h and best_data then
                                            local data_bytes = best_data:get_data_as_bytes()
                                            local raw_data = data_bytes:get_data()
                                            if raw_data and #raw_data >= best_w * best_h * 4 then
                                                item:set_icon_pixmap(best_w, best_h, raw_data)
                                                local data = systray._private.item_data[item]
                                                if data then
                                                    data.icon_surface = item.icon
                                                end
                                            end
                                        end
                                    end)
                                end
                                -- Set flag for icon_change_triggers_urgent feature
                                -- Apps like Slack change their icon instead of using proper
                                -- SNI status/overlay, so this lets users detect that
                                local data = systray._private.item_data[item]
                                if data then
                                    if data.ignore_next_icon_change then
                                        -- This icon change was likely the app clearing its badge
                                        -- after user clicked, so don't set the urgent flag
                                        data.ignore_next_icon_change = false
                                    else
                                        data.urgent_from_icon_change = true
                                    end
                                end
                                -- Emit update for classic widget
                                capi.awesome.emit_signal("systray::update")
                            end
                        end)
                    elseif signal_name == "NewStatus" then
                        if params and params:n_children() > 0 then
                            local status = params:get_child_value(0):get_string()
                            item.status = status
                            -- Status change may affect visibility, emit update
                            capi.awesome.emit_signal("systray::update")
                        end
                    elseif signal_name == "NewToolTip" then
                        -- Refetch ToolTip property
                        pcall(function()
                            local p = proxy:Get("org.kde.StatusNotifierItem", "ToolTip")
                            if p then
                                if p[3] then item.tooltip_title = p[3] end
                                if p[4] then item.tooltip_body = p[4] end
                            end
                        end)
                    elseif signal_name == "NewAttentionIcon" then
                        -- Refetch AttentionIcon properties
                        fetch_item_properties(service, path, function(p)
                            if p then
                                -- Try AttentionIconName first
                                if p.AttentionIconName then
                                    local ok, name = pcall(function() return p.AttentionIconName:get_string() end)
                                    if ok and name and name ~= "" then
                                        item.attention_icon_name = name
                                    end
                                elseif p.AttentionIconPixmap then
                                    -- Try AttentionIconPixmap
                                    pcall(function()
                                        local pixmap_array = p.AttentionIconPixmap
                                        local target_size = systray.config.icon_size
                                        local best_w, best_h, best_data
                                        local best_diff = math.huge

                                        for i = 0, pixmap_array:n_children() - 1 do
                                            local entry = pixmap_array:get_child_value(i)
                                            local w = entry:get_child_value(0):get_int32()
                                            local h = entry:get_child_value(1):get_int32()
                                            local diff = math.abs(w - target_size)
                                            if diff < best_diff or (diff == best_diff and w > (best_w or 0)) then
                                                best_w, best_h = w, h
                                                best_data = entry:get_child_value(2)
                                                best_diff = diff
                                            end
                                        end

                                        if best_w and best_h and best_data then
                                            local data_bytes = best_data:get_data_as_bytes()
                                            local raw_data = data_bytes:get_data()
                                            if raw_data and #raw_data >= best_w * best_h * 4 then
                                                item:set_attention_pixmap(best_w, best_h, raw_data)
                                            end
                                        end
                                    end)
                                end
                            end
                            -- Emit update signal
                            capi.awesome.emit_signal("systray::update")
                        end)
                    elseif signal_name == "NewOverlayIcon" then
                        -- Refetch OverlayIcon properties
                        fetch_item_properties(service, path, function(p)
                            if p then
                                -- Try OverlayIconName first
                                if p.OverlayIconName then
                                    local ok, name = pcall(function() return p.OverlayIconName:get_string() end)
                                    if ok and name and name ~= "" then
                                        item.overlay_icon_name = name
                                    elseif ok and name == "" then
                                        -- Empty name means clear overlay
                                        item:clear_overlay()
                                    end
                                elseif p.OverlayIconPixmap then
                                    -- Try OverlayIconPixmap
                                    pcall(function()
                                        local pixmap_array = p.OverlayIconPixmap
                                        if pixmap_array:n_children() == 0 then
                                            -- Empty array means clear overlay
                                            item:clear_overlay()
                                            return
                                        end
                                        local target_size = math.floor(systray.config.icon_size / 3)
                                        local best_w, best_h, best_data
                                        local best_diff = math.huge

                                        for i = 0, pixmap_array:n_children() - 1 do
                                            local entry = pixmap_array:get_child_value(i)
                                            local w = entry:get_child_value(0):get_int32()
                                            local h = entry:get_child_value(1):get_int32()
                                            local diff = math.abs(w - target_size)
                                            if diff < best_diff or (diff == best_diff and w > (best_w or 0)) then
                                                best_w, best_h = w, h
                                                best_data = entry:get_child_value(2)
                                                best_diff = diff
                                            end
                                        end

                                        if best_w and best_h and best_data then
                                            local data_bytes = best_data:get_data_as_bytes()
                                            local raw_data = data_bytes:get_data()
                                            if raw_data and #raw_data >= best_w * best_h * 4 then
                                                item:set_overlay_pixmap(best_w, best_h, raw_data)
                                            end
                                        end
                                    end)
                                else
                                    -- Neither property present - clear overlay
                                    item:clear_overlay()
                                end
                            end
                            capi.awesome.emit_signal("systray::update")
                        end)
                    end
                end)
            end
        )

        -- Emit the global signal so user code can create widgets
        capi.awesome.emit_signal("systray::added", item)

        -- Also emit systray::update for classic wibox.widget.systray compatibility
        capi.awesome.emit_signal("systray::update")
    end)
end

--- Unregister a systray item.
-- @tparam string service D-Bus service name
-- @tparam string path D-Bus object path
unregister_item = function(service, path)
    if service:find("/") then
        local parts = {}
        for part in service:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        service = parts[1]
        path = "/" .. table.concat(parts, "/", 2)
    end

    path = path or "/StatusNotifierItem"
    local item_key = service .. path

    local item = systray._private.items[item_key]
    if item then
        systray._private.items[item_key] = nil

        -- Stop watching for name vanishing
        local data = systray._private.item_data[item]
        if data and data.name_watch_id then
            Gio.bus_unwatch_name(data.name_watch_id)
        end
        systray._private.item_data[item] = nil  -- Clean up Lua-side data

        -- Emit removal signal
        capi.awesome.emit_signal("systray::removed", item)

        -- Remove from C-side tracking array
        capi.systray_item.unregister(item)

        -- Also emit systray::update for classic wibox.widget.systray compatibility
        capi.awesome.emit_signal("systray::update")
    end
end

---------------------------------------------------------------------------
-- StatusNotifierWatcher interaction
---------------------------------------------------------------------------

--- Fetch list of already-registered items from the watcher.
local function fetch_registered_items()
    systray._private.bus:call(
        SNI_WATCHER_BUS,
        SNI_WATCHER_PATH,
        "org.freedesktop.DBus.Properties",
        "Get",
        GLib.Variant("(ss)", {SNI_WATCHER_IFACE, "RegisteredStatusNotifierItems"}),
        GLib.VariantType("(v)"),
        Gio.DBusCallFlags.NONE,
        -1,
        nil,
        function(conn, result)
            local ok, ret = pcall(function()
                return conn:call_finish(result)
            end)

            if not ok or not ret then
                return
            end

            -- Unpack (v) -> as
            local items_variant = ret:get_child_value(0):get_variant()

            for i = 0, items_variant:n_children() - 1 do
                local service = items_variant:get_child_value(i):get_string()
                protected_call(register_item, service)
            end
        end
    )
end

--- Register as a StatusNotifierHost with the watcher.
local function register_as_host()
    if systray._private.host_registered then
        return
    end

    local host_name = get_host_name()

    systray._private.bus:call(
        SNI_WATCHER_BUS,
        SNI_WATCHER_PATH,
        SNI_WATCHER_IFACE,
        "RegisterStatusNotifierHost",
        GLib.Variant("(s)", {host_name}),
        nil,
        Gio.DBusCallFlags.NONE,
        -1,
        nil,
        function(conn, result)
            local ok, ret = pcall(function()
                return conn:call_finish(result)
            end)

            if ok then
                systray._private.host_registered = true

                -- Fetch existing items
                fetch_registered_items()
            else
                gdebug.print_warning("systray: Failed to register as host: " ..
                    tostring(ret))
            end
        end
    )
end

--- Subscribe to watcher signals for item registration/unregistration.
local function subscribe_to_watcher_signals()
    -- StatusNotifierItemRegistered(service: string)
    systray._private.bus:signal_subscribe(
        SNI_WATCHER_BUS,
        SNI_WATCHER_IFACE,
        "StatusNotifierItemRegistered",
        SNI_WATCHER_PATH,
        nil,
        Gio.DBusSignalFlags.NONE,
        function(conn, sender, path, iface, signal, params)
            protected_call(function()
                local service = params:get_child_value(0):get_string()
                register_item(service)
            end)
        end
    )

    -- StatusNotifierItemUnregistered(service: string)
    systray._private.bus:signal_subscribe(
        SNI_WATCHER_BUS,
        SNI_WATCHER_IFACE,
        "StatusNotifierItemUnregistered",
        SNI_WATCHER_PATH,
        nil,
        Gio.DBusSignalFlags.NONE,
        function(conn, sender, path, iface, signal, params)
            protected_call(function()
                local service = params:get_child_value(0):get_string()
                unregister_item(service)
            end)
        end
    )
end

--- Watch for the StatusNotifierWatcher to appear on the bus.
local function watch_for_watcher()
    Gio.bus_watch_name(
        Gio.BusType.SESSION,
        SNI_WATCHER_BUS,
        Gio.BusNameWatcherFlags.NONE,
        GObject.Closure(function(conn, name, owner)
            -- Watcher appeared
            subscribe_to_watcher_signals()
            register_as_host()
        end),
        GObject.Closure(function(conn, name)
            -- Watcher vanished
            systray._private.host_registered = false

            -- Clear all items
            for key, item in pairs(systray._private.items) do
                capi.awesome.emit_signal("systray::removed", item)
            end
            systray._private.items = {}
            systray._private.item_data = {}  -- Clear Lua-side data too
        end)
    )
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Initialize the systray watcher.
-- This should be called once during startup. It connects to the D-Bus
-- session bus and begins monitoring for StatusNotifierItems.
-- @treturn boolean true if initialization succeeded
function systray.init()
    if systray._private.initialized then
        return true
    end

    -- Get session bus
    local ok, bus = pcall(function()
        return Gio.bus_get_sync(Gio.BusType.SESSION)
    end)

    if not ok or not bus then
        gdebug.print_warning("systray: Failed to connect to session bus: " ..
            tostring(bus))
        return false
    end

    systray._private.bus = bus
    systray._private.initialized = true

    -- Start watching for the StatusNotifierWatcher
    watch_for_watcher()

    return true
end

--- Get all current systray items.
-- @treturn table Array of systray_item objects
function systray.get_items()
    local items = {}
    for _, item in pairs(systray._private.items) do
        table.insert(items, item)
    end
    return items
end

--- Get the number of systray items.
-- @treturn number Number of items
function systray.count()
    local n = 0
    for _ in pairs(systray._private.items) do
        n = n + 1
    end
    return n
end

--- Set the preferred icon size.
-- @tparam number size Icon size in pixels (default 24)
function systray.set_icon_size(size)
    systray.config.icon_size = size or 24
end

--- Get the icon surface for an item.
-- Returns the cairo surface from IconPixmap, or nil if using icon_name.
-- @tparam systray_item item The systray item
-- @treturn cairo.ImageSurface|nil The icon surface, or nil
function systray.get_icon_surface(item)
    local data = systray._private.item_data[item]
    return data and data.icon_surface
end

--- Get Lua-side data for an item.
-- Used to access flags like urgent_from_icon_change that can't be stored
-- on the C userdata object.
-- @tparam systray_item item The systray item
-- @tparam[opt] string key Specific key to retrieve, or nil for full table
-- @treturn any The value for the key, or the full data table
function systray.get_item_data(item, key)
    local data = systray._private.item_data[item]
    if not data then return nil end
    if key then return data[key] end
    return data
end

---------------------------------------------------------------------------
-- DBusMenu support
---------------------------------------------------------------------------

local DBUSMENU_IFACE = "com.canonical.dbusmenu"

--- Parse a DBusMenu layout recursively.
-- @tparam GVariant layout The menu layout variant (ia{sv}av format)
-- @tparam table cache Property cache from GetLayout
-- @treturn table Menu items suitable for awful.menu
local function parse_dbusmenu_layout(layout, cache)
    if not layout then return nil end

    local items = {}

    -- layout is (ia{sv}av) = (id, properties, children)
    local id = layout:get_child_value(0):get_int32()
    local props_variant = layout:get_child_value(1)
    local children_variant = layout:get_child_value(2)

    -- Parse properties
    local props = {}
    for i = 0, props_variant:n_children() - 1 do
        local entry = props_variant:get_child_value(i)
        local key = entry:get_child_value(0):get_string()
        local value = entry:get_child_value(1):get_variant()
        props[key] = value
    end

    -- Parse children
    for i = 0, children_variant:n_children() - 1 do
        local child_variant = children_variant:get_child_value(i):get_variant()
        local child_props_variant = child_variant:get_child_value(1)
        local child_children = child_variant:get_child_value(2)

        -- Get child properties
        local child_props = {}
        for j = 0, child_props_variant:n_children() - 1 do
            local entry = child_props_variant:get_child_value(j)
            local key = entry:get_child_value(0):get_string()
            local value = entry:get_child_value(1):get_variant()
            child_props[key] = value
        end

        -- Get label and type
        local label = child_props["label"] and child_props["label"]:get_string() or ""
        local item_type = child_props["type"] and child_props["type"]:get_string() or "standard"
        local visible = child_props["visible"] == nil or child_props["visible"]:get_boolean()
        local enabled = child_props["enabled"] == nil or child_props["enabled"]:get_boolean()
        local child_id = child_variant:get_child_value(0):get_int32()

        if visible and label ~= "" then
            -- Remove underscores (mnemonics)
            label = label:gsub("_", "")

            if item_type == "separator" then
                -- Separator
                table.insert(items, { "---" })
            elseif child_children:n_children() > 0 then
                -- Submenu
                local submenu = parse_dbusmenu_layout(child_variant, cache)
                if submenu and #submenu > 0 then
                    table.insert(items, { label, submenu })
                end
            else
                -- Regular item with callback
                table.insert(items, {
                    label,
                    function()
                        -- This will be replaced with actual click handler
                    end,
                    _dbusmenu_id = child_id,
                    _enabled = enabled,
                })
            end
        elseif item_type == "separator" and visible then
            table.insert(items, { "---" })
        end
    end

    return items
end

--- Fetch and return the DBusMenu for an item.
-- @tparam systray_item item The systray item
-- @tparam function callback Called with (menu_items, item) or (nil) on error
function systray.fetch_menu(item, callback)
    if not item or not item.bus_name or not item.menu_path or item.menu_path == "" then
        callback(nil)
        return
    end

    local bus_name = item.bus_name
    local menu_path = item.menu_path


    -- Call GetLayout to get the menu structure
    -- GetLayout(parentId: int, recursionDepth: int, propertyNames: as) -> (revision: uint, layout: (ia{sv}av))
    systray._private.bus:call(
        bus_name,
        menu_path,
        DBUSMENU_IFACE,
        "GetLayout",
        GLib.Variant("(iias)", {0, -1, {}}),  -- Get all from root, all levels, all properties
        GLib.VariantType("(u(ia{sv}av))"),
        Gio.DBusCallFlags.NONE,
        -1,
        nil,
        function(conn, result)
            local ok, ret = pcall(function()
                return conn:call_finish(result)
            end)

            if not ok or not ret then
                callback(nil)
                return
            end

            -- Parse the layout
            local ok2, menu_items = pcall(function()
                local layout = ret:get_child_value(1)
                return parse_dbusmenu_layout(layout, {})
            end)

            if not ok2 or not menu_items then
                callback(nil)
                return
            end

            -- Replace callback placeholders with actual Event calls
            local function setup_callbacks(items)
                for _, menu_item in ipairs(items) do
                    if type(menu_item) == "table" then
                        local id = menu_item._dbusmenu_id
                        if id then
                            menu_item[2] = function()
                                -- Call Event method to activate menu item
                                systray._private.bus:call(
                                    bus_name,
                                    menu_path,
                                    DBUSMENU_IFACE,
                                    "Event",
                                    GLib.Variant("(isvu)", {id, "clicked", GLib.Variant("s", ""), 0}),
                                    nil,
                                    Gio.DBusCallFlags.NONE,
                                    -1,
                                    nil,
                                    nil
                                )
                            end
                            menu_item._dbusmenu_id = nil
                            menu_item._enabled = nil
                        end
                        -- Recurse into submenus
                        if type(menu_item[2]) == "table" then
                            setup_callbacks(menu_item[2])
                        end
                    end
                end
            end

            setup_callbacks(menu_items)
            callback(menu_items, item)
        end
    )
end

-- Auto-initialize when the module is loaded
-- (after a short delay to ensure awesome global is ready)
local glib = require("lgi").GLib
glib.idle_add(glib.PRIORITY_DEFAULT, function()
    systray.init()
    return false  -- Don't repeat
end)

return systray

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
