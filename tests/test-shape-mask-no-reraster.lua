local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local shape = require('gears.shape')
local color = require('gears.color')
local cairo = require('lgi').cairo
local shot = require('_shape_mask_capture')
local s = screen[1]
local popup, bar, nested, progress, bytes
local function counters()
    local b,n = awesome._clay_tree(s):match('raster_bytes (%d+) buffers (%d+)')
    assert(b, 'missing raster counters')
    return tonumber(b),tonumber(n)
end
local function no_buffers()
    local b,n=counters()
    assert(n==0,'move allocated '..n..' content buffers')
    assert(b==bytes,'move changed resident raster bytes')
end
local image = cairo.ImageSurface.create(cairo.Format.ARGB32,200,60)
local cr=cairo.Context(image); cr:set_source_rgb(0,0,1); cr:paint()
local steps = {
    function()
        root.wallpaper(color('#123456'))
        mouse.coords{x=600,y=350}
        popup=awful.popup{x=100,y=100,visible=true,shadow=false,bg='#ff0000',
            shape=shape.hexagon,minimum_width=200,maximum_width=200,
            minimum_height=60,maximum_height=60,
            widget={layout=wibox.layout.fixed.horizontal,
                {text='path text',forced_width=100,widget=wibox.widget.textbox},
                {image=image,forced_width=100,widget=wibox.widget.imagebox}}}
        return true
    end,
    function(n)
        if n<5 then return end
        awesome._test_redeclare()
        bytes=counters()
        return true
    end,
}
for _=1,4 do
    steps[#steps+1]=function()
        popup.x=popup.x+10
        awesome._test_redeclare()
        no_buffers()
        return true
    end
    steps[#steps+1]=shot.wait(function()
        assert(shot.pixel(popup.x,popup.y)=='#123456','hexagon corner not cut after move')
        assert(shot.pixel(popup.x+150,popup.y+15)=='#0000ff','image did not move')
    end)
end
steps[#steps+1]=function()
    popup.visible=false
    progress=wibox.widget{shape=shape.rounded_bar,clip=true,value=0,
        color='#0000ff',background_color='#ff0000',widget=wibox.widget.progressbar}
    bar=wibox{x=100,y=100,width=200,height=20,visible=true,bg='#123456',widget=progress}
    return true
end
steps[#steps+1]=function(n) if n<5 then return end; awesome._test_redeclare(); bytes=counters(); return true end
for i=1,10 do
    steps[#steps+1]=function()
        progress.value=i/10
        awesome._test_redeclare()
        no_buffers()
        assert(shot.pixel(100,100)=='#123456','progressbar arc did not cut its corner')
        return true
    end
end
steps[#steps+1]=function()
    bar.visible=false
    local square=cairo.ImageSurface.create(cairo.Format.ARGB32,60,60)
    local ctx=cairo.Context(square); ctx:set_source_rgb(0,0,1); ctx:paint()
    nested=wibox{x=100,y=100,width=60,height=60,visible=true,shadow=false,bg='#ff0000',
        shape=function(ctx,w,h) shape.rounded_rect(ctx,w,h,8) end,
        widget={{image=square,clip_shape=shape.circle,widget=wibox.widget.imagebox},
            shape=shape.hexagon,bg='#ff0000',widget=wibox.container.background}}
    return true
end
steps[#steps+1]=shot.wait(function()
    assert(shot.pixel(130,130)=='#0000ff','nested center is not image')
    assert(shot.pixel(100,100)=='#123456','outer rounded corner not cut')
    assert(shot.pixel(104,114)=='#ff0000','circle outside hexagon not cut')
    awesome._test_redeclare(); bytes=counters()
end)
steps[#steps+1]=function()
    nested.x=nested.x+10; awesome._test_redeclare(); no_buffers(); return true
end
steps[#steps+1]=shot.wait(function()
    assert(shot.pixel(140,130)=='#0000ff')
    assert(shot.pixel(110,100)=='#123456')
    nested.visible=false
end)
runner.run_steps(steps)
