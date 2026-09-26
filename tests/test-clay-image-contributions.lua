-- Images share only declaration-equivalent widget areas, including input.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local example = require('_clay_example')
local capture = require('_widget_capture')
local cairo = require('lgi').cairo
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

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

runner.run_async(function()
    local src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
    local cr = cairo.Context(src)
    cr:set_source_rgb(1, 0, 0); cr:paint()
    local failures, retained = {}, {}
    for _, kind in ipairs {'builtin', 'adhoc'} do
        local current_src = src
        local image
        if kind == 'builtin' then
            image = wibox.widget.imagebox(src, false)
        else
            image = wibox.widget.base.make_widget(nil, nil, {enable_properties = true})
            clay.describe_widget(image, function()
                return {specs = {{image = current_src._native, name = 'image', w = 20, h = 10}}}
            end, 'image-contribution')
        end
        local margin = wibox.container.margin(image, 0, 0, 0, 0)
        local popup = awful.popup {screen = screen[1], visible = true, ontop = true,
            bg = '#0000ff', border_width = 0, shadow = false, widget = margin,
            placement = function(d) awful.placement.top_left(d, {offset = {x = 100, y = 100}}) end}
        retained[#retained + 1] = popup
        local events, click_x = {}, 2
        for i, widget in ipairs {margin, image} do
            for _, signal in ipairs {'button::press', 'button::release'} do
                widget:connect_signal(signal, function(original, x, y, button, mods, area)
                    assert(original == widget and area.widget == widget)
                    assert(x == click_x and y == 2 and button == 1 and #mods == 0)
                    events[#events + 1] = signal .. i
                end)
            end
        end
        local token
        for _, phase in ipairs {'fit', 'minimum', 'restored'} do
            image.forced_width = phase == 'minimum' and 40 or nil
            click_x = phase == 'minimum' and 35 or 2
            async.sleep(0.15)
            local g = popup:geometry()
            example.save('image-contribution-' .. kind .. '-' .. phase, awesome._clay_tree(screen[1]))
            assert(g.width == (phase == 'minimum' and 40 or 20) and g.height == 10,
                kind .. '-' .. phase .. ': ' .. g.width .. 'x' .. g.height)
            local hits = {}
            for _, hit in ipairs(popup:find_widgets(click_x, 2)) do hits[hit.widget] = hit end
            for _, widget in ipairs {margin, image} do
                capture.assert_box(hits[widget], {x = 0, y = 0, width = g.width, height = 10}, 'original image area')
            end
            example.pixel(g.x + 2, g.y + 2, '#ff0000')
            if phase == 'minimum' then example.pixel(g.x + 35, g.y + 2, '#0000ff') end
            events = {}
            awful.spawn {pointer, 'click', tostring(g.x + click_x), tostring(g.y + 2), '1280', '720', 'left'}
            for _ = 1, 30 do if #events == 4 then break end; async.sleep(0.02) end
            assert(table.concat(events, ',') == 'button::press1,button::press2,button::release1,button::release2',
                'original image input changed: ' .. table.concat(events, ','))
            local node = assert(node_for(popup._drawable._clay_tree, image))
            if token then assert(node.occurrence == token, 'image occurrence changed') end
            token = node.occurrence
            if (node.image ~= nil) ~= (phase ~= 'minimum') then failures[#failures + 1] = kind .. '-' .. phase end
            example.save('image-contribution-' .. kind .. '-' .. phase, awesome._clay_tree(screen[1]))
        end
        current_src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
        local green = cairo.Context(current_src)
        green:set_source_rgb(0, 1, 0); green:paint()
        if kind == 'builtin' then image.image = current_src
        else image:emit_signal('widget::redraw_needed') end
        async.sleep(0.15)
        local g = popup:geometry()
        assert(g.width == 20 and g.height == 10)
        example.pixel(g.x + 2, g.y + 2, '#00ff00')
        example.save('image-contribution-' .. kind .. '-replacement', awesome._clay_tree(screen[1]))
        if kind == 'adhoc' then
            screen[1].inspector = true
            async.sleep(0.15)
            example.save('image-contribution-inspector', awesome._clay_tree(screen[1]))
            screen[1].inspector = false
        end
        popup.visible = false
    end
    io.stderr:write('[PASS] built-in/ad-hoc image pixels, original areas, stable occurrences and real parent/child input\n')
    assert(#failures == 0, 'image folding differs: ' .. table.concat(failures, ', '))
    runner.done()
end)
