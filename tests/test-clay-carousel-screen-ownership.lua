local awful = require("awful")
local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local carousel = awful.layout.suit.carousel

local physical = screen.primary
local g = physical.geometry
local third = math.floor(g.width / 3)
local left, t
local clients = {}
local names = { "ownership_first", "ownership_middle", "ownership_last" }

local function frames(tree)
    return assert(tonumber(tree:match("output %S+ scale [^\n]* frames (%d+)")), tree)
end

local function ownership(label, tree)
    for i, c in ipairs(clients) do
        assert(c.screen == physical,
            label .. ": " .. names[i] .. " changed screen after solved geometry\n" .. tree)
        assert(c.first_tag == t,
            label .. ": " .. names[i] .. " changed tag after solved geometry\n" .. tree)
        assert(c:_clay_geometry_is_solved(),
            label .. ": " .. names[i] .. " geometry does not match the solve\n" .. tree)
    end
    local outside, entirely_outside = false, false
    local pg = physical.geometry
    for line in tree:gmatch("[^\n]+") do
        if line:match("^%s*CLIENT ") then
            local x, width = line:match("box (%-?%d+),%-?%d+ (%d+)x%d+")
            x, width = tonumber(x), tonumber(width)
            assert(x and width, line)
            outside = outside or x < pg.x or x + width > pg.x + pg.width
            entirely_outside = entirely_outside or x + width <= pg.x or x >= pg.x + pg.width
        end
    end
    assert(outside, label .. ": no client box extends outside the viewport\n" .. tree)
    assert(entirely_outside, label .. ": no column is entirely outside the viewport\n" .. tree)
    io.stderr:write("[PASS] " .. label .. ": screen, tag, solved geometry and offscreen columns\n")
end

local function box_x(tree, name)
    for line in tree:gmatch("[^\n]+") do
        if line:match("^%s*CLIENT ") and line:find("CLIENT " .. name .. " ", 1, true) then
            return assert(tonumber(line:match("box (%-?%d+),%-?%d+ %d+x%d+")), line)
        end
    end
    error("missing CLIENT line for " .. name .. "\n" .. tree)
end

local function after_frame(action, check)
    local before
    return function(count)
        if count == 1 then
            before = frames(awesome._clay_tree(physical))
            action()
            return nil
        end
        local tree = awesome._clay_tree(physical)
        if frames(tree) <= before and count < 20 then return nil end
        assert(frames(tree) > before, "layout did not publish a frame\n" .. tree)
        check(tree)
        return true
    end
end

local steps = {
    function()
        assert(test_client.is_available(), "test terminal is unavailable")
        assert(third > 0, "physical output is too narrow to split")
        physical:fake_resize(g.x + third, g.y, g.width - third, g.height)
        left = screen.fake_add(g.x, g.y, third, g.height)
        t = assert(physical.tags[#physical.tags])
        t:view_only()
        t.layout = awful.layout.suit.tile
        awful.screen.focus(physical)
        carousel.scroll_duration = 0
        return true
    end,
}

for i, name in ipairs(names) do
    steps[#steps + 1] = function(count)
        if count == 1 then test_client(name) end
        local c = utils.find_client_by_class(name)
        if not c then return nil end
        if not clients[i] then
            clients[i] = c
            c.floating = false
            c.carousel_column_width = 1
            return nil
        end
        if client.focus == c and c.screen == physical and c.first_tag == t
            and c:_clay_geometry_is_solved() then return true end
    end
end

steps[#steps + 1] = function()
    for _, c in ipairs(clients) do
        if c.screen ~= physical or c.first_tag ~= t or not c:_clay_geometry_is_solved() then
            return nil
        end
    end
    return true
end

steps[#steps + 1] = after_frame(function()
    t.layout = carousel
    client.focus = clients[3]
end, function(tree)
    ownership("last-column focus", tree)
    assert(client.focus == clients[3], "last client did not receive focus")
end)

steps[#steps + 1] = after_frame(function()
    client.focus = clients[1]
end, function(tree)
    ownership("first-column focus", tree)
    assert(client.focus == clients[1], "first client did not receive focus")
end)

steps[#steps + 1] = after_frame(function()
    awful.screen.focus(physical)
    require("somewm.inspector").toggle()
end, function(tree)
    assert(physical.inspector, "inspector did not open on the physical screen")
    ownership("inspector open", tree)
end)

steps[#steps + 1] = after_frame(function()
    require("somewm.inspector").toggle()
end, function(tree)
    assert(not physical.inspector, "inspector did not close on the physical screen")
    ownership("inspector closed", tree)
end)

steps[#steps + 1] = after_frame(function()
    clients[2].screen = left
end, function(tree)
    assert(clients[2].screen == left, "authored screen move did not reach the left screen")
    assert(clients[2].first_tag and clients[2].first_tag.screen == left,
        "moved client has no tag on the left screen")
    assert(box_x(tree, names[2]) >= left.geometry.x
        and box_x(tree, names[2]) < left.geometry.x + left.geometry.width,
        "moved client's box is outside the left screen x range\n" .. tree)
end)

steps[#steps + 1] = after_frame(function()
    clients[2].screen = physical
end, function(tree)
    assert(clients[2].screen == physical, "authored screen move did not return to the physical screen")
    assert(clients[2].first_tag and clients[2].first_tag.screen == physical,
        "returned client has no tag on the physical screen")
    box_x(tree, names[2])
    ownership("returned", tree)
end)

steps[#steps + 1] = function()
    t.layout = awful.layout.suit.tile
    left:fake_remove()
    physical:fake_resize(g.x, g.y, g.width, g.height)
    for _, c in ipairs(clients) do c:kill() end
    return true
end

steps[#steps + 1] = function(count)
    local tree = awesome._clay_tree(physical)
    local restored = not tree:match("\n%s*SCREEN %d+ ")
        and physical.geometry.x == g.x and physical.geometry.width == g.width
    if not restored and count < 20 then return nil end
    assert(restored, "physical screen was not restored\n" .. tree)
    return runner.step_kill_clients(count)
end

runner.run_steps(steps, { kill_clients = false })
