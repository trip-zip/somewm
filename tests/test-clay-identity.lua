-- luacheck: globals awesome screen
local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")
local shape = require("gears.shape")
local clay = require("wibox.clay")
local composite = require("awful.client.clay")
local s = screen[1]
local c, box, home, away
local fake, fake_box, original_geometry
local original_client, original_wibox

local function u32(value) return value % 0x100000000 end
local function bxor(a, b)
    local value, place = 0, 1
    while a > 0 or b > 0 do
        if a % 2 ~= b % 2 then value = value + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
    end
    return value
end

-- Clay__HashStringWithOffset with seed zero and unsigned 32-bit arithmetic.
local function hash(text, offset)
    local value = 0
    for i = 1, #text do
        value = u32(value + text:byte(i))
        value = u32(value + value * 1024)
        value = bxor(value, math.floor(value / 64))
    end
    value = u32(value + offset)
    value = u32(value + value * 1024)
    value = bxor(value, math.floor(value / 64))
    value = u32(value + value * 8)
    value = bxor(value, math.floor(value / 2048))
    return u32(value + value * 32768 + 1)
end

local layout = {name = "identity", arrange = function() end}
function layout._clay()
    local children = {}
    for _, client in ipairs(s.tiled_clients) do
        local frame = composite.describe(client, {w = 160, h = 100, wsrc = "user", hsrc = "user"})
        -- A background emits a rectangle with the client frame's element id.
        frame.bg = {1, 0, 0, 1}
        children[#children + 1] = frame
    end
    return {name = "identity-layout", w = "grow", h = "grow", children = children}
end

local function ids()
    local client_id, wibox_id, surface_id
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line:find("client identity_client", 1, true) then
            local id = line:match("^  (%x+) RECTANGLE")
            if id then client_id = tonumber(id, 16) end
            id = line:match("^  (%x+) CUSTOM")
            if id then surface_id = tonumber(id, 16) end
        end
        -- A path frame emits CUSTOM under WIBOX's id, before its content.
        if line:find("box 400,40 120x80 ", 1, true) then
            local id = line:match("^  (%x+) CUSTOM")
            if id then wibox_id = tonumber(id, 16) end
        end
    end
    return client_id, wibox_id, surface_id
end

runner.run_steps({
    function(count)
        if count == 1 then
            home = s.selected_tag
            home.layout = layout
            away = awful.tag.add("identity-away", {screen = s, layout = layout})
            awful.spawn {"./build-test/test-transient-client", "identity_client"}
        end
        c = utils.find_client_by_class("identity_client")
        assert(count < 30, "client did not map")
        if not c then return end
        c.floating, c.border_width, c.shadow, c.animation = false, 0, false, false
        box = wibox {screen = s, x = s.geometry.x + 400, y = s.geometry.y + 40,
            width = 120, height = 80, visible = true, bg = "#00ff00",
            shape = shape.hexagon, shadow = false, animation = false}
        awful.layout.arrange(s)
        return true
    end,
    function(count)
        local client_id, wibox_id, surface_id = ids()
        if not client_id or not wibox_id or not surface_id then
            assert(count < 30, "client, surface and wibox element ids missing from dump")
            return
        end
        local client_node_id, surface_node_id = awesome._test_node_id(c)
        assert(client_id == hash("client", client_node_id), "client does not hash its node id")
        assert(surface_id == hash("SURFACE", surface_node_id), "surface does not hash its node id")
        assert(wibox_id == hash("WIBOX", awesome._test_node_id(box.drawin)), "wibox does not hash its node id")
        original_client, original_wibox = client_id, wibox_id
        c:move_to_tag(away)
        return true
    end,
    function(count)
        local client_id, wibox_id = ids()
        if client_id then
            assert(count < 30, "client remained on the original tag")
            return
        end
        assert(wibox_id == original_wibox, "moving the client changed the wibox id")
        away:view_only()
        return true
    end,
    function(count)
        local client_id, wibox_id = ids()
        if not client_id then
            assert(count < 30, "client did not appear on its new tag")
            return
        end
        assert(client_id == original_client and wibox_id == original_wibox, "tag move changed element ids")
        c:move_to_tag(home)
        home:view_only()
        return true
    end,
    function(count)
        local client_id, wibox_id = ids()
        if not client_id then
            assert(count < 30, "client did not return to its original tag")
            return
        end
        assert(client_id == original_client and wibox_id == original_wibox, "returning changed element ids")
        box.shape, box.border_width, box.shadow, box.animation = nil, 0, false, false
        return true
    end,
    function(count)
        local dump = awesome._clay_tree(s)
        local frame = dump:match("\n%s+CLIENT identity_client [^\n]+")
        local plain = dump:match("WIBOX screen 1 120x80%+400%+40[^\n]+")
        if not frame or not plain or plain:find("custom", 1, true) then
            assert(count < 30, "client frame and plain wibox have not been declared")
            return
        end
        for _, entry in ipairs {{c, frame}, {box.drawin, plain}} do
            local x, y, w, h = entry[2]:match(" box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
            assert(x, "missing solved box: " .. entry[2])
            local nx, ny, nw, nh = awesome._test_node_solved(entry[1])
            assert(nx == tonumber(x) + s.geometry.x and ny == tonumber(y) + s.geometry.y
                and nw == tonumber(w) and nh == tonumber(h), "node box differs from dump: " .. entry[2])
        end
        c:kill()
        away:delete()
        return true
    end,
    function(count)
        if count == 1 then
            local g = s.geometry
            original_geometry = g
            s:fake_resize(g.x, g.y, g.width - 240, g.height)
            fake = screen.fake_add(g.x + g.width - 240, g.y + 160, 200, 140)
            local probe = wibox.widget.base.make_widget()
            -- The float's target in the dump is the SCREEN element id.
            clay.describe_widget(probe, function()
                return {w = 10, h = 10, wsrc = "user", hsrc = "user",
                    float = true, _attach = "output", parent = 0, own = 0}
            end, "screen-id-probe")
            fake_box = wibox {screen = fake, x = fake.geometry.x + 20, y = fake.geometry.y + 20,
                width = 120, height = 80, visible = true, bg = "#0000ff",
                shape = shape.hexagon, shadow = false, animation = false, widget = probe}
        end
        local dump = awesome._clay_tree(s)
        local screen_id = dump:match("screen%-id%-probe [^\n]-target (%x+)")
        local wibox_id
        local g, origin = fake_box:geometry(), s.geometry
        local position = string.format("box %d,%d %dx%d ", g.x - origin.x, g.y - origin.y,
            g.width, g.height)
        for line in dump:gmatch("[^\n]+") do
            if line:find(position, 1, true) then
                local id = line:match("^  (%x+) CUSTOM")
                if id then wibox_id = tonumber(id, 16) end
            end
        end
        if not screen_id or not wibox_id then
            assert(count < 30, "fake screen and wibox element ids missing from dump")
            return
        end
        assert(dump:find("SCREEN " .. fake.index .. " ", 1, true), "fake screen has no SCREEN element")
        assert(tonumber(screen_id, 16) == hash("SCREEN", awesome._test_node_id(fake)),
            "screen does not hash its node id")
        assert(wibox_id == hash("WIBOX", awesome._test_node_id(fake_box.drawin)),
            "fake screen wibox does not hash its node id")
        return true
    end,
    function(count)
        local plain = awesome._clay_tree(s):match("WIBOX screen 1 120x80%+400%+40[^\n]+")
        if not plain then
            assert(count < 30, "plain wibox has no WIBOX element")
            return
        end
        assert(not plain:find("radii", 1, true) and not plain:find("radius", 1, true)
            and not plain:find("pad ", 1, true), "plain wibox frame adds decoration")
        box.visible, fake_box.visible = false, false
        fake:fake_remove()
        local g = original_geometry
        s:fake_resize(g.x, g.y, g.width, g.height)
        return true
    end,
}, {kill_clients = false})
