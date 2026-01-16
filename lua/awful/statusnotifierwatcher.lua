---------------------------------------------------------------------------
--- StatusNotifierWatcher D-Bus service for somewm.
--
-- This module implements the org.kde.StatusNotifierWatcher D-Bus interface,
-- which coordinates between tray applications (StatusNotifierItems) and
-- tray hosts (like our systray module).
--
-- Applications register their tray icons with this watcher, and hosts
-- subscribe to signals to be notified when icons appear/disappear.
--
-- @author somewm contributors
-- @copyright 2024
-- @module awful.statusnotifierwatcher
---------------------------------------------------------------------------

local lgi = require("lgi")
local Gio = lgi.Gio
local GLib = lgi.GLib
local GObject = lgi.GObject

local protected_call = require("gears.protected_call")

local watcher = {
    _private = {
        initialized = false,
        bus_connection = nil,
        registered_items = {},   -- Set: service_name -> true
        registered_hosts = {},   -- Set: service_name -> true
        item_watch_ids = {},     -- service_name -> watch_id (for items)
        host_watch_ids = {},     -- service_name -> watch_id (for hosts)
    }
}

-- D-Bus constants
local WATCHER_BUS_NAME = "org.kde.StatusNotifierWatcher"
local WATCHER_PATH = "/StatusNotifierWatcher"
local WATCHER_IFACE = "org.kde.StatusNotifierWatcher"

---------------------------------------------------------------------------
-- Helper functions
---------------------------------------------------------------------------

--- Get array of registered item service names.
local function get_registered_items_array()
    local items = {}
    for service in pairs(watcher._private.registered_items) do
        table.insert(items, service)
    end
    return items
end

--- Check if any host is registered.
local function has_registered_host()
    return next(watcher._private.registered_hosts) ~= nil
end

--- Emit a signal on the watcher interface.
local function emit_signal(signal_name, variant)
    local conn = watcher._private.bus_connection
    if not conn then return end

    conn:emit_signal(
        nil,  -- destination (nil = broadcast)
        WATCHER_PATH,
        WATCHER_IFACE,
        signal_name,
        variant
    )
end

---------------------------------------------------------------------------
-- Item/Host registration and lifetime tracking
---------------------------------------------------------------------------

