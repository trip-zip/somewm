-- Native aspect sizing retains the image producer's outward pixel rounding.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local example=require('_clay_example')
local cairo=require('lgi').cairo
runner.run_async(function()
    local retained={};_image_rounding_hosts=retained
    for _,source in ipairs {{20,17},{17,20},{2,7},{13,7}} do
        local s=cairo.ImageSurface(cairo.Format.ARGB32,source[1],source[2])
        local cr=cairo.Context(s);cr:set_source_rgb(1,0,0);cr:paint()
        local icon=wibox.widget.imagebox(s)
        local row=wibox.layout.fixed.horizontal(icon,wibox.widget.textbox('text'))
        local bar=wibox {x=100,y=100,width=400,height=24,visible=true,screen=screen[1],bg='#0000ff',widget=row}
        retained[#retained+1]=bar
        for _,h in ipairs {24,21} do
            bar.height=h;awesome._test_redeclare();async.sleep(0.1)
            local want=math.ceil(h*source[1]/source[2])
            local name='image-rounding-'..source[1]..'x'..source[2]..'-'..h
            example.save(name,awesome._clay_tree(screen[1]))
            local hit
            for _,area in ipairs(bar:find_widgets(1,1)) do if area.widget==icon then hit=area end end
            assert(hit and hit.width==want,name..' area expected '..want..', got '..tostring(hit and hit.width))
            example.pixel(100+math.floor(want/2),100+math.floor(h/2),'#ff0000')
            example.pixel(100+want,100,'#0000ff')
        end
        bar.visible=false
    end
    runner.done()
end)
