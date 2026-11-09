-- Rounded titlebars keep their controls inside the mask and publish the inset for input.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local utils = require('_utils')
local shot = require('_shape_mask_capture')
local color = require('gears.color')
local shape = require('gears.shape')
local c, bar, red, blue, report
local steps = {}
local function configure(padding, bg)
    bg = bg or '#33aa55'
    bar = awful.titlebar(c,{size=32,bg_normal=bg,bg_focus=bg,corner_padding=padding})
end
steps[#steps+1] = function()
    root.wallpaper(color('#123456'))
    screen[1].selected_tag.layout = awful.layout.suit.floating
    mouse.coords{x=0,y=0}
    report = os.tmpname()
    awful.spawn{'./build-test/test-transient-client','corner_controls',report,'0','ff204060'}
    return true
end
steps[#steps+1] = function(n)
    c = utils.find_client_by_class('corner_controls')
    if not c then assert(n < 30, 'client did not map'); return end
    c.floating,c.animation,c.shadow = true,false,false
    c.border_width,c.border_color,c.shape = 4,'#ff00ff',24
    for _, bad in ipairs{-1, 65536, math.huge, 0/0, 'yes', {}} do
        assert(not pcall(awful.titlebar, c, {corner_padding=bad}), 'invalid padding accepted')
    end
    configure(true)
    red = wibox.widget {forced_width=20,bg='#ff0000',widget=wibox.container.background}
    blue = wibox.widget {forced_width=20,bg='#0000ff',widget=wibox.container.background}
    bar:setup {red,nil,blue,layout=wibox.layout.align.horizontal}
    c:geometry{x=100,y=100,width=300,height=220}
    return true
end
local function contains(x,y,widget)
    for _,found in ipairs(bar:find_widgets(x,y)) do if found.widget==widget then return true end end
    return false
end
local function check(label, setup, pad)
    steps[#steps+1] = function() setup(); return true end
    shot.check_steps(steps,function()
        local dump = awesome._clay_tree(screen[1])
        local line = assert(dump:match('\n( *TITLEBAR corner_controls [^\n]*)'))
        local x,y,w = line:match(' box (%S+),(%S+) (%S+)x')
        x,y,w = tonumber(x),tonumber(y),tonumber(w)
        assert(contains(pad+2,24,red), label .. ': left control input missed\n' .. dump)
        assert(contains(w-pad-3,24,blue), label .. ': right control input missed')
        if pad > 0 then
            assert(not contains(2,24,red), label .. ': input ignored left inset')
            assert(not contains(w-3,24,blue), label .. ': input ignored right inset')
        end
        return {{x+pad+2,y+24,'#ff0000'}, {x+w-pad-3,y+24,'#0000ff'},
            {x+2,y+24,pad > 0 and '#33aa55' or '#ff0000'},
            {x+pad+2,y+2,pad == 0 and c.shape and '#123456' or '#ff0000'}}
    end)
end
for _, scale in ipairs{1,1.5} do
    check('automatic', function() screen[1].scale=scale; c.shape=24; configure(true) end,20)
    check('inner rounding', function() c.content_radius=24 end,20)
    check('reset inner rounding', function() c.content_radius=0 end,20)
    check('opt out', function() configure(false) end,0)
    check('explicit inset', function() configure(30) end,30)
    check('shape closure', function()
        configure(true)
        c.shape=function(cr,w,h) shape.rounded_rect(cr,w,h,24) end
    end,20)
    check('clear shape', function() c.shape=nil end,0)
end
steps[#steps+1] = function()
    screen[1].scale = 1
    c.shape = 24
    configure(true, 'linear:0,0:300,0:0,#33aa55:1,#33aa55')
    return true
end
shot.check_steps(steps, function()
    local line = assert(awesome._clay_tree(screen[1]):match('\n( *TITLEBAR corner_controls [^\n]*)'))
    local x,y = line:match(' box (%S+),(%S+) ')
    return {{tonumber(x)+2,tonumber(y)+24,'#33aa55'}, {tonumber(x)+22,tonumber(y)+24,'#ff0000'}}
end)
local side
local function side_check(label, setup, pad)
    steps[#steps+1] = function() setup(); return true end
    shot.check_steps(steps, function()
        local dump = awesome._clay_tree(screen[1])
        local line = assert(dump:match('\n( *TITLEBAR_LEFT corner_controls [^\n]*)'))
        local x,y = line:match(' box (%S+),(%S+) ')
        x,y = tonumber(x),tonumber(y)
        local found = false
        for _, item in ipairs(side:find_widgets(24,pad+2)) do found = found or item.widget == red end
        assert(found, label .. ': side control input missed')
        return {{x+24,y+pad+2,'#ff0000'}, {x+24,y+pad+22,'#33aa55'}}
    end)
end
side_check('side below top', function()
    screen[1].scale = 1
    c.shape = 24
    side = awful.titlebar(c,{position='left',size=32,bg_normal='#33aa55',bg_focus='#33aa55'})
    red = wibox.widget{forced_height=20,bg='#ff0000',widget=wibox.container.background}
    side:setup{red,layout=wibox.layout.fixed.vertical}
end,0)
side_check('short top', function()
    awful.titlebar(c,{size=10,bg_normal='#33aa55',bg_focus='#33aa55'})
end,10)
side_check('hidden top', function() awful.titlebar.hide(c,'top') end,20)
steps[#steps+1] = function() c:kill(); os.remove(report); screen[1].scale=1; return true end
runner.run_steps(steps,{kill_clients=false})
