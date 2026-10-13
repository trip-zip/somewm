-- Scene captures must retain text and image pixels after texture upload.
-- Flat rectangles alone do not exercise wlroots releasing a CPU raster.
local runner=require('_runner')
local wibox=require('wibox')
local capture=require('_widget_capture')
local surface=require('gears.surface')
local cairo=require('lgi').cairo
local s
local w, text, image
local evidence=os.getenv('TASK4_CAPTURE_EVIDENCE')
local function check()
    local g=w:geometry()
    for name, shot in pairs{root=surface(root.content()),screen=surface(s.content)} do
        if evidence then shot:write_to_png(evidence..'/'..name..'.png') end
        local ox=name=='root' and g.x or g.x-s.geometry.x
        local oy=name=='root' and g.y or g.y-s.geometry.y
        local white,red=0,0
        for y=0,49 do for x=0,239 do
            local r,bg,b=capture.read(shot,ox+x,oy+y)
            if r>220 and bg>220 and b>220 then white=white+1 end
            if r>240 and bg<10 and b<10 then red=red+1 end
        end end
        assert(white>100,name..' capture omitted uploaded text: '..white..' white pixels')
        assert(red>500,name..' capture omitted uploaded image: '..red..' red pixels')
    end
end
runner.run_steps{
    -- A hidden parent window can stall a Wayland output before upload. A
    -- headless sibling still presents frames using the same real renderer.
    function() assert(awesome._test_add_output(800,600)); return true end,
    function() return screen.count()>=2 or nil end,
    function()
        for candidate in screen do
            if not s or candidate.geometry.x>s.geometry.x then s=candidate end
        end
        local im=cairo.ImageSurface.create(cairo.Format.ARGB32,32,32)
        local cr=cairo.Context(im); cr:set_source_rgb(1,0,0); cr:paint()
        text=wibox.widget.textbox('MMMM'); text.font='sans 24'
        image=wibox.widget.imagebox(im); image.resize=false
        w=wibox{screen=s,x=s.geometry.x+200,y=s.geometry.y+150,width=240,height=50,
            visible=true,bg='#000000',fg='#ffffff',
            widget={layout=wibox.layout.fixed.horizontal,text,image}}
        return true
    end,
    function(n) if n<8 then return end; check(); text.text='WWWW'; return true end,
    function(n)
        if n<8 then return end; check()
        io.stderr:write('[PASS] settled and replaced text/image rasters appear in root and screen captures\n')
        if evidence then _capture_probe=w else w.visible=false end
        return true
    end,
}