--- Start watching a D-Bus name for disappearance.
-- @tparam string service The D-Bus service name to watch
-- @tparam string type Either "item" or "host"
-- @treturn number The watch ID
local function watch_service(service, stype)
    local watch_id = Gio.bus_watch_name(
        Gio.BusType.SESSION,
        service,
        Gio.BusNameWatcherFlags.NONE,
        nil,  -- name_appeared_callback (we don't need it, already know it exists)
        GObject.Closure(function(conn, name)
            -- Service vanished
            if stype == "item" then
                if watcher._private.registered_items[name] then
                    watcher._private.registered_items[name] = nil
                    watcher._private.item_watch_ids[name] = nil
                    emit_signal("StatusNotifierItemUnregistered", GLib.Variant("(s)", {name}))
                end
            elseif stype == "host" then
                if watcher._private.registered_hosts[name] then
                    watcher._private.registered_hosts[name] = nil
                    watcher._private.host_watch_ids[name] = nil
                end
            end
        end)
    )
    return watch_id
end

--- Register a StatusNotifierItem.
-- @tparam string sender The D-Bus unique name of the sender
-- @tparam string service The service name provided by the item (may be empty)
local function register_item(sender, service)
    -- Per spec, if service is empty, use the sender's unique name
    -- Also, some items pass their unique name, others pass a well-known name
    local item_service = service
    if not item_service or item_service == "" then
        item_service = sender
    end

    -- If it's just a path (starts with /), prepend sender
    if item_service:sub(1, 1) == "/" then
        item_service = sender .. item_service
    end

    -- Already registered?
    if watcher._private.registered_items[item_service] then
        return
    end

    -- Register the item
    watcher._private.registered_items[item_service] = true

    -- Watch for the service disappearing
    -- Use the sender (unique name) for watching since that's what will vanish
    local watch_service_name = sender
    if not watcher._private.item_watch_ids[watch_service_name] then
        watcher._private.item_watch_ids[watch_service_name] = watch_service(watch_service_name, "item")
    end

    -- Emit signal
    emit_signal("StatusNotifierItemRegistered", GLib.Variant("(s)", {item_service}))
end

--- Register a StatusNotifierHost.
-- @tparam string sender The D-Bus unique name of the sender
-- @tparam string service The service name provided by the host
local function register_host(sender, service)
    local host_service = service
    if not host_service or host_service == "" then
        host_service = sender
    end

    -- Already registered?
    if watcher._private.registered_hosts[host_service] then
        return
    end

    -- Register the host
    watcher._private.registered_hosts[host_service] = true

    -- Watch for the service disappearing
    local watch_service_name = sender
    if not watcher._private.host_watch_ids[watch_service_name] then
        watcher._private.host_watch_ids[watch_service_name] = watch_service(watch_service_name, "host")
    end

    -- Emit signal
    emit_signal("StatusNotifierHostRegistered", GLib.Variant("()"))
end

---------------------------------------------------------------------------
-- D-Bus method handlers
---------------------------------------------------------------------------

local watcher_methods = {}

function watcher_methods.RegisterStatusNotifierItem(sender, object_path, interface, method, parameters, invocation)
    local service = parameters.value[1]
    register_item(sender, service)
    invocation:return_value(GLib.Variant("()"))
end

function watcher_methods.RegisterStatusNotifierHost(sender, object_path, interface, method, parameters, invocation)
    local service = parameters.value[1]
    register_host(sender, service)
    invocation:return_value(GLib.Variant("()"))
end

---------------------------------------------------------------------------
-- D-Bus Properties interface handler
---------------------------------------------------------------------------

local function handle_properties_get(prop_name, invocation)
    if prop_name == "RegisteredStatusNotifierItems" then
        local items = get_registered_items_array()
        invocation:return_value(GLib.Variant("(v)", {GLib.Variant("as", items)}))
        return true
    elseif prop_name == "IsStatusNotifierHostRegistered" then
        local has_host = has_registered_host()
        invocation:return_value(GLib.Variant("(v)", {GLib.Variant("b", has_host)}))
        return true
    elseif prop_name == "ProtocolVersion" then
        invocation:return_value(GLib.Variant("(v)", {GLib.Variant("i", 0)}))
        return true
    end
    return false
end

local function handle_properties_getall(iface_name, invocation)
    if iface_name == WATCHER_IFACE then
        local items = get_registered_items_array()
        local has_host = has_registered_host()

        local props = {
            RegisteredStatusNotifierItems = GLib.Variant("as", items),
            IsStatusNotifierHostRegistered = GLib.Variant("b", has_host),
            ProtocolVersion = GLib.Variant("i", 0),
        }
        invocation:return_value(GLib.Variant("(a{sv})", {props}))
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- D-Bus method dispatcher
---------------------------------------------------------------------------

local function method_call(conn, sender, object_path, interface, method, parameters, invocation)
    -- Handle org.freedesktop.DBus.Properties interface
    if interface == "org.freedesktop.DBus.Properties" then
        if method == "Get" then
            local iface_name, prop_name = unpack(parameters.value)
            if iface_name == WATCHER_IFACE then
                if handle_properties_get(prop_name, invocation) then
                    return
                end
            end
            -- Unknown property
            invocation:return_error_literal(
                Gio.DBusError.quark(),
                Gio.DBusError.UNKNOWN_PROPERTY,
                "Unknown property: " .. tostring(prop_name)
            )
            return
        elseif method == "GetAll" then
            local iface_name = parameters.value[1]
            if handle_properties_getall(iface_name, invocation) then
                return
            end
            invocation:return_value(GLib.Variant("(a{sv})", {{}}))
            return
        elseif method == "Set" then
            -- All properties are read-only
            invocation:return_error_literal(
                Gio.DBusError.quark(),
                Gio.DBusError.PROPERTY_READ_ONLY,
                "Property is read-only"
            )
            return
        end
    end

    -- Handle StatusNotifierWatcher interface
    if interface == WATCHER_IFACE then
        local handler = watcher_methods[method]
        if handler then
            protected_call(handler, sender, object_path, interface, method, parameters, invocation)
            return
        end
    end

    -- Unknown method
    invocation:return_error_literal(
        Gio.DBusError.quark(),
        Gio.DBusError.UNKNOWN_METHOD,
        "Unknown method: " .. tostring(method)
    )
end

---------------------------------------------------------------------------
-- D-Bus service setup
---------------------------------------------------------------------------

local function on_bus_acquire(conn, name)
    -- Helper to create D-Bus argument info
    local function arg(argname, signature)
        return Gio.DBusArgInfo{ name = argname, signature = signature }
    end

    local method_info = Gio.DBusMethodInfo
    local signal_info = Gio.DBusSignalInfo

    local property_info = Gio.DBusPropertyInfo

    -- Define the interface
    local interface_info = Gio.DBusInterfaceInfo {
        name = WATCHER_IFACE,
        methods = {
            method_info{
                name = "RegisterStatusNotifierItem",
                in_args = { arg("service", "s") }
            },
            method_info{
                name = "RegisterStatusNotifierHost",
                in_args = { arg("service", "s") }
            },
        },
        signals = {
            signal_info{
                name = "StatusNotifierItemRegistered",
                args = { arg("service", "s") }
            },
            signal_info{
                name = "StatusNotifierItemUnregistered",
                args = { arg("service", "s") }
            },
            signal_info{
                name = "StatusNotifierHostRegistered"
            },
        },
        properties = {
            property_info{
                name = "RegisteredStatusNotifierItems",
                signature = "as",
                flags = { "READABLE" },
            },
            property_info{
                name = "IsStatusNotifierHostRegistered",
                signature = "b",
                flags = { "READABLE" },
            },
            property_info{
                name = "ProtocolVersion",
                signature = "i",
                flags = { "READABLE" },
            },
        },
    }

    -- Property getter callback
    local function get_property(conn, sender, object_path, interface, property_name)
        if property_name == "RegisteredStatusNotifierItems" then
            return GLib.Variant("as", get_registered_items_array())
        elseif property_name == "IsStatusNotifierHostRegistered" then
            return GLib.Variant("b", has_registered_host())
        elseif property_name == "ProtocolVersion" then
            return GLib.Variant("i", 0)
        end
        return nil
    end

    -- Register the object with method and property callbacks
    conn:register_object(WATCHER_PATH, interface_info,
        GObject.Closure(method_call),
        GObject.Closure(get_property),
        nil  -- No property setter (all read-only)
    )
end

local function on_name_acquired(conn, name)
    watcher._private.bus_connection = conn
end

local function on_name_lost(conn, name)
    watcher._private.bus_connection = nil
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Initialize the StatusNotifierWatcher service.
-- This should be called once during startup. It claims the
-- org.kde.StatusNotifierWatcher name on the session bus.
-- @treturn boolean true if initialization succeeded
function watcher.init()
    if watcher._private.initialized then
        return true
    end

    watcher._private.initialized = true

    -- Claim the bus name
    Gio.bus_own_name(
        Gio.BusType.SESSION,
        WATCHER_BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        GObject.Closure(on_bus_acquire),
        GObject.Closure(on_name_acquired),
        GObject.Closure(on_name_lost)
    )

    return true
end

--- Get all registered StatusNotifierItem service names.
-- @treturn table Array of service name strings
function watcher.get_registered_items()
    return get_registered_items_array()
end

--- Check if any StatusNotifierHost is registered.
-- @treturn boolean True if at least one host is registered
function watcher.is_host_registered()
    return has_registered_host()
end

-- Auto-initialize when the module is loaded
local glib = require("lgi").GLib
glib.idle_add(glib.PRIORITY_DEFAULT, function()
    watcher.init()
    return false  -- Don't repeat
end)

return watcher

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
