-- Distinct solid border colors preserve calendar geometry, pixels and real input.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local clay=require('wibox.clay')
local example=require('_clay_example')
local check=require('_clay_grid_presentation')
local solver=dofile('tests/_grid_solver.lua')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
local GLib=require('lgi').GLib
local function now() return GLib.get_monotonic_time()/1000 end
runner.run_async(function()
    local host,cal,day,phase,finished,presses,releases
    local retained={} -- Hold old widget objects through queued release delivery.
    local function calendar(kind)
        local w=wibox.widget.calendar[kind](nil,'monospace 10')
        w.spacing=3;w.week_numbers=true
        w.border_width=1
        w.border_color={inner="#8090a080",outer="#e0a030c0"}
        w.fn_embed=function(child,flag,date)
            if flag=='normal' then
                local bg=wibox.container.background(child,'#d03020')
                if date.month==1 and date.day==1 then day=bg end
                return bg
            end
            return child
        end
        w.date={year=2026,month=1,day=16}
        w:connect_signal('button::press',function(_,x,y,button,_,area)
            check(host._drawable)
            assert(button==1 and area.widget==w)
            local matches=solver.find(host._drawable._clay_tree,w)
            assert(#matches==1 and matches[1].binding.id==area.occurrence)
            local b=matches[1].box
            assert(x>=0 and y>=0 and x<b.width and y<b.height)
            assert(now()>=finished,'pointer dispatched before transaction finished')
            presses=presses+1
            io.stderr:write(string.format('[INPUT42] %s press occurrence=%s x=%g y=%g presented=true\n',phase,tostring(area.occurrence),x,y))
        end)
        w:connect_signal('button::release',function() releases=releases+1 end)
        retained[#retained+1]=w
        return w
    end
    local function click(x,y)
        awful.spawn{pointer,'click',tostring(x),tostring(y),'1280','720','left'}
    end
    local function transition(label,mutate,queued)
        phase=label;presses=0;releases=0;finished=math.huge
        if queued then
            -- The pointer client connects and starts its motion roundtrips
            -- before the mutation, then its press queues while layout works.
            finished=0;click(host.x+2,host.y+2);async.sleep(.07)
            presses=0;releases=0;finished=math.huge
        end
        mutate()
        awesome._test_redeclare()
        finished=now()
        check(host._drawable)
        example.save(label..'-presented',awesome._clay_tree(screen[1]))
        local found=solver.find(host._drawable._clay_tree,day)
        assert(#found==1,'original first-day occurrence missing')
        local b=found[1].box
        local hits=host:find_widgets(b.x+1,b.y+1)
        local matched=false
        for _,hit in ipairs(hits) do
            if hit.widget==day then
                assert(hit.occurrence==found[1].binding.id)
                assert(hit.x==b.x and hit.y==b.y and hit.width==b.width and hit.height==b.height)
                matched=true
            end
        end
        assert(matched,'presented day missing from native pointer query')
        example.pixel(host.x+b.x+1,host.y+b.y+1,'#d03020')
        if queued then
            assert(async.wait_for_condition(function() return presses==1 and releases==1 end,2,.01),'queued pointer not delivered')
        end
        presses=0;releases=0
        local delivered=0
        local function pressed(_,x,y,button,_,area)
            assert(button==1 and area.occurrence==found[1].binding.id and x==1 and y==1)
            example.pixel(host.x+b.x+1,host.y+b.y+1,'#d03020')
            delivered=delivered+1
        end
        day:connect_signal('button::press',pressed)
        click(host.x+b.x+1,host.y+b.y+1)
        assert(async.wait_for_condition(function() return presses==1 and releases==1 end,2,.01),'real pointer not delivered')
        day:disconnect_signal('button::press',pressed)
        assert(delivered==1,'real first-day targeting differs from native lookup')
        assert(awesome._test_redeclare()==0,'stable presented frame mutates scene')
        io.stderr:write('[PRESENT42] '..label..' pixels=geometry=indices=input restored_idle=true\n')
    end
    transition('first-year',function()
        cal=calendar('year');host=awful.popup{screen=screen[1],x=10,y=10,visible=true,widget=cal,bg='#204080',maximum_width=1100}
    end)
    transition('month-switch',function() cal=calendar('month');host.widget=cal end)
    transition('year-switch',function() cal=calendar('year');host.widget=cal end,true)
    local initial_height=host.height
    transition('width-grow',function() cal.forced_width=900 end,true)
    transition('width-shrink',function() cal.forced_width=550 end,true)
    transition('width-restore',function() cal.forced_width=nil end)
    transition('font-grow',function() cal.font='monospace 14' end,true)
    transition('font-restore',function() cal.font='monospace 10' end)
    assert(host.height==initial_height)
    local text=day.widget
    local old=text.text
    transition('content-grow',function() text.text='one one one one' end,true)
    transition('content-restore',function() text.text=old end)
    assert(host.height==initial_height)
    host.visible=false;async.sleep(.05)
    transition('show-restored',function() host.visible=true end)
    async.sleep(.25);assert(awesome._test_redeclare()==0)
    host.visible=false;runner.done()
end)
