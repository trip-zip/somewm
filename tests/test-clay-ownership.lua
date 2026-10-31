-- luacheck: globals awesome screen client drawin mouse root
local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")
local naughty = require("naughty")
local shape = require("gears.shape")

local s = screen[1]
local tiled, floating, fullscreen, parent
local plain, hexagon, notification, notification_box
local popup_pid, layer_pid
local home, original_layout, original_focus, original_mouse, original_animation
local failure
local ignored = {SCISSOR_START = true, SCISSOR_END = true,
    OVERLAY_COLOR_START = true, OVERLAY_COLOR_END = true}

local function geometry_owner(box)
    local g = box:geometry()
    return string.format("screen %d %dx%d+%d+%d", box.screen.index,
        g.width, g.height, g.x, g.y)
end

local function command(line)
    local id, kind = line:match("^  (%x+) (%S+) ")
    if not id or #id ~= 8 then return end
    local owner = line:match(" rbox %-?%d+,%-?%d+ %d+x%d+ (.*)$")
    if owner then
        -- Presentation and raster diagnostics surround the owner label.
        owner = owner:gsub("^presented %-?%d+,%-?%d+ %d+x%d+ ", "")
        owner = owner:gsub(" %[[^%]]+%]", "")
        owner = owner:gsub(" raster=%d+", "")
        owner = owner:gsub(" clip$", ""):gsub(" configure$", ""):gsub(" no%-node$", "")
    end
    return kind, owner
end

local function display(item)
    notification_box = require("naughty.layout.box") {notification = item,
        border_width = 0, shadow = false, animation = false, bg = "#00ff00",
        widget_template = {widget = naughty.widget.message}}
end

