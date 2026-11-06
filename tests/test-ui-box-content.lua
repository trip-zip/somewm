local runner = require('_runner')
local async = require('_async')
local ui = require('ui')
local awful = require('awful')
local wibox = require('wibox')
local beautiful = require('beautiful')
local cairo = require('lgi').cairo
local surface = require('gears.surface')
local capture = require('_widget_capture')
local utils = require('_utils')
local s = screen[1]

local function dump() return awesome._clay_tree(s) end
local function wait(fn)
    assert(async.wait_for_condition(fn, 4, .02), 'timed out\n' .. dump())
end
local function line(text)
    return capture.dump_line(s, text) or ''
end
local function pixel(x, y, r, g, b)
    local pr, pg, pb = capture.read(surface(s.content), x, y)
    return math.abs(pr-r) <= 1 and math.abs(pg-g) <= 1 and math.abs(pb-b) <= 1
end
local function scan(x, y, width, height, check)
    local cap = capture.new(s, x, y, width, height)
    local shot = cap:shot()
    for yy = 0, height-1 do
        for xx = 0, width-1 do
            if check(cap:pixel(shot, xx, yy)) then return true end
        end
    end
    return false
end
local function refused(fn, message)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end

runner.run_async(function()
    local wall = awful.wallpaper {screen=s, bg='#000000'}
    mouse.coords {x=900, y=600}
    root.fake_input('motion_notify', true, 0, 0)
    async.sleep(.05)
    local escaped = {}
    local signals = {'button::press', 'button::release', 'mouse::enter', 'mouse::leave', 'mouse::move',
        'property::animation', 'property::surface', 'property::geometry', 'property::x', 'property::y',
        'property::width', 'property::height', 'property::visible', 'property::screen', 'clay::solved'}
    local handlers = {}
    for _, class in ipairs {drawin, drawable} do
        for _, signal in ipairs(signals) do
            local function handler() escaped[#escaped+1] = signal end
            class.connect_signal(signal, handler)
            handlers[#handlers+1] = {class, signal, handler}
        end
    end
    local b = ui.box {parent=s, x=20, y=20, width=200, height=40, bg='#000000',
        fg='#ff0000', font='Sans 20', text='hello', label='content_text'}
    assert(b.text == 'hello' and b.font == 'Sans 20' and b.fg == '#ff0000ff')
    assert(b.wrap == 'words' and b.ellipsize and b.opacity == 1)
    wait(function() return line('"hello"') ~= '' and scan(20,20,200,40,
        function(r,g,bl) return r == 255 and g == 0 and bl == 0 end) end)
    local d = dump()
    assert(d:find('content_text',1,true) < d:find('"hello"',1,true))
    b.text = 'a much longer string that cannot fit in two hundred pixels'
    wait(function() return line('"a much longer'):find('ellipsize=true',1,true) end)
    for _, wrap in ipairs {'newlines','none'} do
        b.wrap = wrap
        wait(function() return line('"a much longer'):find('wrap='..wrap,1,true) end)
    end
    b.ellipsize = false
    wait(function() return line('"a much longer'):find('ellipsize=false',1,true) end)
    local extra = ui.box {width=1,height=1}
    refused(function() b:append(extra) end, 'a box with text cannot have children')
    refused(function() ui.box {parent=b, width=1} end, 'a box with text cannot have children')
    refused(function() ui.box {text='x', extra} end, 'a box with text cannot have children')
    extra:detach()
    for _, word in ipairs {'line_height','image_color','shape','shadow','rotation','mirror'} do
        refused(function() b[word] = 1 end, 'step 4')
        refused(function() ui.box {[word]=1} end, 'step 4')
    end
    b.width, b.x = 210, 30
    wait(function() return line('content_text'):find('210x40',1,true) end)
    b.visible = false
    wait(function() return not dump():find('content_text',1,true) end)
    b.visible = true
    wait(function() return dump():find('content_text',1,true) end)
    b:detach()

    local child = ui.box {width=200,height=40,text='inherited',label='inherited_text'}
    local parent = ui.box {parent=s,x=20,y=20,width=220,height=60,bg='#000000',
        fg='#00ff00',font='Sans 20',child}
    assert(child.fg == nil and child.font == nil)
    refused(function() parent.text = 'no children' end, 'cannot have children')
    wait(function() return scan(20,20,200,40,function(r,g,bl) return r==0 and g==255 and bl==0 end) end)
    local old_font = line('"inherited"'):match('font=(%d+)')
    child.fg, child.font = '#ff0000', 'Sans 12'
    assert(child.fg == '#ff0000ff' and child.font == 'Sans 12')
    wait(function() return line('"inherited"'):match('font=(%d+)') ~= old_font
        and scan(20,20,200,40,function(r,g,bl) return r==255 and g==0 and bl==0 end) end)
    child.fg, child.font = nil, nil
    wait(function() return line('"inherited"'):match('font=(%d+)') == old_font
        and scan(20,20,200,40,function(r,g,bl) return r==0 and g==255 and bl==0 end) end)
    parent:detach()
    local saved_fg, saved_font = beautiful.fg_normal, beautiful.font
    beautiful.fg_normal, beautiful.font = '#0000ff', 'Sans 20'
    b = ui.box {parent=s,x=20,y=20,width=200,height=40,text='theme'}
    beautiful.fg_normal, beautiful.font = saved_fg, saved_font
    assert(b.fg == nil and b.font == nil)
    wait(function() return scan(20,20,200,40,function(r,g,bl) return r==0 and g==0 and bl==255 end) end)
    b:detach()

    local image = cairo.ImageSurface(cairo.Format.ARGB32,2,2)
    local cr = cairo.Context(image)
    cr:set_source_rgb(0,0,1)
    cr:paint()
    b = ui.box {parent=s,x=20,y=20,width=40,height=40,image=image,label='content_image'}
    assert(b.image == image)
    wait(function() return line(' image 2x2') ~= '' and pixel(40,40,0,0,255) end)
    refused(function() b.text = 'both' end, 'text and image')
    local png = os.tmpname() .. '.png'
    image:write_to_png(png)
    b.image = png
    assert(cairo.Surface:is_type_of(b.image))
    wait(function() return pixel(40,40,0,0,255) end)
    b.image = '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="2"><rect width="4" height="2" fill="blue"/></svg>'
    wait(function() return line(' image 4x2') ~= '' and pixel(40,40,0,0,255)
        and pixel(40,22,0,0,0) end)
    b.image = nil
    assert(b.image == nil)
    b.text = 'replaced'
    wait(function() return line('"replaced"') ~= '' end)
    b:detach()
    os.remove(png)

    b = ui.box {parent=s,x=20,y=20,width=80,height=60,bg='#ff0000',opacity=.5}
    wait(function() return pixel(30,30,128,0,0) end)
    b:detach()
    child = ui.box {width=80,height=60,bg='#ff0000',opacity=.5,text='x',fg='#ffffff',font='Sans 30'}
    parent = ui.box {parent=s,x=20,y=20,width=80,height=60,bg='#000000',child}
    wait(function() return pixel(90,70,128,0,0) and scan(20,20,80,60,
        function(r,g,bl) return math.abs(r-191)<=2 and math.abs(g-128)<=2 and math.abs(bl-128)<=2 end) end)
    assert(not scan(20,20,80,60,function(r,g,bl) return r==255 and g==255 and bl==255 end))
    parent:detach()

    child = ui.box {width=40,height=40,bg='#ff0000'}
    parent = ui.box {parent=s,x=100,y=100,width=80,height=80,padding=10,bg='#000000',child}
    local events = {}
    for _, box in ipairs {child,parent} do
        for _, signal in ipairs {'mouse::enter','mouse::leave','mouse::move','button::press','button::release'} do
            box:connect_signal(signal,function(_,x,y,button,mods)
                events[#events+1] = {box,signal,x,y,button,mods}
            end)
        end
    end
    wait(function() return pixel(120,120,255,0,0) end)
    local function move(x,y)
        mouse.coords {x=x,y=y}
        root.fake_input('motion_notify',true,0,0)
        async.sleep(.05)
    end
    local function matches(signal)
        local list = {}
        for _, e in ipairs(events) do if e[2] == signal then list[#list+1] = e end end
        return list
    end
    move(115,115)
    for _, signal in ipairs {'mouse::enter','mouse::move'} do
        local e = matches(signal)
        assert(#e >= 2 and e[1][1] == child and e[2][1] == parent,signal..' order')
        assert(e[1][3] == 5 and e[1][4] == 5 and e[2][3] == 15 and e[2][4] == 15,signal..' coords')
    end
    root.fake_input('button_press',1)
    root.fake_input('button_release',1)
    for _, signal in ipairs {'button::press','button::release'} do
        local e = matches(signal)
        assert(#e == 2 and e[1][1] == child and e[2][1] == parent,signal..' order')
        assert(e[1][3] == 5 and e[1][4] == 5 and e[2][3] == 15 and e[2][4] == 15,signal..' coords')
        assert(e[1][5] == 1 and type(e[1][6]) == 'table')
    end
    root.fake_input('button_press',4)
    local presses = matches('button::press')
    assert(#presses == 4 and presses[3][5] == 4 and presses[4][5] == 4)
    move(900,600)
    local leaves = matches('mouse::leave')
    assert(#leaves == 2 and leaves[1][1] == child and leaves[2][1] == parent)
    refused(function() child.layer = 'top' end, 'layer applies to a screen box')
    refused(function() ui.box {parent=parent,layer='top'} end, 'layer applies to a screen box')
    parent:detach()
    async.sleep(.1)
    for _, h in ipairs(handlers) do h[1].disconnect_signal(h[2],h[3]) end
    assert(#escaped == 0,'internal host signals: '..table.concat(escaped,', '))

    local geometry = s.geometry
    s:fake_resize(geometry.x,geometry.y,geometry.width / 2,geometry.height)
    local fake = screen.fake_add(geometry.x + geometry.width / 2,geometry.y,
        geometry.width / 2,geometry.height)
    b = ui.box {parent=fake,x=10,y=10,
        width=40,height=40,bg='#00ff00',label='screen_box'}
    local function fake_line() return capture.dump_line(fake, 'screen_box') or '' end
    local function fake_box(x)
        local l = fake_line()
        return l:find('offset '..x..',10',1,true)
            and l:find('box '..(fake.geometry.x-geometry.x+x)..',10 40x40',1,true)
    end
    wait(function()
        local r, g, bl = capture.read(surface(root.content()),fake.geometry.x+20,fake.geometry.y+20)
        return fake_box(10) and r == 0 and g == 255 and bl == 0
    end)
    assert(b.x == 10 and b.y == 10)
    local screen_signals = 0
    local function exposed_screen() screen_signals = screen_signals + 1 end
    drawin.connect_signal('property::screen',exposed_screen)
    b.x = -fake.geometry.width
    wait(function() return fake_box(b.x) end)
    assert(b.parent == fake.tree)
    b.x = 10
    wait(function() return fake_box(10) end)
    fake:fake_remove()
    s:fake_resize(geometry.x,geometry.y,geometry.width,geometry.height)
    wait(function() return line('screen_box'):find('box 10,10 40x40',1,true)
        and b.parent == s.tree and pixel(20,20,0,255,0) end)
    assert(b.x == 10 and b.y == 10)
    local found = false
    for _, n in ipairs(s.tree.children) do if n == b then found = true end end
    assert(found and screen_signals == 0,'box screen reassignment exposed its host')
    drawin.disconnect_signal('property::screen',exposed_screen)
    b:detach()

    local bar = wibox {screen=s,x=100,y=100,width=100,height=100,bg='#00ff00',visible=true}
    b = ui.box {parent=s,x=100,y=100,width=100,height=100,bg='#ff0000',label='layer_box'}
    local face
    for _, n in ipairs(s.tree.children) do if n.object == bar.drawin then face = n end end
    assert(face and b.layer == face.layer)
    for _, layer in ipairs {'background','bottom','below','normal','above','fullscreen','ontop','top','overlay'} do
        b.layer = layer
        assert(b.layer == layer)
    end
    bar.widget = wibox.widget {text='ontop_wibox',widget=wibox.widget.textbox}
    bar.ontop = true
    b.layer = 'top'
    wait(function() return pixel(150,150,255,0,0) end)
    local top = dump()
    assert(top:find('ontop_wibox',1,true) < top:find('layer_box',1,true),top)
    bar.visible = false
    local binary = utils.binary_or_skip('./build-test/test-transient-client')
    assert(binary)
    local report = os.tmpname()
    awful.spawn {binary,'--subsurfaces','ui_layer_client',report,'0','ff0000ff','0'}
    local c = assert(async.wait_for_client('ui_layer_client',3))
    c.floating, c.border_width, c.shadow, c.animation = true,0,false,false
    c:geometry {x=100,y=100,width=200,height=200}
    b.layer = 'below'
    wait(function() return pixel(150,150,0,0,255) end)
    local below = dump()
    assert(below:find('layer_box',1,true) < below:find('CLIENT',1,true),below)
    b.layer = 'ontop'
    wait(function() return pixel(150,150,255,0,0) end)
    local above = dump()
    assert(above:find('CLIENT',1,true) < above:find('layer_box',1,true),above)
    c:kill()
    b:detach()
    os.remove(report)
    wall:detach()
    runner.done()
end)
