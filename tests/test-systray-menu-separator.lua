-- A DBusMenu separator opens as a line in the tray's menu, not an item
-- labelled "---".
local runner = require("_runner")
local lgi = require("lgi")
local Gio, GLib, GObject = lgi.Gio, lgi.GLib, lgi.GObject
local awful = require("awful")
local beautiful = require("beautiful")
local example = require("_clay_example")
local systray = require("awful.systray")
local bus = Gio.bus_get_sync(Gio.BusType.SESSION)
local path = "/SeparatorTestMenu"
local registration, items, menu

local info = Gio.DBusNodeInfo.new_for_xml([[
<node><interface name="com.canonical.dbusmenu">
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/>
<arg type="as" direction="in"/><arg type="u" direction="out"/>
<arg type="(ia{sv}av)" direction="out"/></method>
</interface></node>
]])

local function pixel_is(x, y, want)
    return pcall(example.pixel, x, y, want)
end

local function entry(id, props)
    return GLib.Variant("(ia{sv}av)", {id, props, {}})
end

runner.run_steps {
    function()
        registration = assert(bus:register_object(path, info.interfaces[1],
            GObject.Closure(function(_, _, _, _, method, _, invocation)
                assert(method == "GetLayout")
                invocation:return_value(GLib.Variant("(u(ia{sv}av))", {1, {0, {}, {
                    entry(1, {label = GLib.Variant("s", "One")}),
                    entry(2, {type = GLib.Variant("s", "separator")}),
                    entry(3, {label = GLib.Variant("s", "Two")}),
                }}}))
            end), nil, nil))
        assert(registration ~= 0)
        systray.fetch_menu({bus_name = bus:get_unique_name(), menu_path = path},
            function(result) items = result or false end)
        return true
    end,
    function(n)
        if items == nil then assert(n < 40, "GetLayout never answered"); return end
        assert(items and #items == 3, "menu items not parsed")
        beautiful.separator_color = "#0000ff"
        menu = awful.menu {items = items, theme = {width = 120, height = 24,
            border_width = 0, bg_normal = "#ff0000", bg_focus = "#ffff00"}}
        menu:show {coords = {x = 200, y = 100}}
        return true
    end,
    function(n)
        local g = menu.wibox:geometry()
        if g.height ~= 56 then assert(n < 20, "menu is " .. g.height .. " high"); return end
        local dump = awesome._clay_tree(screen[1])
        assert(not dump:find('"---"', 1, true), "separator drawn as a label")
        assert(dump:find("box 200,124 120x8", 1, true), "separator row is not 8 high")
        example.pixel(260, 128, "#0000ff")
        example.pixel(260, 112, "#ff0000")
        example.save("systray-menu-separator", dump)
        menu:item_enter(1)
        return true
    end,
    function(n)
        if not pixel_is(260, 112, "#ffff00") then assert(n < 20, "item 1 never highlighted"); return end
        menu:item_enter(2)
        menu:exec(2, {exec = true})
        return true
    end,
    function(n)
        -- Item 1 back to normal: the frame with the separator hovered is up.
        if not pixel_is(260, 112, "#ff0000") then assert(n < 20, "hover never moved"); return end
        assert(menu.wibox.visible, "clicking the separator closed the menu")
        example.pixel(260, 125, "#ff0000")
        menu:hide()
        bus:unregister_object(registration)
        io.stderr:write("[PASS] DBusMenu separator is a line in the tray menu\n")
        return true
    end,
}
