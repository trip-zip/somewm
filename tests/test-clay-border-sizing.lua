-- Authored border widths and source pixels must work in one native solve.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local capture = require('_widget_capture')
local example = require('_clay_example')
local cairo = require('lgi').cairo
local gcolor = require('gears.color')
local awful = require('awful')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

local function source(width, height, color)
    local image = cairo.ImageSurface(cairo.Format.ARGB32, width, height)
    local cr = cairo.Context(image)
    cr:set_source(gcolor(color)); cr:paint()
    return image
end

runner.run_async(function()
    local child = wibox.container.background(nil, '#00ff00')
    local border = wibox.container.border { widget = child, fill = true,
        border_image = source(30, 20, '#ff0000'),
        borders = {left=4, right=6, top=3, bottom=7},
        paddings = {left=2, right=1, top=5, bottom=2} }
    local bar = wibox { x=100, y=100, width=200, height=80, visible=true,
        screen=screen[1], bg='#0000ff', widget=border }
    _border_sizing_host = bar
    local measurements = {}
    local function measure(name, start, memory)
        local line = string.format('%s cpu_us=%.0f lua_kib_delta=%.3f', name,
            (os.clock()-start)*1000000, collectgarbage('count')-memory)
        measurements[#measurements+1] = line
        local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        if dir then
            local file = assert(io.open(dir .. '/measurements.txt', 'w'))
            file:write(table.concat(measurements, '\n'), '\n'); file:close()
        end
    end
    local declares = 0
    local function count_declare() declares = declares + 1 end
    awesome.connect_signal('clay::declare', count_declare)
    local function solve(name, box)
        declares = 0
        local memory, start = collectgarbage('count'), os.clock()
        awesome._test_redeclare()
        measure(name, start, memory)
        assert(declares == 1, name .. ': expected one solve, got ' .. declares)
        local dump = awesome._clay_tree(screen[1])
        for line in dump:gmatch('[^\n]+') do
            if line:match('^    %x+ ') then
                assert(not line:find(' derived ',1,true) and not line:find('last-frame',1,true), line)
            end
        end
        local found
        for _, hit in ipairs(bar:find_widgets(box.x+1, box.y+1)) do
            if hit.widget == child then found = hit end
        end
        capture.assert_box(found, box, name .. ' content')
        example.save('border-' .. name .. '-first', dump)
        async.sleep(0.1)
        local settled
        for _, hit in ipairs(bar:find_widgets(box.x+1, box.y+1)) do
            if hit.widget == child then settled=hit end
        end
        capture.assert_box(settled, box, name .. ' settled content')
        example.pixel(bar.x + box.x+1, bar.y + box.y+1, '#00ff00')
        example.save('border-' .. name, awesome._clay_tree(screen[1]))
        return dump
    end
    local first = solve('cold', {x=6,y=8,width=187,height=63})
    assert(first:find('image 20x3 ',1,true), 'wrong intrinsic top crop')
    assert(first:find('image 4x10 ',1,true), 'wrong intrinsic left crop')
    example.pixel(101,101,'#ff0000')
    declares = 0
    local memory, start = collectgarbage('count'), os.clock()
    assert(awesome._test_redeclare() == 0, 'unchanged border mutated the scene')
    measure('unchanged', start, memory)
    assert(declares == 1, 'forced idle frame needed a second solve')
    local slices = border._private.slice_cache[96]
    assert(slices, 'expected source DPI')
    for _, size in ipairs {{320,140},{120,60},{200,80}} do
        bar.width, bar.height = size[1], size[2]
        solve('resize-'..size[1], {x=6,y=8,width=size[1]-13,height=size[2]-17})
        assert(slices == border._private.slice_cache[96], 'resize recropped source pixels')
        example.pixel(100+size[1]-2,102,'#ff0000')
    end
    border.borders = {left=2,right=5,top=1,bottom=4}
    local changed = solve('slices', {x=4,y=6,width=190,height=68})
    assert(changed:find('image 23x1 ',1,true), 'stale top crop after border change')
    assert(changed:find('image 2x15 ',1,true), 'stale side crop after border change')
    border.border_image = source(60,40,'#ffff00')
    changed = solve('source', {x=4,y=6,width=190,height=68})
    assert(changed:find('image 53x1 ',1,true), 'stale source size')
    example.pixel(101,110,'#ffff00')
    border.paddings = {left=3,right=4,top=2,bottom=3}
    solve('padding', {x=5,y=3,width=186,height=70})
    local side = wibox.container.background(nil, '#00ffff')
    local corner = wibox.container.background(nil, '#ff00ff')
    border.border_widgets = {left=side, bottom_right=corner}
    solve('widgets', {x=5,y=3,width=186,height=70})
    for _, pair in ipairs {{side,{x=0,y=1,width=2,height=75}},
            {corner,{x=195,y=76,width=5,height=4}}} do
        local found
        for _, hit in ipairs(bar:find_widgets(pair[2].x+1,pair[2].y+1)) do
            if hit.widget == pair[1] then found=hit end
        end
        capture.assert_box(found,pair[2],'original border widget area')
    end
    example.pixel(101,110,'#00ffff'); example.pixel(298,178,'#ff00ff')
    for _, target in ipairs {{side,1,10,1,9}, {corner,198,78,3,2}, {child,6,4,1,1}} do
        local events, handlers = {}, {}
        for i, widget in ipairs {border, target[1]} do
            for _, signal in ipairs {'button::press', 'button::release'} do
                local function handler(original, x, y, button, _, area)
                    assert(original == widget and area.widget == widget and button == 1)
                    assert(x == target[i == 1 and 2 or 4] and y == target[i == 1 and 3 or 5],
                        string.format('border input %d got %.8f,%.8f expected %d,%d', i, x, y,
                            target[i == 1 and 2 or 4], target[i == 1 and 3 or 5]))
                    events[#events+1] = signal .. i
                end
                widget:connect_signal(signal, handler)
                handlers[#handlers+1] = {widget, signal, handler}
            end
        end
        -- Aim at pixel centers so normalized protocol coordinates do not round down.
        awful.spawn {pointer, 'click', tostring(2*(100+target[2])+1), tostring(2*(100+target[3])+1),
            '2560', '1440', 'left'}
        for _=1,30 do if #events == 4 then break end; async.sleep(0.02) end
        assert(table.concat(events, ',') == 'button::press1,button::press2,button::release1,button::release2',
            'border parent/child input: ' .. table.concat(events, ','))
        for _, handler in ipairs(handlers) do handler[1]:disconnect_signal(handler[2], handler[3]) end
    end
    border.border_widgets = nil
    border.border_images = {left=source(8,12,'#ff00ff')}
    solve('images', {x=5,y=3,width=186,height=70})
    example.pixel(101,110,'#ff00ff')
    border.slice = false
    solve('unsliced', {x=5,y=3,width=186,height=70})
    example.pixel(120,102,'#ffff00')
    border.slice = true
    border.border_images = nil
    border.border_image = nil
    border.border_widgets = {left=side}
    solve('widget-only', {x=5,y=3,width=186,height=70})
    example.pixel(101,110,'#00ffff')
    example.pixel(299,110,'#0000ff')
    child.forced_width = 40
    bar.widget = wibox.layout.fixed.horizontal(border)
    solve('fit-width', {x=5,y=3,width=40,height=70})
    child.forced_width, child.forced_height = nil, 20
    bar.widget = wibox.layout.fixed.vertical(border)
    solve('fit-height', {x=5,y=3,width=186,height=20})
    awesome.disconnect_signal('clay::declare', count_declare)
    bar.visible=false
    io.stderr:write('[PASS] border inputs, source replacement, resize, padding and original widget areas in one native solve\n')
    runner.done()
end)
