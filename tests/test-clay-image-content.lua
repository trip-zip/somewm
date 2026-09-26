-- FIT images start from source dimensions; tray slots retain authored bounds.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local wibox=require('wibox')
local example=require('_clay_example')
local cairo=require('lgi').cairo

runner.run_async(function()
    local src=cairo.ImageSurface(cairo.Format.ARGB32,20,10)
    local cr=cairo.Context(src); cr:set_source_rgb(1,0,0);cr:paint()
    local image=wibox.widget.imagebox(src)
    local popup=awful.popup {widget=image,screen=screen[1],visible=true,bg='#0000ff',
        border_width=0,shadow=false,placement=function(d) awful.placement.top_left(d,{offset={x=100,y=100}}) end}
    _image_content_popup=popup
    awesome._test_redeclare()
    example.save('image-content-natural-first',awesome._clay_tree(screen[1]))
    assert(popup.width==20 and popup.height==10,'natural FIT image: '..popup.width..'x'..popup.height)
    async.sleep(0.1)
    example.pixel(102,102,'#ff0000')
    example.save('image-content-natural',awesome._clay_tree(screen[1]))
    image.forced_width=40
    awesome._test_redeclare()
    example.save('image-content-forced-first',awesome._clay_tree(screen[1]))
    assert(popup.width==40 and popup.height==20,'forced FIT axis must size its aspect-dependent content')
    async.sleep(0.1)
    example.pixel(135,115,'#ff0000')
    example.save('image-content-forced',awesome._clay_tree(screen[1]))
    image.upscale=false
    awesome._test_redeclare()
    assert(popup.width==40 and popup.height==10,'natural cap with authored width')
    async.sleep(0.1)
    example.pixel(102,102,'#ff0000');example.pixel(135,102,'#0000ff')
    example.save('image-content-capped-forced',awesome._clay_tree(screen[1]))
    popup.visible=false

    local item=systray_item.register()
    item:set_icon_pixmap(20,10,string.char(255,255,0,0):rep(200))
    local icon=wibox.widget.systray_icon(item)
    local slot=wibox {x=100,y=100,width=80,height=80,screen=screen[1],visible=true,
        bg='#0000ff',widget=icon}
    _image_content_tray={slot,item,icon}
    for _,size in ipairs {24,40,16,24} do
        icon.forced_size=size
        awesome._test_redeclare()
        local dump=awesome._clay_tree(screen[1])
        example.save('image-tray-'..size..'-first',dump)
        local found
        for line in dump:gmatch('[^\n]+') do
            if line:match('^    %x+ .* image 20x10 ') then
                local w,h=line:match('box %-?%d+,%-?%d+ (%d+)x(%d+)')
                assert(tonumber(w)==size and tonumber(h)==size/2,line)
                assert(not line:find('last-frame',1,true),line)
                found=true
            end
        end
        assert(found,'native tray image missing')
        async.sleep(0.1)
        example.pixel(140,140,'#ff0000')
        example.pixel(102,102,'#0000ff')
        local hit
        for _,area in ipairs(slot:find_widgets(2,2)) do if area.widget==icon then hit=area end end
        assert(hit and hit.width==80 and hit.height==80,'tray input area shrank to image')
        example.save('image-tray-'..size,dump)
    end
    slot.visible=false
    item.status='Passive'
    runner.done()
end)
