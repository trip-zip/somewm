local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local shape = require('gears.shape')
local color = require('gears.color')
local wibox = require('wibox')
local shot = require('_shape_mask_capture')
local wallpaper, ink, border = '#123456', '#204060', '#ffff00'
local c, report, below
local enters, leaves, clicks = 0, 0, 0
local function octogon(cr, w, h) shape.octogon(cr, w, h, 24 * math.sqrt(2)) end
local function points()
    local x,y,w,h
    for line in awesome._clay_tree(screen[1]):gmatch('[^\n]+') do
        if line:find('CLIENT path_client ',1,true) then
            x,y,w,h=line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            x,y,w,h=tonumber(x),tonumber(y),tonumber(w),tonumber(h)
        end
    end
    assert(x,'client frame missing')
    local bw=c.border_width
    local p = {{x,y,wallpaper}, {x+w-1,y,wallpaper},
        {x,y+h-1,wallpaper}, {x+w-1,y+h-1,wallpaper}, {x+w/2,y+h/2,ink}}
    if bw > 0 then p[#p+1] = {x+13,y+13,border} end
    return p
end
local function click(x,y)
    local width,height = root.size()
    awful.spawn{'./build-test/test-virtual-pointer-client','click',tostring(x),tostring(y),
        tostring(width),tostring(height)}
end
local steps = {
    function()
        screen[1].scale = 1
        root.wallpaper(color(wallpaper))
        screen[1].selected_tag.layout = awful.layout.suit.floating
        report = os.tmpname()
        awful.spawn{'./build-test/test-transient-client','path_client',report,'0','ff204060'}
        return true
    end,
    function(n)
        c = utils.find_client_by_class('path_client')
        if not c then assert(n < 30, 'client did not map'); return end
        c.floating, c.shadow, c.border_width = true, false, 0
        c:geometry{x=100,y=100,width=160,height=120}
        c.shape = octogon
        mouse.coords{x=600,y=300}
        return true
    end,
}
shot.check_steps(steps, points)
steps[#steps+1] = function()
    local f = assert(io.open(os.getenv('SOMEWM_TEST_LOG')))
    local text = f:read('*a'); f:close()
    assert(not text:find('client stays square',1,true))
    c.border_width, c.border_color = 4, border
    return true
end
shot.check_steps(steps, points)
steps[#steps+1] = function()
    client.focus=c
    c.animation={focus=1}
    return true
end
steps[#steps+1] = function(n)
    if n < 3 then return end
    client.focus=nil
    c.border_color='#0000ff'
    return true
end
steps[#steps+1] = shot.wait(function()
    local p=points()[6]
    local value=shot.pixel(p[1],p[2])
    assert(value ~= border and value ~= '#0000ff' and value ~= wallpaper and value ~= ink,
        'path border did not interpolate: '..value)
end)
steps[#steps+1] = shot.wait(function()
    local p=points()[6]
    assert(shot.pixel(p[1],p[2]) == '#0000ff','path border did not settle')
end)
steps[#steps+1] = function()
    c.animation=false
    c.border_color=border
    c.border_width = 0
    awful.titlebar(c,{size=24,bg_normal=border,bg_focus=border})
    return true
end
shot.check_steps(steps, function()
    local g=c:geometry()
    return {{g.x,g.y,wallpaper},{g.x+g.width-1,g.y,wallpaper},{g.x+g.width/2,g.y+2,border}}
end)
steps[#steps+1] = function()
    awful.titlebar.hide(c,'top')
    below = wibox{x=90,y=90,width=190,height=160,visible=true,ontop=false,type="desktop",bg=wallpaper,shadow=false}
    below:buttons{awful.button({},1,function() clicks=clicks+1 end)}
    c:raise()
    c:connect_signal('mouse::enter',function() enters=enters+1 end)
    c:connect_signal('mouse::leave',function() leaves=leaves+1 end)
    mouse.coords{x=100,y=100}; mouse._fake_motion(0,0)
    click(100,100)
    return true
end
steps[#steps+1] = function(n)
    if n < 5 then return end
    assert(enters == 0, 'cut corner entered client')
    assert(clicks == 1, 'corner click did not reach wibox below')
    mouse.coords{x=180,y=160}; mouse._fake_motion(0,0)
    return true
end
steps[#steps+1] = shot.wait(function() assert(enters == 1, 'center did not enter client') end)
steps[#steps+1] = function()
    mouse.coords{x=600,y=300}; mouse._fake_motion(0,0)
    below.visible=false
    c.shape=function(cr,w,h) shape.partially_rounded_rect(cr,w,h,true,true,false,false,24) end
    return true
end
shot.check_steps(steps,function()
    local g=c:geometry()
    return {{g.x,g.y,wallpaper},{g.x+g.width-1,g.y,wallpaper},
        {g.x,g.y+g.height-1,ink},{g.x+g.width-1,g.y+g.height-1,ink}}
end)
steps[#steps+1] = function() c.shape=nil; return true end
shot.check_steps(steps,function()
    local g=c:geometry()
    return {{g.x,g.y,ink},{g.x+g.width-1,g.y,ink},
        {g.x,g.y+g.height-1,ink},{g.x+g.width-1,g.y+g.height-1,ink}}
end)
steps[#steps+1] = function() c.shape=octogon; c.fullscreen=true; return true end
shot.check_steps(steps,function()
    local g=screen[1].geometry
    return {{0,0,ink},{g.width-1,0,ink},{0,g.height-1,ink},{g.width-1,g.height-1,ink}}
end)
steps[#steps+1] = function() c.fullscreen=false; return true end
shot.check_steps(steps,points)
for _, scale in ipairs{2,1.5} do
    steps[#steps+1] = function() screen[1].scale=scale; c.border_width=0; return true end
    shot.check_steps(steps,points)
    steps[#steps+1] = function() c.border_width=4; return true end
    shot.check_steps(steps,points)
end
steps[#steps+1] = function()
    assert(leaves >= 1, 'pointer never left client')
    screen[1].scale=1; c:kill(); os.remove(report); return true
end
runner.run_steps(steps,{kill_clients=false})
