-- timeout: 70
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local ui = require('ui')
local animation = require('somewm.animation')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local s = screen[1]
local seconds = 3
local function dump() return awesome._clay_tree(s) end

local function shot()
    local content, width, header, data = surface(s.content)
    if utils.is_headless() then
        local path, done = os.tmpname(), false
        awful.spawn.easy_async({'grim', '-t', 'ppm', path}, function(_, stderr, _, code)
            assert(code == 0, stderr)
            local file = assert(io.open(path, 'rb'))
            data = file:read('*a')
            file:close()
            os.remove(path)
            done = true
        end)
        assert(async.wait_for_condition(function() return done end, 2, .01), 'grim timed out')
        width, header = data:match('^P6%s+(%d+)%s+%d+%s+255%s()')
        assert(width, 'grim did not produce P6')
    end
    return function(x, y)
        local red, green, blue = capture.read(content, x, y)
        local values = {red, green, blue}
        if data then
            local offset = header + (y * tonumber(width) + x) * 3
            for channel = 0, 2 do values[#values + 1] = data:byte(offset + channel) end
        end
        return values
    end
end

local function box(label)
    for line in dump():gmatch('[^\n]+') do
        if line:find(label, 1, true) then
            local x,y,w,h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            if x then return {x=tonumber(x),y=tonumber(y),w=tonumber(w),h=tonumber(h)} end
        end
    end
end
local function wait(check, timeout)
    assert(async.wait_for_condition(check, timeout or 1, .02), 'timed out\n' .. dump())
end
local function exact(x,y,value)
    wait(function()
        for _, channel in ipairs(shot()(x,y)) do if channel ~= value then return false end end
        return true
    end)
end
local function between(x,y)
    for _, channel in ipairs(shot()(x,y)) do
        assert(channel > 32 and channel < 224, 'pixel did not interpolate: '..channel..'\n'..dump())
    end
end
local function refused(fn, word)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(word,1,true), tostring(err))
end
local function settle() async.sleep(seconds + .15) end

runner.run_async(function()
    local wall = awful.wallpaper {screen=s,bg='#202020'}
    mouse.coords {x=1100,y=650}
    local b = ui.box {parent=s,x=40,y=40,width=80,height=40,bg='#202020',label='animated_box',
        animation={width=seconds}}
    wait(function() return box('animated_box') end)
    assert(box('animated_box').w == 80, 'first frame animated from empty\n'..dump())
    local changes = 0
    b:connect_signal('property::animation',function() changes=changes+1 end)
    local policy = {bg=seconds,visible={duration=seconds,enter='fade'}}
    b:set_animation(policy)
    local copy = b:get_animation()
    assert(copy ~= policy and copy.visible ~= policy.visible and copy.bg == seconds
        and copy.visible.enter == 'fade')
    policy.bg = 1
    copy.visible.duration = 1
    assert(b.animation.bg == seconds and b.animation.visible.duration == seconds)
    b.animation = copy
    assert(b.animation.visible.duration == 1)
    b.animation = false
    assert(b.animation == false)
    b.animation = nil
    assert(b.animation == nil and changes == 4)
    b.animation = {bg=seconds,width=seconds,x=seconds}
    async.sleep(.15)
    b.bg,b.width,b.height,b.x,b.y = '#e0e0e0',160,60,140,50
    async.sleep(.3*seconds)
    local mid = assert(box('animated_box'))
    assert(mid.w > 80 and mid.w < 160 and mid.x > 40 and mid.x < 140 and mid.y == 50 and mid.h == 60,
        'geometry did not interpolate or height did not snap\n'..dump())
    between(mid.x+10,60)
    settle()
    assert(box('animated_box').w == 160 and box('animated_box').x == 140)
    exact(150,60,224)
    b.animation = {width=seconds}
    b.width,b.height = 200,80
    async.sleep(.1)
    assert(box('animated_box').h == 80, 'unnamed height did not snap\n'..dump())
    b.animation = false
    b.width = 160
    async.sleep(.1)
    b:detach()

    local child = ui.box {width=100,height=60,bg='#202020',animation={bg=seconds},label='animated_child'}
    local parent = ui.box {parent=s,x=40,y=40,width=100,height=60,child}
    wait(function() return box('animated_child') end)
    exact(50,50,32)
    child.bg = '#e0e0e0'
    async.sleep(.3*seconds)
    between(50,50)
    parent.animation = false
    child.bg = '#202020'
    exact(50,50,32)
    parent.animation = nil
    child.bg = '#e0e0e0'
    async.sleep(.3*seconds)
    between(50,50)
    settle()
    child.animation = nil
    child:animate {bg='#202020',duration=seconds}
    async.sleep(.3*seconds)
    between(50,50)
    settle()
    child.bg = '#e0e0e0'
    exact(50,50,224)
    child:animate {bg='#e0e0e0',duration=seconds}
    async.sleep(.15)
    child.bg = '#202020'
    exact(50,50,32)
    child.animation = false
    child:animate {bg='#e0e0e0',duration=seconds}
    exact(50,50,224)
    assert(child.animation == false and type(child.animate) == 'function')
    child.animation = {bg=seconds}
    animation.enabled = false
    child.bg = '#202020'
    exact(50,50,32)
    animation.enabled = true
    refused(function() child.animation = {visible={enter='fade'}} end,'step 4')
    refused(function() ui.box {parent=parent,animation={visible={enter='grow'}}} end,'step 4')
    refused(function() child.animation = {radius=1} end,'radius')
    refused(function() child.animation = 'fast' end,'animation')
    refused(function() child:animate {bg='#fff'} end,'duration')
    refused(function() child:animate {unknown=1,duration=1} end,'unknown')
    parent:detach()

    b = ui.box {parent=s,x=400,y=200,width=200,height=100,bg='#e0e0e0',visible=false,
        label='visible_box',animation={visible={duration=seconds,enter='grow',exit='grow'}}}
    async.sleep(.1)
    b.visible = true
    async.sleep(.3*seconds)
    mid = assert(box('visible_box'),dump())
    assert(mid.w > 0 and mid.w < 200 and mid.h > 0 and mid.h < 100,
        'screen box did not grow in\n'..dump())
    settle()
    assert(box('visible_box').w == 200)
    b.visible = false
    async.sleep(.3*seconds)
    local departing = box('box 400,200 ')
    assert(departing and departing.w > 0 and departing.w < 200,
        'screen box exit missing or not shrinking\n'..dump())
    settle()
    assert(not box('box 400,200 '), 'screen box exit retained after duration\n'..dump())
    b.animation = {visible={duration=seconds,enter='fade'}}
    b.visible = true
    async.sleep(.3*seconds)
    between(420,220)
    settle()
    exact(420,220,224)
    b:detach()
    wall:detach()
    runner.done()
end)
