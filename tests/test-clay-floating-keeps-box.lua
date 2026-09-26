local awful = require("awful")
local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

local physical = screen.primary
local g = physical.geometry
local third = math.floor(g.width / 3)
local left, t, slave, other, B, F, B2
local clients = {}
local names = { "floating_box_first", "floating_box_second" }

local function frames(tree)
    return assert(tonumber(tree:match("output %S+ scale [^\n]* frames (%d+)")), tree)
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

local function assert_box(label, box, x, y, tree)
    local actual = slave:geometry()
    assert(actual.x == x and actual.y == y
        and actual.width == box.width and actual.height == box.height,
        string.format("%s: expected %d,%d %dx%d, got %d,%d %dx%d\n%s",
            label, x, y, box.width, box.height,
            actual.x, actual.y, actual.width, actual.height, tree))
    assert(slave.screen == physical, label .. ": client changed screen\n" .. tree)
end

local function assert_moved(tree)
    assert_box("user move keeps the floating box", B, B.x + 40, B.y + 20, tree)
end

local function assert_declaration(label, G, tree)
    local client_line
    for line in tree:gmatch("[^\n]+") do
        if line:find("CLIENT " .. slave.class .. " ", 1, true) then
            client_line = line
            break
        end
    end
    assert(client_line, label .. ": missing CLIENT " .. slave.class .. "\n" .. tree)
    local pl, pt, pr, pb = client_line:match("pad (%d+),(%d+),(%d+),(%d+)")
    local X, Y, W, H = client_line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    pl, pt, pr, pb = tonumber(pl), tonumber(pt), tonumber(pr), tonumber(pb)
    X, Y, W, H = tonumber(X), tonumber(Y), tonumber(W), tonumber(H)
    assert(pl and pt and pr and pb and X and Y and W and H,
        string.format("%s: expected padding and box for %d,%d %dx%d: %s",
            label, G.x, G.y, G.width, G.height, client_line))
    local message = string.format("%s: expected box %d,%d %dx%d and w=fixed(%d) h=fixed(%d) user: %s",
        label, G.x, G.y, G.width + pl + pr, G.height + pt + pb, W, H, client_line)
    assert(X == G.x and Y == G.y, message)
    assert(W == G.width + pl + pr and H == G.height + pt + pb, message)
    assert(client_line:find(string.format("w=fixed(%d) h=fixed(%d) user", W, H), 1, true), message)
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
            return nil
        end
        if c.screen == physical and c.first_tag == t
            and c:_clay_geometry_is_solved() then return true end
    end
end

steps[#steps + 1] = function()
    for _, c in ipairs(clients) do
        if c.screen ~= physical or c.first_tag ~= t or not c:_clay_geometry_is_solved() then
            return nil
        end
    end
    local first, second = clients[1]:geometry(), clients[2]:geometry()
    assert(first.x ~= second.x, "tiled clients do not occupy separate columns")
    slave = first.x > second.x and clients[1] or clients[2]
    other = slave == clients[1] and clients[2] or clients[1]
    B = slave:geometry()
    return true
end

steps[#steps + 1] = after_frame(function()
    local stored = require("awful").client.property.get(slave, "floating_geometry")
    io.stderr:write("[STORED] " .. tostring(stored) .. "\n")
    if type(stored) == "table" then
        io.stderr:write(string.format("[STORED] x=%s y=%s width=%s height=%s\n",
            tostring(stored.x), tostring(stored.y), tostring(stored.width), tostring(stored.height)))
    end
    slave.floating = true
end, function(tree)
    assert_box("floating keeps the tiled box", B, B.x, B.y, tree)
    assert(slave.first_tag == t, "floating client changed tag\n" .. tree)
    assert_declaration("first float declaration", B, tree)
    assert(not other.floating, "other client became floating\n" .. tree)
    assert(other:_clay_geometry_is_solved(), "other client's geometry is not solved\n" .. tree)
end)

steps[#steps + 1] = after_frame(function()
    slave:geometry { x = B.x + 40, y = B.y + 20 }
end, assert_moved)

steps[#steps + 1] = after_frame(function()
    awesome._clay_dirty()
end, function(tree)
    assert_moved(tree)
    F = slave:geometry()
end)

steps[#steps + 1] = after_frame(function()
    slave.floating = false
end, function(tree)
    assert(slave:_clay_geometry_is_solved(), "retiled client's geometry is not solved\n" .. tree)
    assert(slave.screen == physical, "retiled client changed screen\n" .. tree)
    assert(slave.first_tag == t, "retiled client changed tag\n" .. tree)
    B2 = slave:geometry()
    assert(B2.x ~= F.x or B2.width ~= F.width,
        "retiled box does not differ from the floating box\n" .. tree)
end)

steps[#steps + 1] = after_frame(function()
    slave.floating = true
end, function(tree)
    assert_box("second float keeps the tiled box", B2, B2.x, B2.y, tree)
    assert_declaration("second float declaration", B2, tree)
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
