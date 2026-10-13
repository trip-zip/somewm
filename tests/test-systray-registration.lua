local runner = require("_runner")
local timer = require("gears.timer")
local lgi = require("lgi")
local Gio, GLib, GObject = lgi.Gio, lgi.GLib, lgi.GObject
require("awful.systray")
local bus = Gio.bus_get_sync(Gio.BusType.SESSION)
local path = "/RegistrationTestItem"
local service = bus:get_unique_name() .. path
local requests, settled, fail_fetch = 0, false, false
local registration

local info = Gio.DBusNodeInfo.new_for_xml([[
<node><interface name="org.freedesktop.DBus.Properties">
<method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
</interface></node>
]])

local function announce()
    assert(bus:emit_signal(nil, "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher", "StatusNotifierItemRegistered",
        GLib.Variant("(s)", {service})))
end

local function matching_items()
    local found = {}
    for _, item in ipairs(systray_item.get_items()) do
        if item.bus_name == bus:get_unique_name() and item.object_path == path then
            found[#found + 1] = item
        elseif item.status ~= "Passive" then
            item.status = "Passive"
        end
    end
    return found
end

runner.run_steps {
    function(count)
        if count == 1 then
            registration = assert(bus:register_object(path, info.interfaces[1],
                GObject.Closure(function(_, _, _, _, method, _, invocation)
                    assert(method == "GetAll")
                    requests = requests + 1
                    -- Hold replies while all three announcements reach the host.
                    timer.start_new(0.2, function()
                        if fail_fetch then
                            invocation:return_dbus_error("org.freedesktop.DBus.Error.Failed", "Unavailable")
                        else
                            invocation:return_value(GLib.Variant("(a{sv})", {{
                                Id = GLib.Variant("s", "registration-test"),
                                Status = GLib.Variant("s", "Active"),
                            }}))
                        end
                        settled = true
                    end)
                end), nil, nil))
            assert(registration ~= 0)
            announce()
            announce()
            announce()
        end
        local items = matching_items()
        if not settled or #items == 0 then
            assert(count < 30, "the item never registered")
            return
        end
        assert(#items == 1, "three announcements created " .. #items .. " items")
        assert(requests == 1, "three announcements started " .. requests .. " fetches")
        assert(items[1].id == "registration-test")
        return true
    end,
    function(count)
        if count == 1 then
            assert(bus:emit_signal(nil, "/StatusNotifierWatcher",
                "org.kde.StatusNotifierWatcher", "StatusNotifierItemUnregistered",
                GLib.Variant("(s)", {service})))
        end
        if #matching_items() > 0 then
            assert(count < 30, "the item never unregistered")
            return
        end
        fail_fetch, settled = true, false
        announce()
        return true
    end,
    function(count)
        matching_items()
        if not settled then
            assert(count < 30, "the failed fetch never replied")
            return
        end
        assert(#matching_items() == 0, "a failed fetch created an item")
        -- Wait another tick for the host to consume the error before retrying.
        return true
    end,
    function(count)
        if count == 1 then
            fail_fetch, settled = false, false
            announce()
        end
        local items = matching_items()
        if not settled or #items == 0 then
            assert(count < 30, "registration could not retry after a failed fetch")
            return
        end
        assert(#items == 1 and requests == 3, "retry did not create exactly one item")
        assert(bus:emit_signal(nil, "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher", "StatusNotifierItemUnregistered",
            GLib.Variant("(s)", {service})))
        assert(bus:unregister_object(registration))
        return true
    end,
    function(count)
        if #matching_items() > 0 then
            assert(count < 30, "the item remained after cleanup")
            return
        end
        return true
    end,
}
