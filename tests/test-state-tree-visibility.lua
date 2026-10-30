-- Visibility filters declarations without changing client sibling order.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local binary = utils.binary_or_skip('./build-test/test-transient-client')
if not binary then return end

runner.run_async(function()
    local s = screen[1]
    local t1 = s.selected_tag
    t1.layout = awful.layout.suit.floating
    local t2 = awful.tag.add('visibility_2', {screen = s, layout = awful.layout.suit.floating})
    local t3 = awful.tag.add('visibility_3', {screen = s, layout = awful.layout.suit.floating})
    local empty = awful.tag.add('visibility_empty', {screen = s, layout = awful.layout.suit.floating})
    local clients = {}
    local function spawn(name)
        awful.spawn {binary, name}
        local c = assert(async.wait_for_client(name, 3))
        c.floating, c.border_width, c.shadow = true, 0, false
        c.animation = false
        c:geometry {x = 100, y = 100, width = 200, height = 200}
        clients[#clients + 1] = c
        return c
    end
    local a = spawn('tree_visibility_a')
    local b = spawn('tree_visibility_b')
    local c = spawn('tree_visibility_c')
    mouse.coords {x = 900, y = 600}
    a:tags {t1, t2}
    b:tags {t1}
    c:tags {t1}
    c.sticky = true

    local function same_order(left, right)
        if #left ~= #right then return false end
        for i, object in ipairs(left) do
            if right[i] ~= object then return false end
        end
        return true
    end
    local function declared_clients()
        local result = {}
        for _, object in ipairs(awesome._test_declare_order(s)) do
            if object == a or object == b or object == c then
                result[#result + 1] = object
            end
        end
        return result
    end
    local function check(visible, siblings, message)
        local expected, selected = {}, {}
        for _, object in ipairs(visible) do selected[object] = true end
        -- client.get(s, true) is top first; declarations are bottom first.
        for i = #siblings, 1, -1 do
            if selected[siblings[i]] then expected[#expected + 1] = siblings[i] end
        end
        assert(async.wait_for_condition(function()
            if not same_order(declared_clients(), expected)
                or not same_order(client.get(s, true), siblings) then return false end
            for _, object in ipairs(clients) do
                if object:isvisible() ~= (selected[object] == true) then return false end
            end
            return true
        end, 3, .02), message)
        io.stderr:write('[PASS] ' .. message .. '\n')
    end

    local siblings = client.get(s, true)
    t2:view_only()
    check({a, c}, siblings, 'tag 2 shows the shared client and the sticky client')
    t1:view_only()
    check({a, b, c}, siblings, 'tag 1 shows all clients')
    awful.tag.viewtoggle(t2)
    check({a, b, c}, siblings, 'two selected tags declare each client once')
    a:raise()
    siblings = client.get(s, true)
    assert(siblings[1] == a, 'raise puts a above b in sibling order')
    check({a, b, c}, siblings, 'raise across selected tags puts a last in declarations')
    empty:view_only()
    check({c}, siblings, 'an empty tag still declares the sticky client')

    a:tags {t3}
    b:tags {t3}
    c:tags {t3}
    siblings = client.get(s, true)
    t3:view_only()
    check({a, b, c}, siblings, 'one tag holding every client preserves sibling order')
    client.focus = a
    assert(client.focus == a, 'a starts focused')
    t3.selected = false
    assert(client.focus ~= a, 'deselecting every tag of a unfocuses a immediately')
    check({c}, siblings, 'deselecting every tag hides nonsticky clients')
    t3:view_only()
    a:raise()
    b:raise()
    c:raise()
    siblings = {c, b, a}
    check({a, b, c}, siblings, 'a, b, c are declared bottom to top')
    for _, property in ipairs {'minimized', 'hidden'} do
        b[property] = true
        check({a, c}, siblings, property .. ' omits b without moving its sibling position')
        b[property] = false
        check({a, b, c}, siblings, 'clearing ' .. property .. ' restores b between a and c')
    end

    for _, object in ipairs(clients) do object:kill() end
    assert(async.wait_for_condition(function() return #client.get(s) == 0 end, 3))
    t1:view_only()
    t2:delete()
    t3:delete()
    empty:delete()
    runner.done()
end)
