local runner = require('_runner')
local async = require('_async')
local test_client = require('_client')
local awful = require('awful')
local wibox = require('wibox')

local function position(list, value)
    for i, item in ipairs(list) do
        if item == value then return i end
    end
    error('missing object in order')
end

local function find(root, object)
    if root.object == object then return root end
    for _, child in ipairs(root.children) do
        local found = find(child, object)
        if found then return found end
    end
end

local function refused(fn, reason, a, b)
    local ok, message = pcall(fn)
    assert(not ok, 'operation must refuse')
    assert(message:find(reason, 1, true), message)
    assert(message:find(string.format('node %u', a), 1, true), message)
    if b then assert(message:find(string.format('node %u', b), 1, true), message) end
end

runner.run_async(function()
    local s = screen[1]
    s.selected_tag.layout = awful.layout.suit.tile
    assert(test_client.get_terminal_info().executable == 'kitty')
    assert(test_client('tree_face_a'))
    local a = assert(async.wait_for_client('tree_face_a', 5))
    assert(test_client('tree_face_b'))
    local b = assert(async.wait_for_client('tree_face_b', 5))
    a.animation, b.animation = false, false
    awful.titlebar(a, {position = 'top', size = 24}):setup {
        wibox.widget.textbox('tree face'), layout = wibox.layout.fixed.horizontal,
    }
    awful.titlebar(a, {position = 'left', size = 12}):setup {
        layout = wibox.layout.fixed.vertical,
    }
    local box = wibox {screen = s, x = 20, y = 20, width = 80, height = 30,
        visible = true, bg = '#00ff00'}
    assert(async.wait_for_condition(function() return find(s.tree, box.drawin) end, 3))
    local root = s.tree
    assert(type(root) == 'node' and root.kind == 'screen')
    assert(root.object == s and root.parent == nil and root.root == root)
    assert(root.protected and root.label == 'screen' and root.layer == nil)
    assert(s.tree == s.tree)
    local weak = setmetatable({}, {__mode = 'k'})
    weak[assert(find(root, a))] = true
    collectgarbage('collect')
    collectgarbage('collect')
    assert(next(weak) == nil, 'the face cache retained unused userdata')
    local an, bn = assert(find(root, a)), assert(find(root, b))
    assert(not a.floating and an.kind == 'client' and an.layer == 'normal')
    assert(a.parent == root and b.parent == root)
    assert(a.parent.children[position(a.parent.children, an)] == an)
    assert(find(root, box.drawin).kind == 'box')
    assert(find(root, box.drawin).layer == 'normal')
    box.ontop = true
    assert(find(root, box.drawin).layer == 'top')
    box.ontop = false
    a.ontop = true
    assert(an.layer == 'ontop')
    a.ontop = false
    a.fullscreen = true
    assert(an.layer == 'fullscreen')
    a.fullscreen = false
    s.selected_tag.layout = awful.layout.suit.floating
    local function signal_handler() end
    an:connect_signal('unused', signal_handler)
    an:disconnect_signal('unused', signal_handler)
    collectgarbage('collect')
    assert(find(root, a) == an)
    assert(root.children ~= root.children)

    local function walk(n)
        local children = n.children
        assert(n.root == root)
        assert(n.first_child == children[1] and n.last_child == children[#children])
        for i, child in ipairs(children) do
            assert(child.parent == n)
            assert(child.previous_sibling == children[i - 1])
            assert(child.next_sibling == children[i + 1])
            walk(child)
        end
    end
    walk(root)
    local titlebars = {
        [a:titlebar_top()] = true, [a:titlebar_left()] = true,
        [a:titlebar_right()] = true, [a:titlebar_bottom()] = true,
    }
    local bars, surfaces = 0, 0
    for _, child in ipairs(a.children) do
        assert(child == an.children[position(an.children, child)])
        if child.kind == 'box' then
            bars = bars + 1
            assert(type(child.object) == 'drawable')
            assert(titlebars[child.object], 'titlebar drawable missing or duplicated')
            titlebars[child.object] = nil
        else
            assert(child.kind == 'surface' and child.object == nil)
            surfaces = surfaces + 1
        end
    end
    assert(bars == 4 and surfaces == 1 and next(titlebars) == nil)
    for _, key in ipairs {'id', 'kind', 'layer', 'label', 'protected', 'parent',
        'first_child', 'last_child', 'next_sibling', 'previous_sibling', 'root',
        'children', 'object'} do
        local before = an[key]
        refused(function() an[key] = false end, 'read-only', an.id)
        if key ~= 'children' then assert(an[key] == before) end
    end

    local raised, lowered = {}, {}
    local function on_raised(c) raised[#raised + 1] = c end
    local function on_lowered(c) lowered[#lowered + 1] = c end
    client.connect_signal('raised', on_raised)
    client.connect_signal('lowered', on_lowered)
    local function signals(expected_raised, expected_lowered)
        assert(#raised == #expected_raised and #lowered == #expected_lowered,
            'unexpected number of client stacking signals')
        for i, c in ipairs(expected_raised) do assert(raised[i] == c) end
        for i, c in ipairs(expected_lowered) do assert(lowered[i] == c) end
        raised, lowered = {}, {}
    end

    local function dump_above(top, bottom)
        local dump = awesome._clay_tree(s)
        local ti = dump:find('CLIENT ' .. top .. ' ', 1, true)
        local bi = dump:find('CLIENT ' .. bottom .. ' ', 1, true)
        return ti and bi and ti > bi
    end
    local function ordered(top, bottom, top_name, bottom_name)
        assert(position(root.children, top) > position(root.children, bottom))
        assert(position(client.get(s, true), top.object) < position(client.get(s, true), bottom.object))
        assert(async.wait_for_condition(function() return dump_above(top_name, bottom_name) end, 3, .02),
            'dump did not publish the new sibling order\n' .. awesome._clay_tree(s))
    end
    local old_index = position(root.children, an)
    root:push(an)
    signals({}, old_index > 1 and {a} or {})
    ordered(bn, an, 'tree_face_b', 'tree_face_a')
    assert(not dump_above('tree_face_a', 'tree_face_b'), 'target dump order already present before move')
    assert(select('#', an:move_after(bn)) == 0)
    signals({a}, {})
    ordered(an, bn, 'tree_face_a', 'tree_face_b')
    an:swap(bn)
    signals({b}, {a})
    ordered(bn, an, 'tree_face_b', 'tree_face_a')
    root:append(an)
    signals({a}, {})
    assert(root.last_child == an)
    root:append(an)
    signals({}, {})
    ordered(an, bn, 'tree_face_a', 'tree_face_b')
    root:push(an)
    signals({}, {a})
    assert(root.first_child == an)
    root:push(an)
    signals({}, {})
    ordered(bn, an, 'tree_face_b', 'tree_face_a')
    an:move_after(bn)
    signals({a}, {})
    an:move_after(bn)
    signals({}, {})
    an:move_before(bn)
    signals({}, {a})
    an:move_before(bn)
    signals({}, {})
    ordered(bn, an, 'tree_face_b', 'tree_face_a')
    refused(function() root:detach() end, 'protected', root.id)
    refused(function() an:detach() end, 'detach is not supported', an.id, root.id)
    refused(function() an:swap(an) end, 'itself', an.id)
    local second_box = wibox {screen = s, x = 120, y = 20, width = 80, height = 30,
        visible = true, bg = '#0000ff'}
    assert(async.wait_for_condition(function() return find(root, second_box.drawin) end, 3))
    local box_node = assert(find(root, box.drawin))
    local second_box_node = assert(find(root, second_box.drawin))
    local count = #root.children
    box_node:move_before(an)
    assert(position(root.children, box_node) + 1 == position(root.children, an))
    box_node:move_after(an)
    assert(position(root.children, an) + 1 == position(root.children, box_node))
    local reason = 'cannot swap different node kinds'
    refused(function() box_node:swap(an) end, reason, box_node.id, an.id)
    refused(function() an:swap(box_node) end, reason, an.id, box_node.id)
    root:append(box_node)
    assert(root.last_child == box_node)
    root:push(box_node)
    assert(root.first_child == box_node)
    box_node:swap(second_box_node)
    assert(root.first_child == second_box_node and #root.children == count)
    signals({}, {})
    client.disconnect_signal('raised', on_raised)
    client.disconnect_signal('lowered', on_lowered)
    second_box.visible = false
    local other = screen.fake_add(1400, 0, 320, 240)
    refused(function() other.tree:append(an) end, 'changing parents is not supported', other.tree.id, an.id)
    refused(function() other.tree:push(an) end, 'changing parents is not supported', other.tree.id, an.id)
    refused(function() an:move_before(other.tree) end, 'changing parents is not supported', an.id, other.tree.id)
    refused(function() an:move_after(other.tree) end, 'changing parents is not supported', an.id, other.tree.id)
    refused(function() an:swap(other.tree) end, 'changing parents is not supported', an.id, other.tree.id)
    other:fake_remove()
    local id = an.id
    awesome.kill(a.pid, 15)
    assert(async.wait_for_condition(function() return not a.valid end, 5))
    refused(function() an:detach() end, 'no longer exists', id)
    refused(function() return an.id end, 'no longer exists', id)
    refused(function() root:append(an) end, 'no longer exists', id)
    box.visible = false
    awesome.kill(b.pid, 15)
    assert(async.wait_for_condition(function() return not b.valid end, 5))
    runner.done()
end)
