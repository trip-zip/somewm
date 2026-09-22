-- Fractional native origins, integer track rounding and scale-dependent calendars.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')
local solver=dofile('tests/_grid_solver.lua')
local check=require('_clay_grid_presentation')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
runner.run_async(function()
    local s=screen[1]
    local g=wibox.layout.grid();g.column_count=2;g.spacing=2.5
    g.expand={horizontal=true,vertical=false}
    local a=wibox.container.background(nil,'#ff0000');a.forced_width=20;a.forced_height=10
    local b=wibox.container.background(nil,'#00ff00');b.forced_width=20;b.forced_height=10
    g:add(a,b)
    local layout=wibox.layout.manual()
    layout:add_at(g,{x=10.5,y=20.5,width=200.5,height=60.5})
    local host=wibox{screen=s,x=20,y=20,width=250,height=100,visible=true,bg='#204080',widget=layout}
    local function frame(label)
        awesome._test_redeclare();check(host._drawable)
        local ga=solver.find(host._drawable._clay_tree,g)[1]
        assert(ga.binding.grid_state.columns[1]==98 and ga.binding.grid_state.columns[2]==98)
        for i,w in ipairs{a,b} do
            local found=solver.find(host._drawable._clay_tree,w);assert(#found==1)
            local box=found[1].box
            local x=i==1 and 11 or 112
            assert(box.x==x and box.y==21 and box.width==98 and box.height==10,
                label..': '..table.concat({box.x,box.y,box.width,box.height},','))
            local matched=false
            for _,hit in ipairs(host:find_widgets(x+2,23)) do
                if hit.widget==w then assert(hit.occurrence==found[1].binding.id);matched=true end
            end
            assert(matched)
            example.pixel(host.x+x+2,host.y+23,i==1 and '#ff0000' or '#00ff00')
        end
        example.pixel(host.x+110,host.y+23,'#204080')
        example.save(label,awesome._clay_tree(s))
        assert(awesome._test_redeclare()==0)
        io.stderr:write('[FRACTIONAL] '..label..' native_origin=10.5,20.5 tracks=98,98 geometry=pixels=lookup\n')
    end
    local pressed,released=0,0
    b:connect_signal('button::press',function(_,x,y,button,_,area)
        assert(x==2 and y==2 and button==1)
        assert(area.occurrence==solver.find(host._drawable._clay_tree,b)[1].binding.id)
        pressed=pressed+1
    end)
    b:connect_signal('button::release',function() released=released+1 end)
    for _,scale in ipairs{1,1.5,2,1} do
        s.dpi=96*scale;s.scale=scale;async.sleep(.1);frame('grid-scale-'..scale)
        pressed,released=0,0
        awful.spawn{pointer,'click','134','43',tostring(s.geometry.width),tostring(s.geometry.height),'left'}
        assert(async.wait_for_condition(function() return pressed==1 and released==1 end,2,.01))
        io.stderr:write('[FRACTIONAL INPUT] scale='..scale..' local=2,2 press=1 release=1\n')
    end
    host.visible=false
    for _,kind in ipairs{'month','year'} do
        local cal=wibox.widget.calendar[kind](nil,'monospace 10')
        cal.week_numbers=true;cal.spacing=3;cal.date={year=2026,month=9,day=16}
        host=awful.popup{screen=s,x=0,y=0,visible=true,widget=cal,bg='#204080',maximum_width=1100}
        local initial
        for _,scale in ipairs{1,1.5,2,1} do
            s.dpi=96*scale;s.scale=scale;async.sleep(.1)
            awesome._test_redeclare();check(host._drawable)
            local count=0
            local target
            local function walk(w)
                if w.set_text then
                    local found=solver.find(host._drawable._clay_tree,w)
                    assert(#found==1 and found[1].box.width>0 and found[1].box.height>0)
                    count=count+1
                    target=target or w
                end
                for _,child in ipairs(w._private.container and {w._private.container} or w:get_children()) do walk(child) end
            end
            walk(cal);assert(count>(kind=='year' and 400 or 30))
            assert(host._drawable._widget_context.dpi==s.dpi)
            if not initial then initial={host.width,host.height}
            elseif scale==1 then assert(host.width==initial[1] and host.height==initial[2],'DPI restoration') end
            local found=solver.find(host._drawable._clay_tree,target)[1]
            local box=found.box
            local delivered,released=0,0
            local function press(_,x,y,button,_,area)
                assert(x==1 and y==1 and button==1 and area.occurrence==found.binding.id,
                    string.format('delivered local=%g,%g occurrence=%s expected=%s',x,y,tostring(area.occurrence),tostring(found.binding.id)))
                check(host._drawable);delivered=delivered+1
            end
            local function release() released=released+1 end
            target:connect_signal('button::press',press)
            target:connect_signal('button::release',release)
            -- A half-pixel interior point avoids absolute-protocol rounding
            -- just below an integer; delivered drawable coordinates truncate.
            awful.spawn{pointer,'click',tostring(2*(host.x+box.x)+3),tostring(2*(host.y+box.y)+3),tostring(2*s.geometry.width),tostring(2*s.geometry.height),'left'}
            assert(async.wait_for_condition(function() return delivered==1 and released==1 end,2,.01))
            target:disconnect_signal('button::press',press)
            target:disconnect_signal('button::release',release)
            io.stderr:write('[DPI INPUT] '..kind..' scale='..scale..' local=1,1 press=1 release=1\n')
            example.save(kind..'-scale-'..scale,awesome._clay_tree(s))
            assert(awesome._test_redeclare()==0)
            io.stderr:write(string.format('[DPI] %s scale=%g dpi=%g width=%g height=%g text_occurrences=%d settled=true\n',kind,scale,s.dpi,host.width,host.height,count))
        end
        host.visible=false
    end
    runner.done()
end)
