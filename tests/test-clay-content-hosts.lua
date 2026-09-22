-- Original widget areas and input survive folding into a content-sized host.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local example = require('_clay_example')
local capture = require('_widget_capture')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    local leaf = wibox.widget.base.make_widget()
    clay.describe_widget(leaf, function() return {w = 40, h = 30, bg = {1, 0, 0, 1}} end,
        'content-host-leaf')
    local margin = wibox.container.margin(leaf, 4, 4, 4, 4)
    local background = wibox.container.background(margin, '#0000ff')
    local popup = awful.popup {screen = screen[1], visible = true, ontop = true,
        bg = '#00000000', border_width = 0, shadow = false, widget = background,
        placement = function(d) awful.placement.top_left(d, {offset = {x = 100, y = 100}}) end}
    local events, failures = {}, {}
    for i, widget in ipairs {background, margin, leaf} do
        for _, signal in ipairs {'button::press', 'button::release'} do
            widget:connect_signal(signal, function(original, x, y, button, mods, area)
                assert(original == widget and area.widget == widget)
                assert(x == (i == 3 and 2 or 6) and y == (i == 3 and 2 or 6))
                assert(button == 1 and #mods == 0)
                events[#events + 1] = signal .. i
            end)
        end
    end
    local function node_for(node, widget)
        if clay.bindings then
            for _, binding in clay.bindings(node) do
                if binding.widget == widget then return node end
            end
        elseif node.widget == widget then return node end
        for _, child in ipairs(node.children or {}) do
            local found = node_for(child, widget)
            if found then return found end
        end
    end
    for _, phase in ipairs {'combined', 'paint-boundary', 'recombined'} do
        popup.bg = phase == 'paint-boundary' and '#00ff0080' or '#00000000'
        async.sleep(0.15)
        local g = popup:geometry()
        assert(g.width == 48 and g.height == 38)
        local hits = {}
        for _, hit in ipairs(popup:find_widgets(6, 6)) do hits[hit.widget] = hit end
        for _, widget in ipairs {background, margin} do
            capture.assert_box(hits[widget], {x = 0, y = 0, width = 48, height = 38}, 'original wrapper')
        end
        capture.assert_box(hits[leaf], {x = 4, y = 4, width = 40, height = 30}, 'inset child')
        example.pixel(g.x + 2, g.y + 2, '#0000ff')
        example.pixel(g.x + 6, g.y + 6, '#ff0000')
        events = {}
        awful.spawn {pointer, 'click', tostring(g.x + 6), tostring(g.y + 6), '1280', '720', 'left'}
        for _ = 1, 30 do if #events == 6 then break end; async.sleep(0.02) end
        assert(table.concat(events, ',') == 'button::press1,button::press2,button::press3,button::release1,button::release2,button::release3',
            'original parent/child delivery changed: ' .. table.concat(events, ','))
        local tree = popup._drawable._clay_tree
        local folded = node_for(tree, background) == tree and node_for(tree, margin) == tree
        if folded ~= (phase ~= 'paint-boundary') then failures[#failures + 1] = phase end
        example.save('content-host-' .. phase, awesome._clay_tree(screen[1]))
    end
    screen[1].inspector = true
    async.sleep(0.15)
    example.save('content-host-inspector', awesome._clay_tree(screen[1]))
    screen[1].inspector = false
    popup.visible = false
    io.stderr:write('[PASS] original host/widget areas, ordered parent/child input and pixels across paint boundary changes\n')
    assert(#failures == 0, 'content host folding differs: ' .. table.concat(failures, ', '))
    runner.done()
end)