local function check(dump)
    local missing, kinds, owners = {}, {}, {}
    for line in dump:gmatch("[^\n]+") do
        local kind, owner = command(line)
        if kind and not ignored[kind] then
            local owner_kind, object = (owner or ""):match("^(%S+) (.+)$")
            if not owner_kind or owner_kind == "-" or object == "-" then
                missing[#missing + 1] = line
            else
                kinds[owner_kind] = true
                owners[#owners + 1] = {kind = owner_kind, object = object, line = line}
            end
        end
    end
    assert(#missing == 0, "drawn commands without owners:\n" .. table.concat(missing, "\n"))

    local names = {}
    for kind in pairs(kinds) do names[#names + 1] = kind end
    table.sort(names)
    io.stderr:write("[OWNERS] " .. table.concat(names, ", ") .. "\n")
    for _, kind in ipairs {"client", "titlebar", "drawin", "popup", "layer", "cursor", "output"} do
        assert(kinds[kind], "missing owner kind: " .. kind)
    end

    local clients, boxes = {}, {}
    for _, c in ipairs(client.get()) do clients[c.class] = true end
    for _, d in ipairs(drawin.get()) do
        local box = d.get_wibox and d.get_wibox()
        if box then boxes[geometry_owner(box)] = true end
    end
    local notification_owner = geometry_owner(notification_box)
    boxes[notification_owner] = true
    local notification_seen = false
    for _, owner in ipairs(owners) do
        if owner.kind == "client" or owner.kind == "titlebar" or owner.kind == "popup" then
            assert(clients[owner.object], "owner names no live client app id: " .. owner.line)
        elseif owner.kind == "drawin" then
            assert(boxes[owner.object], "owner geometry names no live wibox: " .. owner.line)
            if owner.object == notification_owner then
                notification_seen = true
                io.stderr:write("[NOTIFICATION] " .. owner.line .. "\n")
            end
        end
    end
    assert(notification_seen, "notification has no drawin command owner: " .. notification_owner)
    assert(fullscreen.fullscreen and client.focus == floating,
        "fullscreen client must remain unfocused")
end

runner.run_steps({
    function(count)
        if count == 1 then
            home, original_focus, original_mouse = s.selected_tag, client.focus, mouse.coords()
            original_layout, original_animation = home.layout, root.animation
            root.animation = false
            home.layout = awful.layout.suit.tile
            awful.spawn {"./build-test/test-transient-client", "ownership_tiled"}
            awful.spawn {"./build-test/test-transient-client", "ownership_floating"}
            awful.spawn {"./build-test/test-fullscreen-client"}
            popup_pid = awful.spawn {"./build-test/test-popup-client"}
            layer_pid = awful.spawn {"./build-test/test-layer-client", "--namespace", "test-layer-bar",
                "--keyboard", "none", "--anchor", "top,left,right", "--size", "0,40",
                "--exclusive-zone", "40"}
        end
        tiled = utils.find_client_by_class("ownership_tiled")
        floating = utils.find_client_by_class("ownership_floating")
        fullscreen = utils.find_client_by_class("fullscreen_test")
        parent = utils.find_client_by_class("popup_test")
        if not tiled or not floating or not fullscreen or not parent then
            assert(count < 30, "ownership clients did not map")
            return
        end
        for _, c in ipairs {tiled, floating, fullscreen, parent} do
            c:move_to_tag(home)
            c.shadow, c.animation, c.border_width = false, false, 0
        end
        tiled.floating = false
        awful.titlebar(tiled, {size = 24, bg = "#cc8800"}):setup {
            widget = wibox.widget.textbox, text = "Ownership"}
        floating.floating, floating.ontop, floating.border_width = true, true, 10
        floating.border_color = "#ff0000"
        local g = s.geometry
        floating:geometry {x = g.x + 80, y = g.y + 140, width = 220, height = 160}
        parent.floating = true
        parent:geometry {x = g.x + 400, y = g.y + 200, width = 200, height = 200}
        fullscreen.fullscreen = true
        client.focus = floating
        fullscreen:raise()
        plain = wibox {screen = s, x = g.x + 340, y = g.y + 60, width = 120, height = 80,
            visible = true, ontop = true, bg = "#0000ff", shadow = false, animation = false}
        hexagon = wibox {screen = s, x = g.x + 500, y = g.y + 60, width = 120, height = 80,
            visible = true, ontop = true, bg = "#00ffff", shape = shape.hexagon,
            shadow = false, animation = false}
        naughty.connect_signal("request::display", display)
        notification = naughty.notification {screen = s, position = "top_right",
            message = "Ownership", timeout = 0}
        awful.layout.arrange(s)
        return true
    end,
    function(count)
        if count < 3 then return end
        awesome.kill(popup_pid, 10)
        mouse.coords({x = floating.x + 40, y = floating.y + 40}, true)
        return true
    end,
    function(count)
        local dump = awesome._clay_tree(s)
        local wanted = {"CLIENT ownership_tiled ", "TITLEBAR ownership_tiled ",
            "CLIENT ownership_floating ", "CLIENT fullscreen_test ", "fullscreen_bg ",
            "WIBOX " .. geometry_owner(plain) .. " ",
            "WIBOX " .. geometry_owner(hexagon) .. " ",
            "LAYER_BAR test-layer-bar ", " popup popup_test", " cursor "}
        if notification_box then
            wanted[#wanted + 1] = "NOTIFICATION " .. geometry_owner(notification_box) .. " "
        end
        local missing = {}
        if not notification_box then missing[#missing + 1] = "notification box" end
        for _, label in ipairs(wanted) do
            if not dump:find(label, 1, true) then missing[#missing + 1] = label end
        end
        if #missing > 0 then
            assert(count < 30, "objects missing from dump: " .. table.concat(missing, ", ") .. "\n" .. dump)
            return
        end
        local ok, err = pcall(check, dump)
        if not ok then failure = err end
        notification:destroy()
        naughty.disconnect_signal("request::display", display)
        plain.visible, hexagon.visible = false, false
        for _, c in ipairs {tiled, floating, fullscreen, parent} do c:kill() end
        -- The layer helper blocks in dispatch and cannot finish on SIGTERM.
        awesome.kill(layer_pid, 9)
        return true
    end,
    function(count)
        for _, c in ipairs {tiled, floating, fullscreen, parent} do
            if c.valid then
                assert(count < 30, "ownership client did not exit")
                return
            end
        end
        if awesome._clay_tree(s):find("test-layer-bar", 1, true) then
            assert(count < 30, "layer bar did not leave the dump")
            return
        end
        home.layout, root.animation = original_layout, original_animation
        client.focus = original_focus
        mouse.coords(original_mouse, true)
        awful.layout.arrange(s)
        assert(not failure, failure)
        io.stderr:write("[PASS] every drawn command has a live owner\n")
        return true
    end,
}, {kill_clients = false, wait_per_step = 4})
