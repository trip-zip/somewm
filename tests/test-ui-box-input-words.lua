local runner = require('_runner')
local async = require('_async')
local ui = require('ui')
local awful = require('awful')
local capture = require('_widget_capture')
local s = screen[1]
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

local function dump() return awesome._clay_tree(s) end
local function wait(fn)
    assert(async.wait_for_condition(fn, 3, .02), 'timed out\n' .. dump())
end
local function cursor_record()
    for text in dump():gmatch('[^\n]+') do
        local name = text:match('^  cursor (%S+) w=fixed')
        if name then return name end
    end
end
local function move(x,y)
    mouse.coords {x=x,y=y}
    mouse._fake_motion(1,0)
    mouse._fake_motion(-1,0)
    async.sleep(.05)
end
local function click(x,y)
    local g = s.geometry
    awful.spawn({pointer,'click',tostring(x),tostring(y),tostring(g.width),tostring(g.height),'right'}, false)
    async.sleep(.4)
end
local function refused(fn, word)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(word,1,true),tostring(err))
end

runner.run_async(function()
    local original_buttons = root.buttons()
    move(900,600)
    local original = cursor_record()
    assert(original)
    local parent = ui.box {parent=s,x=100,y=100,width=100,height=100,
        bg='#ff0000',input_passthrough=true,cursor='crosshair',label='input_parent'}
    local enters, presses, root_presses = 0, 0, 0
    parent:connect_signal('mouse::enter',function() enters=enters+1 end)
    parent:connect_signal('button::press',function() presses=presses+1 end)
    awful.mouse.append_global_mousebindings {
        awful.button({},3,function() root_presses=root_presses+1 end),
    }
    wait(function() return capture.dump_line(s,'input_parent') end)
    click(120,120)
    assert(root_presses == 1 and presses == 0 and enters == 0)
    assert(parent.input_passthrough and parent.cursor == 'crosshair')
    local signals = {input_passthrough=0,cursor=0}
    for word in pairs(signals) do parent:connect_signal('property::'..word,
        function() signals[word] = signals[word]+1 end) end
    parent.input_passthrough = false
    parent.input_passthrough = false
    move(900,600)
    click(120,120)
    assert(root_presses == 1 and presses == 1 and enters == 1)
    wait(function() return cursor_record() == 'crosshair' end)
    move(900,600)
    wait(function() return cursor_record() == original end)
    assert(signals.input_passthrough == 1)
    refused(function() parent.cursor=3 end, 'cursor')
    refused(function() ui.box {cursor=3} end, 'cursor')
    refused(function() parent.input_passthrough='yes' end, 'input_passthrough')
    parent.padding = 10
    local child = ui.box {parent=parent,width=60,height=60,padding=10,
        input_passthrough=true,bg='#00ff00',label='input_child'}
    local grandchild = ui.box {parent=child,width=30,height=30,bg='#0000ff',label='input_grandchild'}
    local events = {}
    for _, box in ipairs {parent,child,grandchild} do
        for _, signal in ipairs {'mouse::enter','mouse::leave','mouse::move','button::press','button::release'} do
            box:connect_signal(signal,function() events[#events+1] = {box,signal} end)
        end
    end
    wait(function() return capture.dump_line(s,'input_grandchild') end)
    move(125,125)
    root.fake_input('button_press',1)
    root.fake_input('button_release',1)
    move(900,600)
    for _, signal in ipairs {'mouse::enter','mouse::leave','mouse::move','button::press','button::release'} do
        local found = {}
        for _, event in ipairs(events) do if event[2] == signal then found[event[1]]=true end end
        assert(found[parent] and found[grandchild] and not found[child], signal)
    end
    child.input_passthrough = false
    events = {}
    move(125,125)
    root.fake_input('button_press',1)
    root.fake_input('button_release',1)
    for _, signal in ipairs {'button::press','button::release'} do
        local list = {}
        for _, event in ipairs(events) do if event[2] == signal then list[#list+1]=event[1] end end
        assert(#list == 3 and list[1] == grandchild and list[2] == child and list[3] == parent, signal)
    end
    child.cursor = 'pointer'
    move(125,125)
    wait(function() return cursor_record() == 'pointer' end)
    move(105,105)
    wait(function() return cursor_record() == 'crosshair' end)
    child.cursor = nil
    assert(child.cursor == nil)
    move(125,125)
    wait(function() return cursor_record() == 'crosshair' end)
    move(105,105)
    wait(function() return cursor_record() == 'crosshair' end)
    parent.cursor = nil
    assert(parent.cursor == nil and signals.cursor == 1)
    move(125,125)
    wait(function() return cursor_record() == original end)
    parent.input_passthrough = true
    events = {}
    move(900,600)
    click(125,125)
    assert(root_presses == 2 and #events == 0)
    parent.input_passthrough = nil
    assert(not parent.input_passthrough)
    parent.cursor = 'crosshair'
    parent:detach()
    root.buttons = original_buttons
    runner.done()
end)
