-- luacheck: globals screen root awesome mouse
-- Run: make test-one TEST=tests/test-clay-titlebar.lua
local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")

local TEST_CLIENT = utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_CLIENT then
    return
end

local s = screen[1]
local c, frame, textbox, restored_box
local pressed = 0

local function box(x, y, w, h)
    return string.format("box %d,%d %dx%d ", x, y, w, h)
end

local function find(kind, wanted)
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line:find(kind, 1, true) and line:find(wanted, 1, true) then
            return line
        end
    end
end

local function update_frame()
    local geo = c:geometry()
    frame = { x = geo.x - s.geometry.x, y = geo.y - s.geometry.y,
        width = geo.width + 8, height = geo.height + 8 }
end

local function surface_box(left)
    return box(frame.x + 4 + left, frame.y + 24,
        frame.width - 8 - left, frame.height - 28)
end

local function assert_agrees()
    assert(not awesome._clay_tree(s):find("[tree!=scene]", 1, true),
        "the scene disagrees with the tree")
end

local function assert_pixel(x, y, red, green, blue)
    local r, g, b = capture.read(gsurface(root.content()),
        s.geometry.x + x, s.geometry.y + y)
    assert(r == red and g == green and b == blue,
        string.format("unexpected pixel at %d,%d: %d,%d,%d", x, y, r, g, b))
end

runner.run_steps({
    function(count)
        if count == 1 then
            awful.spawn(TEST_CLIENT)
        end
        c = utils.find_client_by_class("transient_test_parent")
        return c ~= nil or nil
    end,
    function()
        c.floating = true
        c.border_width = 4
        c.shadow = false
        c:geometry({ x = s.geometry.x + 100, y = s.geometry.y + 100,
            width = 200, height = 120 })
        textbox = wibox.widget.textbox("hello")
        textbox.valign = "top"
        textbox:connect_signal("button::press", function()
            pressed = pressed + 1
        end)
        awful.titlebar(c, { size = 20, bg_normal = "#00ff00", bg_focus = "#00ff00" }):setup({
            textbox,
            layout = wibox.layout.fixed.horizontal,
        })
        return true
    end,
    function(count)
        local titlebar = find("TITLEBAR transient_test_parent ", "converted:")
        update_frame()
        if not titlebar or not find("CUSTOM", surface_box(0)) then
            assert(count < 20, "the converted top titlebar never reached its box")
            return
        end
        assert(titlebar:find("0 images", 1, true), "the titlebar has image leaves")
        assert(find("BORDER", box(frame.x, frame.y, frame.width, frame.height)),
            "missing client border")
        assert(find("TEXT", string.format("box %d,%d ", frame.x + 4, frame.y + 4)),
            "the textbox does not start inside the top bar")
        assert_pixel(frame.x + frame.width - 10, frame.y + 10, 0, 255, 0)
        assert_agrees()
        awful.titlebar(c, { position = "left", size = 10,
            bg_normal = "#0000ff", bg_focus = "#0000ff" }):setup({
            layout = wibox.layout.fixed.vertical,
        })
        return true
    end,
    function(count)
        update_frame()
        if not find("CUSTOM", surface_box(10)) then
            assert(count < 20, "the left titlebar never inset the surface")
            return
        end
        assert_pixel(frame.x + 8, frame.y + math.floor(frame.height / 2), 0, 0, 255)
        assert_agrees()
        restored_box = surface_box(10)
        -- Deliver the drawable's press signal through its widget hit query.
        c:titlebar_top():emit_signal("button::press", 4, 4, 1, {})
        c:titlebar_top():emit_signal("button::release", 4, 4, 1, {})
        assert(pressed == 1, "the drawable press did not reach the textbox")
        -- The pointer over the bar resolves to the client through the band
        -- (input.c xytonode): the bar's nodes sit in the output's tree, not
        -- in c->scene, so nothing else names the client there. A fake
        -- button press goes to the Wayland seat, not through the
        -- compositor's handler (tests/test-numlock-setting.lua), so the
        -- press above is the drawable's own signal.
        mouse.coords({ x = s.geometry.x + frame.x + 8,
            y = s.geometry.y + frame.y + 8 })
        mouse._fake_motion(1, 0)
        mouse._fake_motion(-1, 0)
        return true
    end,
    function(count)
        if mouse.object_under_pointer() ~= c then
            assert(count < 20, "the pointer over the titlebar does not resolve to the client")
            return
        end
        c.fullscreen = true
        return true
    end,
    function(count)
        local geo = c:geometry()
        local wanted = box(geo.x - s.geometry.x, geo.y - s.geometry.y, geo.width, geo.height)
        if not find("CUSTOM", wanted) then
            assert(count < 20, "the fullscreen surface still has an inset")
            return
        end
        assert(not find("TITLEBAR transient_test_parent", ""),
            "fullscreen still declares titlebars")
        assert_agrees()
        c.fullscreen = false
        return true
    end,
    function(count)
        if not find("CUSTOM", restored_box) then
            assert(count < 20, "leaving fullscreen did not restore the surface box")
            return
        end
        assert(find("TITLEBAR transient_test_parent ", "converted:"),
            "leaving fullscreen did not restore the titlebar")
        assert_agrees()
        c:kill()
        return true
    end,
    function(count)
        if not c.valid then
            return true
        end
        assert(count < 20, "the client did not exit")
    end,
}, { kill_clients = false })
