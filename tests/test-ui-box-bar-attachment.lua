local runner = require('_runner')
local async = require('_async')
local ui = require('ui')
local awful = require('awful')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local s = screen[1]

local function dump() return awesome._clay_tree(s) end
local function wait(fn)
    assert(async.wait_for_condition(fn, 3, .02), 'timed out\n' .. dump())
end
local function line(name, index)
    for text in dump():gmatch('[^\n]+') do
        if text:find('  ' .. name .. ' ', 1, true) then
            if not index or index == 1 then return text end
            index = index - 1
        end
    end
    return ''
end
local function box(name, x, y, w, h, index)
    return line(name, index):find(('box %d,%d %dx%d'):format(x,y,w,h), 1, true)
end
local function pixel(x,y,r,g,b)
    local pr, pg, pb = capture.read(surface(s.content), x, y)
    return pr == r and pg == g and pb == b
end
local function refused(fn, message)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end
local function same(a,b)
    for _, key in ipairs {'x','y','width','height'} do assert(a[key] == b[key], key) end
end

runner.run_async(function()
    mouse.coords {x=900,y=600}
    local g = s.geometry
    local escaped, handlers = 0, {}
    for _, class in ipairs {drawin, drawable} do
        for _, signal in ipairs {'geometry','x','y','width','height','surface','bar','cursor','input_passthrough'} do
            local fn = function() escaped = escaped + 1 end
            class.connect_signal('property::'..signal, fn)
            handlers[#handlers+1] = {class, 'property::'..signal, fn}
        end
    end
    local bar = ui.box {parent=s,position='top',height=28,bg='#ff0000'}
    assert(bar.position == 'top' and bar.restrict_workarea)
    wait(function() return s.workarea.y == g.y+28 and s.workarea.height == g.height-28
        and box('WIBAR',0,0,g.width,28) and pixel(10,10,255,0,0) end)
    local wa = s.workarea
    local second = ui.box {parent=s,position='top',height=20,bg='#0000ff'}
    wait(function() return s.workarea.y == g.y+48 and box('WIBAR',0,28,g.width,20,2) end)
    second:detach()
    bar:detach()
    wait(function() return s.workarea.y == g.y end)
    assert(escaped == 0, 'screen bar emitted on its internal host')
    for _, h in ipairs(handlers) do h[1].disconnect_signal(h[2], h[3]) end
    local wb = awful.wibar {screen=s,position='top',height=28}
    wait(function() return wb:geometry().height == 28 and s.workarea.y == g.y+28 end)
    same(wb:geometry(), {x=g.x,y=g.y,width=g.width,height=28})
    same(s.workarea, wa)
    wb.visible = false
    wait(function() return s.workarea.y == g.y end)

    bar = ui.box {parent=s,position='top',height=28,restrict_workarea=false,bg='#ff0000'}
    wait(function() return box('WIBAR',0,0,g.width,28) and pixel(10,10,255,0,0) end)
    same(s.workarea, g)
    local signals = {position=0, restrict_workarea=0}
    for word in pairs(signals) do bar:connect_signal('property::'..word,
        function() signals[word] = signals[word]+1 end) end
    bar.restrict_workarea = true
    wait(function() return s.workarea.y == g.y+28 end)
    bar.restrict_workarea = true
    assert(signals.restrict_workarea == 1)
    bar.position = nil
    assert(bar.position == nil and bar.restrict_workarea)
    wait(function() return s.workarea.y == g.y and box('ui.box',0,0,0,28) end)
    assert(signals.position == 1)
    bar:detach()
    bar = ui.box {parent=s,position='left',width=40}
    wait(function() return s.workarea.x == g.x+40 and box('WIBAR',0,0,40,g.height) end)
    bar.position = nil
    wait(function() return s.workarea.x == g.x and box('ui.box',0,0,40,0) end)
    local child = ui.box {parent=bar}
    refused(function() child.position='top' end, 'ui.box position under a box is reserved')
    refused(function() ui.box {parent=bar,position='top',height=10} end, 'under a box is reserved')
    refused(function() ui.box {parent=s,position='top',height='fit'} end, 'height must be a number on a top bar')
    refused(function() ui.box {parent=s,position='top',height=10,width=20} end, 'width must be grow or absent on a top bar')
    refused(function() ui.box {parent=s,position='top',height=10,width='fit'} end, 'width must be grow or absent')
    refused(function() ui.box {parent=s,position='top',height=10,width={'grow',0,0}} end, 'width must be grow or absent')
    refused(function() ui.box {parent=s,position='top',height=10,x=0} end, 'position cannot be combined with x')
    refused(function() ui.box {parent=s,restrict_workarea=false} end, 'restrict_workarea requires position')
    refused(function() bar.restrict_workarea=true end, 'restrict_workarea requires position')
    refused(function() bar.position='middle' end, 'middle')
    bar:detach()
    for _, side in ipairs {'bottom','right'} do
        local horizontal = side == 'bottom'
        bar = ui.box {parent=s,position=side,width=horizontal and 'grow' or 12,
            height=horizontal and 12 or 'grow'}
        wait(function() return box('WIBAR', horizontal and 0 or g.width-12,
            horizontal and g.height-12 or 0, horizontal and g.width or 12,
            horizontal and 12 or g.height) end)
        bar:detach()
    end

    local target = ui.box {parent=s,x=100,y=100,width=40,height=40,label='target_box'}
    local popup = ui.box {parent=s,attachment={to=target,anchor='bottom_left',offset={y=4}},
        width=30,height=30,bg='#00ff00'}
    local changed = 0
    popup:connect_signal('property::attachment', function() changed=changed+1 end)
    wait(function() return box('POPUP',100,144,30,30) and pixel(110,154,0,255,0) end)
    local a, b = popup.attachment, popup.attachment
    assert(a ~= b and a.anchor ~= b.anchor and a.offset ~= b.offset and a.to == target)
    assert(a.anchor.target == 'bottom_left' and a.anchor.self == 'top_left')
    assert(a.offset.x == 0 and a.offset.y == 4)
    popup.attachment = a
    assert(changed == 0)
    a.offset.y = 90
    assert(popup.attachment.offset.y == 4)
    popup.attachment = {to=target,anchor={target='top_right',self='top_left'}}
    wait(function() return box('POPUP',140,100,30,30) end)
    popup.attachment = {to=target,anchor='bottom_left',offset={y=4}}
    target.x = 200
    wait(function() return box('POPUP',200,144,30,30) end)
    target.visible = false
    wait(function() return line('POPUP') == '' end)
    target.visible = true
    wait(function() return box('POPUP',200,144,30,30) end)
    popup.attachment = {to=s,anchor={target='bottom_right',self='bottom_right'}}
    wait(function() return box('POPUP',g.width-30,g.height-30,30,30) end)
    assert(popup.attachment.to == s)
    popup.attachment = {}
    assert(popup.attachment.to == s and popup.attachment.anchor.target == 'top_left')
    wait(function() return box('POPUP',0,0,30,30) end)
    child = ui.box {parent=target,width=20,height=20,label='nested_target'}
    popup.attachment = {to=child,anchor='bottom_right'}
    wait(function() return box('POPUP',220,120,30,30) end)
    assert(popup.attachment.to == child)
    child.visible = false
    wait(function() return line('POPUP') == '' end)
    child.visible = true
    wait(function() return box('POPUP',220,120,30,30) end)
    refused(function() child.attachment={} end, 'attachment applies to a screen box')
    refused(function() popup.x=0 end, 'attachment cannot be combined with x')
    refused(function() popup.position='top' end, 'position cannot be combined with attachment')
    refused(function() popup.attachment={fit=true} end, 'fit')
    refused(function() popup.attachment={anchor='middle'} end, 'middle')
    refused(function() popup.attachment={anchor={bad=true}} end, 'bad')
    refused(function() popup.attachment={offset={bad=1}} end, 'bad')
    local fake = screen.fake_add(g.x+g.width,g.y,100,100)
    local remote = ui.box {parent=fake,width=10,height=10}
    refused(function() popup.attachment={to=remote} end, 'target is on another screen')
    remote:detach()
    fake:fake_remove()
    popup.attachment = {to=target,anchor='bottom_left'}
    target:detach()
    wait(function() return line('POPUP') == '' end)
    assert(popup.attachment.to == target)
    popup.attachment = nil
    assert(popup.attachment == nil)
    wait(function() return box('ui.box',0,0,30,30) end)
    popup.width, popup.height, popup.text = nil, nil, 'fit popup'
    popup.attachment = {anchor='center'}
    wait(function() return line('POPUP'):find(('box %d,%d'):format(g.width/2,g.height/2),1,true) end)
    assert(popup.width == 'fit' and popup.height == 'fit' and changed > 0)
    popup:detach()
    runner.done()
end)
