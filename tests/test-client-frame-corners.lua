-- The outer frame keeps its shape while the surface changes its own corners.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local shot = require('_shape_mask_capture')
local color = require('gears.color')
local shape = require('gears.shape')
local c, report
local wallpaper, frame, ink, bar_color = '#123456', '#ff00ff', '#204060', '#33aa55'
local enters, leaves = 0, 0
local steps = {}
local function rounded(cr, w, h)
    local r = math.min(24, w / 2, h / 2)
    local k = r * 0.5522847498
    cr:move_to(r, 0); cr:line_to(w-r, 0)
    cr:curve_to(w-r+k, 0, w, r-k, w, r)
    cr:line_to(w,h-r); cr:curve_to(w,h-r+k,w-r+k,h,w-r,h)
    cr:line_to(r,h); cr:curve_to(r-k,h,0,h-r+k,0,h-r)
    cr:line_to(0,r); cr:curve_to(0,r-k,r-k,0,r,0); cr:close_path()
end
steps[#steps+1] = function()
    screen[1].selected_tag.layout = awful.layout.suit.floating
    root.wallpaper(color(wallpaper))
    mouse.coords{x=0,y=0}
    report = os.tmpname()
    awful.spawn{'./build-test/test-transient-client','frame_corners',report,'0','ff204060'}
    return true
end
steps[#steps+1] = function(n)
    c = utils.find_client_by_class('frame_corners')
    if not c then assert(n < 30, 'client did not map'); return end
    c.floating, c.shadow, c.animation = true, false, false
    c.border_color = frame
    awful.titlebar(c, {size=32,bg_normal=bar_color,bg_focus=bar_color})
    c:geometry{x=100,y=100,width=300,height=220}
    c:connect_signal('mouse::enter', function() enters = enters + 1 end)
    c:connect_signal('mouse::leave', function() leaves = leaves + 1 end)
    return true
end
local function check(label, setup, inner, path)
    steps[#steps+1] = function() setup(); return true end
    shot.check_steps(steps, function()
        local dump = awesome._clay_tree(screen[1])
        local outer = assert(dump:match('\n( *CLIENT frame_corners [^\n]*)'))
        local surface = assert(dump:match('\n( *SURFACE frame_corners [^\n]*)'))
        if path then assert(outer:find(' shape ',1,true), outer)
        else assert(outer:find(' clip ',1,true), outer) end
        local x,y = surface:match(' box (%S+),(%S+) ')
        x,y = tonumber(x),tonumber(y)
        io.stderr:write(label .. ': ' .. outer .. '\n' .. surface .. '\n')
        local g,bw = c:geometry(),c.border_width
        return {{g.x+2,g.y+2,wallpaper}, {g.x+100,g.y+bw+2,bar_color},
            {x+2,y+2,inner}, {x+26,y+26,ink},
            {g.x+100,g.y+1,bw>0 and frame or bar_color}}
    end)
end
for _, scale in ipairs{1,1.5} do
    for _, bw in ipairs{0,4} do
        check('default corners', function()
            screen[1].scale = scale
            c.shape,c.border_width,c.content_radius = 24,bw,nil
        end, ink)
        check('inner rounding', function() c.content_radius = 24 end, frame)
        check('reset to zero', function() c.content_radius = 0 end, ink)
        check('explicit square', function() c.content_radius = {} end, ink)
        check('selected corners', function() c.content_radius = {top_left=24,top_right=24} end, frame)
        check('rounded function', function()
            c.shape = function(cr,w,h) shape.rounded_rect(cr,w,h,24) end
        end, frame)
        check('custom path', function() c.shape = rounded end, frame, true)
        check('custom path zero', function() c.content_radius = 0 end, ink, true)
    end
end
local signals = 0
check('explicit fill', function()
    screen[1].scale = 1
    c.shape,c.content_radius,c.border_width = 24,24,4
    assert(c.content_background_color == nil)
    c:connect_signal('property::content_background_color', function() signals = signals + 1 end)
    c.content_background_color = bar_color
    assert(c.content_background_color == bar_color and signals == 1)
    c.content_background_color = bar_color
    assert(signals == 1, 'same fill emitted a signal')
    for _, bad in ipairs{false, 12, {}, 'not-a-color', 'linear:0,0:100,0:0,#ff0000:1,#0000ff'} do
        assert(not pcall(awful.client.object.set_content_background_color, c, bad), 'invalid fill accepted')
        assert(c.content_background_color == bar_color and signals == 1, 'invalid fill changed property')
    end
end, bar_color)
check('independent border color', function()
    frame = '#ffaa00'
    c.border_color = frame
end, bar_color)
check('transparent fill', function() c.content_background_color = '#00000000' end, wallpaper)
check('restore border fill', function()
    c.content_background_color = nil
    assert(c.content_background_color == nil and signals == 3)
end, '#ffaa00')
steps[#steps+1] = function()
    screen[1].scale = 1
    c.shape,c.content_radius,c.border_width = 24,24,4
    mouse.coords{x=102,y=102}; mouse._fake_motion(0,0)
    return true
end
steps[#steps+1] = shot.wait(function()
    assert(enters == 0, 'outer cut captured the pointer')
end)
steps[#steps+1] = function()
    local g = c:geometry()
    mouse.coords{x=g.x+6,y=g.y+38}; mouse._fake_motion(0,0)
    return true
end
steps[#steps+1] = shot.wait(function()
    assert(enters == 1 and leaves == 0, 'inner cut did not belong to the client')
end)
steps[#steps+1] = function()
    mouse.coords{x=102,y=102}; mouse._fake_motion(0,0)
    return true
end
steps[#steps+1] = shot.wait(function() assert(leaves == 1, 'outer cut did not leave client') end)
steps[#steps+1] = function() c:kill(); os.remove(report); return true end
runner.run_steps(steps, {kill_clients=false})
