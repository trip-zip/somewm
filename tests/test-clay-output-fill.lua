-- Output fill ownership, capture semantics and repaint stability.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local example = require('_clay_example')
local cairo = require('lgi').cairo
local s = screen[1]
local wall, image, first_screen, first_wall
local function check(name, r, g, b)
    local x,y = s.geometry.x+100,s.geometry.y+100
    for _, im in ipairs{surface(root.content()), surface(root.content(true))} do
        local rr,gg,bb,a = capture.read(im,x,y)
        assert(math.abs(rr-r)<=1 and math.abs(gg-g)<=1 and math.abs(bb-b)<=1 and a==255,
            name..': screenshot inclusion/pixels changed')
    end
    local rr,gg,bb,a = capture.read(surface(s.content),100,100)
    assert(math.abs(rr-r)<=1 and math.abs(gg-g)<=1 and math.abs(bb-b)<=1 and a==255)
    local dump=awesome._clay_tree(s)
    assert(not dump:match('\n%s*BACKGROUND '), dump)
    -- the pointer image is a floating root of the screen under the pointer
    local floating = dump:find('\n  cursor ',1,true) and 1 or 0
    assert(dump:find('roots flow 1 floating '..floating..' derived 0',1,true),dump)
    if name:find('image',1,true) then
        assert(dump:match('OUTPUT [^\n]* column image '),dump)
    end
    mouse.coords{x=x,y=y}
    assert(mouse.object_under_pointer()~=wall._private.wibox.drawin,
        'OUTPUT wallpaper must remain input passthrough')
    local hits=wall._private.wibox:find_widgets(100,100)
    assert(#hits>0,'folded wallpaper lost original widget lookup')
    example.save(name,dump)
    local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
    if dir then
        surface(root.content(true)):write_to_png(dir..'/'..name..'-alpha.png')
        surface(s.content):write_to_png(dir..'/'..name..'-screen.png')
    end
    awesome._test_redeclare()
    assert(awesome._test_redeclare()==0,'unchanged fill mutated the scene')
end
runner.run_steps {
    function(n)
        if n==1 then
            wall=awful.wallpaper{screen=s,bg='#123456'}
            return
        end
        if n<4 then return end
        check('solid-fill',18,52,86)
        return true
    end,
    function()
        wall.bg='#abcdef'
        assert(awesome._test_redeclare()>0,'wallpaper replacement did not repaint')
        check('solid-replaced',171,205,239)
        wall.bg='#12345680'
        assert(awesome._test_redeclare()>0,'translucent wallpaper did not repaint')
        check('solid-translucent',26,43,60)
        return true
    end,
    function(n)
        if n==1 then
            image=cairo.ImageSurface.create(cairo.Format.RGB24,16,16)
            local cr=cairo.Context(image); cr:set_source_rgb(0.8,0.4,0.2); cr:paint()
            local widget=require('wibox.widget.base').make_widget()
            widget._clay={name='wallpaper-image',describe=function()
                return {image=image._native,w='grow',h='grow'}
            end}
            wall=awful.wallpaper{screen=s,bg='#00000000',widget=widget}
            return
        end
        if n<4 then return end
        check('image-fill',204,102,51)
        return true
    end,
    function(n)
        if n==1 then s.scale=1.25; return end
        if n<4 then return end
        check('image-fill-fractional',204,102,51)
        return true
    end,
    function(n)
        if n==1 then
            wall=awful.wallpaper{screen=s,bg='#654321'}
            return
        end
        if n<4 then return end
        check('solid-fill-fractional',101,67,33)
        s.scale=1
        return true
    end,
    function(n)
        if n==1 then
            wall=awful.wallpaper{screen=s,bg='#000000',widget=wibox.widget.imagebox(image)}
            return
        end
        if n<4 then return end
        local dump=awesome._clay_tree(s)
        local floating = dump:find('\n  cursor ',1,true) and 2 or 1
        assert(dump:find('roots flow 1 floating '..floating..' derived 0',1,true),dump)
        example.save('imagebox-fill',dump)
        wall:detach()
        return true
    end,
    function(n)
        if n==1 then
            first_screen=s
            first_screen.output.position={x=0,y=0}
            assert(awesome._test_add_output(640,480))
            return
        end
        if screen.count()~=2 or n<4 then assert(n<30); return end
        for other in screen do if other~=first_screen then s=other end end
        s.output.position={x=first_screen.geometry.width+80,y=120}
        first_wall=awful.wallpaper{screen=first_screen,bg='#123456'}
        wall=awful.wallpaper{screen=s,bg='#654321'}
        return true
    end,
    function(n)
        if n<4 then return end
        awesome._test_redeclare()
        check('solid-second-output',101,67,33)
        example.save('first-output-after-hotplug',awesome._clay_tree(first_screen))
        local rr,gg,bb=capture.read(surface(first_screen.content),100,100)
        assert(rr==18 and gg==52 and bb==86,string.format('first output color %d,%d,%d; wall visible=%s',rr,gg,bb,tostring(first_wall._private.wibox.visible)))
        return true
    end,
    function(n)
        if n==1 then
            local widget=require('wibox.widget.base').make_widget()
            widget._clay={name='wallpaper-image',describe=function()
                return {image=image._native,w='grow',h='grow'}
            end}
            wall=awful.wallpaper{screen=s,bg='#00000000',widget=widget}
            return
        end
        if n<4 then return end
        check('image-second-output',204,102,51)
        s.scale=1.25
        return true
    end,
    function(n)
        if n<4 then return end
        check('image-second-output-fractional',204,102,51)
        s.output.position={x=first_screen.geometry.width+40,y=40}
        return true
    end,
    function(n)
        if n<4 then return end
        check('image-second-output-moved',204,102,51)
        wall:detach(); first_wall:detach()
        return true
    end,
}
