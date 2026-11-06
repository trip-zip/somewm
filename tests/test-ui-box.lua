local runner = require('_runner')
local async = require('_async')
local ui = require('ui')
local awful = require('awful')
local color = require('gears.color')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local s = screen[1]

local function dump() return awesome._clay_tree(s) end
local function wait(fn)
    assert(async.wait_for_condition(fn, 3, .02), 'timed out\n' .. dump())
end
local function line(name)
    for text in dump():gmatch('[^\n]+') do
        local escaped = name:gsub('%.', '%%.')
        if text:match('^    %x+%s+' .. escaped .. ' ') or text:match('^%s+' .. escaped .. ' ') then return text end
    end
    return ''
end
local function pixel(x, y, r, g, b)
    local pr, pg, pb = capture.read(surface(s.content), x, y)
    return pr == r and pg == g and pb == b
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function refused(fn, word, value)
    local ok, message = pcall(fn)
    assert(not ok and message:find(word, 1, true), tostring(message))
    if value then assert(message:find(value, 1, true), message) end
end
local function contains(parent, child)
    for _, n in ipairs(parent.children) do if n == child then return true end end
    return false
end

runner.run_async(function()
    local wallpaper = awful.wallpaper {screen = s, bg = '#202020'}
    mouse.coords {x = 900, y = 600}
    local drawins = #drawin.get()
    local root_drawins = #root.drawins()
    local escaped_hosts = 0
    local function exposed() escaped_hosts = escaped_hosts + 1 end
    drawin.connect_signal('property::geometry', exposed)
    drawin.connect_signal('property::screen', exposed)
    local b = ui.box {parent = s, x = 20, y = 20, width = 80, height = 30, bg = '#00ff00'}
    assert(#drawin.get() == drawins and #root.drawins() == root_drawins)
    assert(type(b) == 'node' and b.kind == 'box' and b.object == nil)
    assert(b.parent == s.tree and contains(s.tree, b))
    for _, found in ipairs(s.tree.children) do if found.id == b.id then assert(found == b) end end
    assert(b.width == 80 and b.height == 30 and b.x == 20 and b.y == 20)
    assert(b.bg == '#00ff00ff' and b.visible and b.direction == 'row')
    assert(b.gap == 0 and b.padding == 0 and b.radius == 0 and b.border_width == 0)
    assert(b.border_color == nil and b.aspect_ratio == 0 and b.clip == false)
    assert(equal(b.align, {x = 'left', y = 'top'}) and b.label == nil)
    wait(function() return line('ui.box'):find('w=fixed(80)', 1, true)
        and line('ui.box'):find('h=fixed(30)', 1, true) and pixel(50, 35, 0, 255, 0) end)
    assert(not pixel(10, 10, 0, 255, 0))
    mouse.coords {x=50,y=35}
    wait(function() return mouse.object_under_pointer() == b end)
    mouse.coords {x=900,y=600}
    assert(not line('ui.box'):find('column', 1, true))
    b.direction, b.gap, b.padding = 'column', 4, {x = 8}
    wait(function() local l = line('ui.box')
        return l:find('column', 1, true) and l:find('gap 4', 1, true)
            and l:find('pad 8,8,0,0', 1, true) end)
    assert(equal(b.padding, {left=8, right=8, top=0, bottom=0}) and b.direction == 'column' and b.gap == 4)
    assert(not pixel(20, 30, 255, 0, 0))
    b.border_width, b.border_color = 3, '#ff0000'
    wait(function() return pixel(20, 30, 255, 0, 0) end)
    assert(b.border_width == 3 and b.border_color == '#ff0000ff')
    b.border_width = 0
    wait(function() return pixel(20, 20, 0, 255, 0) end)
    b.radius = 10
    wait(function() return not pixel(20, 20, 0, 255, 0) and pixel(50, 35, 0, 255, 0) end)
    assert(b.radius == 10)
    assert(pixel(50, 35, 0, 255, 0))
    b.visible = false
    wait(function() return not pixel(50, 35, 0, 255, 0) end)
    b.visible = true
    wait(function() return pixel(50, 35, 0, 255, 0) end)
    local signals = 0
    b:connect_signal('property::bg', function() signals = signals + 1 end)
    b.bg = '#0000ff'
    assert(signals == 1 and b.bg == '#0000ffff')
    b.bg = '#0000ff'
    assert(signals == 1)
    wait(function() return pixel(50, 35, 0, 0, 255) end)
    b.visible = false

    local parent = ui.box {parent = s, x = 100, y = 100, width = 105, height = 50,
        direction = 'row', gap = 10, padding = 5, bg = '#000000', label = 'placed',
        ui.box {width = 40, height = 40, bg = '#ff0000', label = 'red_child'},
        ui.box {width = 40, height = 40, bg = '#0000ff', label = 'blue_child'},
    }
    local children = parent.children
    assert(#children == 2 and children[1].label == 'red_child' and children[2].label == 'blue_child')
    for _, child in ipairs(children) do
        assert(child.parent == parent and child.kind == 'box' and child.object == nil)
    end
    local function ordered(first, second)
        local d = dump()
        local p = d:find(' placed ', 1, true)
        local a = d:find(' ' .. first .. ' ', 1, true)
        local z = d:find(' ' .. second .. ' ', 1, true)
        return p and a and z and p < a and a < z
    end
    wait(function() return ordered('red_child', 'blue_child') and pixel(120,125,255,0,0)
        and pixel(170,125,0,0,255) and pixel(145,125,0,0,0) end)
    assert(line('placed'):find('box 100,100', 1, true), dump())
    assert(line('red_child'):match('^    %x+%s+red_child'), dump())
    assert(not ordered('blue_child', 'red_child'))
    children[1]:swap(children[2])
    assert(parent.children[1] == children[2] and parent.children[2] == children[1])
    wait(function() return ordered('blue_child', 'red_child') and pixel(120,125,0,0,255)
        and pixel(170,125,255,0,0) end)
    local fit = ui.box {parent = s, direction = 'row', gap = 10, padding = 5,
        bg = '#000000', label = 'fitted',
        ui.box {width = 40, height = 40, bg = '#ff0000'},
    }
    assert(fit.width == 'fit' and fit.height == 'fit' and fit.x == 0 and fit.y == 0)
    wait(function() return line('fitted'):find('box 0,0 50x50', 1, true) and pixel(25,25,255,0,0) end)
    assert(not line('fitted'):find('box 0,0 80x50', 1, true))
    fit.width, fit.height = 80, 'fit'
    wait(function() return line('fitted'):find('box 0,0 80x50', 1, true)
        and dump():find('screen 1 80x50+0+0', 1, true) end)
    assert(fit.width == 80 and fit.height == 'fit')

    local words = ui.box {parent = parent, label = 'words', visible = false}
    local cases = {
        {'width', 'grow'}, {'height', '50%'}, {'width', {'fit', 10, 50}},
        {'height', {'grow', 20, 60}}, {'width', {'fit', 0, 0}, 'fit'},
        {'height', {'grow', 0, 0}, 'grow'}, {'aspect_ratio', 2},
        {'padding', {2, 3}, {left=2, right=2, top=3, bottom=3}},
        {'padding', {left=1, right=2, top=3, bottom=4}}, {'padding', {1,2,3,4}, {left=1, right=2, top=3, bottom=4}},
        {'border_width', {left=1, right=2, top=3, bottom=4, between=5}},
        {'border_width', {1,2,3,4,5}, {left=1, right=2, top=3, bottom=4, between=5}},
        {'padding', {2,2,2,2}, 2}, {'border_width', {2,2,2,2,0}, 2},
        {'align', 'center', {x='center', y='center'}}, {'align', 'left', {x='left', y='top'}},
        {'align', 'right', {x='right', y='top'}}, {'align', 'top', {x='left', y='top'}},
        {'align', 'bottom', {x='left', y='bottom'}},
        {'align', {x='right', y='bottom'}}, {'clip', true}, {'clip', 'x'}, {'clip', 'y'},
    }
    for _, case in ipairs(cases) do
        words[case[1]] = case[2]
        assert(equal(words[case[1]], case[3] or case[2]), 'readback ' .. case[1])
    end
    refused(function() words.padding = {1,2,left=3} end, 'padding')
    refused(function() words.padding = {x=2,left=3} end, 'padding')
    refused(function() words.width = {'fit',1,2,unexpected=true} end, 'width')
    local pattern = color('#abcdef')
    words.bg = pattern
    assert(words.bg == '#abcdefff')
    local before = {width = words.width, bg = words.bg, radius = words.radius, gap = words.gap}
    refused(function() ui.box {bogus = 7} end, 'bogus')
    refused(function() words.bogus = 7 end, 'bogus')
    refused(function() words.x = 1 end, 'x')
    refused(function() words.bg = {type='linear', from={0,0}, to={10,0}, stops={{0,'#000000'}, {1,'#ffffff'}}} end, 'step 4')
    refused(function() words.radius = {1,2,3,4} end, 'step 4')
    refused(function() words.gap = 'oops' end, 'gap')
    local fractions = {
        {'gap', 1.5, '1.5'}, {'padding', 2.5, '2.5'},
        {'padding', {x=2.5,y=3}, '2.5'}, {'padding', {2,3.5}, '3.5'},
        {'border_width', 1.5, '1.5'},
        {'border_width', {left=1.5,right=2,top=3,bottom=4}, '1.5'},
        {'border_width', {1,2.5,3,4}, '2.5'},
        {'border_width', {between=5.5}, '5.5'},
    }
    for _, case in ipairs(fractions) do
        local word, value, text = case[1], case[2], case[3]
        local previous = words[word]
        refused(function() words[word] = value end, word, text)
        assert(equal(words[word], previous), 'failed write changed ' .. word)
        refused(function() ui.box {[word] = value} end, word, text)
    end
    local empty = ui.box {parent = s, label = 'empty', bg='#0000ff'}
    refused(function() empty.x = 1 end, 'x')
    wait(function() return line('empty'):find('box 0,0 0x0', 1, true) end)
    assert(pixel(0,0,0,0,0), 'an empty fit box painted its retained host size')
    for key, value in pairs(before) do assert(equal(words[key], value), 'failed write changed ' .. key) end
    refused(function() parent.width = 'fit' end, 'width')
    assert(parent.width == 105)
    words.visible = true
    words.width, words.height, words.aspect_ratio = 20, 10, 2
    wait(function() return line('words'):find('w=fixed(20)', 1, true)
        and line('words'):find('h=fixed(10)', 1, true) end)
    local layout = ui.box {parent=s, x=300, y=200, width=200, height=100,
        bg='#000000', label='layout_words',
        ui.box {width=40, height=20, bg='#ffffff', label='size_words'},
    }
    local sized = layout.children[1]
    local function solved(w, h)
        return line('size_words'):find(' '..w..'x'..h, 1, true)
    end
    wait(function() return solved(40,20) end)
    sized.width = '50%'
    wait(function() return line('size_words'):find('w=percent(0.5)', 1, true) and solved(100,20) end)
    sized.width = {'fit', 30, 60}
    wait(function() return line('size_words'):find('w=fit>=30<=60', 1, true) and solved(30,20) end)
    sized.width = {'grow', 30, 60}
    wait(function() return line('size_words'):find('w=grow>=30<=60', 1, true) and solved(60,20) end)
    sized.width = 'grow'
    wait(function() return solved(200,20) end)
    sized.width, sized.height, sized.aspect_ratio = 40, 'fit', 2
    wait(function() return solved(40,20) end)
    sized.aspect_ratio = 1
    wait(function() return solved(40,40) end)
    sized.aspect_ratio, sized.height = 0, 20
    layout.align = {x='right', y='bottom'}
    wait(function() return line('size_words'):find('box 460,280 40x20', 1, true)
        and pixel(480,290,255,255,255) end)
    layout.align = 'center'
    wait(function() return line('size_words'):find('box 380,240 40x20', 1, true) end)
    layout.align = 'left'
    wait(function() return line('size_words'):find('box 300,200 40x20', 1, true) end)
    layout.align = 'right'
    wait(function() return line('size_words'):find('box 460,200 40x20', 1, true) end)
    layout.align = 'bottom'
    wait(function() return line('size_words'):find('box 300,280 40x20', 1, true) end)
    layout.align = 'top'
    wait(function() return line('size_words'):find('box 300,200 40x20', 1, true) end)
    layout.padding = {left=1, right=2, top=3, bottom=4}
    wait(function() return line('layout_words'):find('pad 1,2,3,4', 1, true)
        and line('size_words'):find('box 301,203 40x20', 1, true) end)
    layout.x, layout.y = 310, 210
    wait(function() return line('layout_words'):find('box 310,210 200x100', 1, true) end)
    local border = ui.box {parent=s, x=600,y=200,width=100,height=60,
        direction='row',gap=10,bg='#000000',border_color='#ff0000',label='border_words',
        ui.box {width=30,height=40}, ui.box {width=30,height=40},
    }
    wait(function() return line('border_words') ~= '' and pixel(601,220,0,0,0) end)
    border.border_width = {left=2,right=3,top=4,bottom=5,between=6}
    wait(function() return pixel(600,220,255,0,0) and pixel(699,220,255,0,0)
        and pixel(650,201,255,0,0) and pixel(650,259,255,0,0)
        and pixel(635,220,255,0,0) end)
    for _, axis in ipairs {'x','y',true} do
        sized.clip = axis
        wait(function() return line('size_words'):find('cut=' .. (axis == true and 'both' or axis), 1, true) end)
    end
    local solid = color('#abcdef')
    sized.bg = solid
    wait(function() return pixel(320,220,171,205,239) end)
    mouse.coords {x=320,y=220}
    wait(function() return mouse.object_under_pointer() == layout end)
    layout:detach()
    collectgarbage('collect')
    mouse.coords {x=900,y=600}
    border:detach()
    local count = #s.tree.children
    refused(function() ui.box {parent=s, parent} end, 'x')
    assert(parent.parent == s.tree and #s.tree.children == count)
    refused(function() ui.box {parent=false} end, 'parent')
    local id = b.id
    b:detach()
    assert(not contains(s.tree, b))
    refused(function() return b.kind end, string.format('node %u no longer exists', id))
    local child_id = children[1].id
    parent:detach()
    refused(function() return children[1].kind end, string.format('node %u no longer exists', child_id))
    fit:detach()
    empty:detach()
    wait(function() return not dump():find('ui.box', 1, true) and not dump():find('placed', 1, true) end)
    assert(escaped_hosts == 0, 'internal drawin escaped through a class signal')
    drawin.disconnect_signal('property::geometry', exposed)
    drawin.disconnect_signal('property::screen', exposed)
    wallpaper:remove_screen(s)
    runner.done()
end)
