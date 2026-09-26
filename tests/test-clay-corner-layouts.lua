-- Corner orientation, grouping, finite allocations and client protocol boxes.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local utils=require('_utils')
local wibox=require('wibox')
local example=require('_clay_example')
local binary=assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer=assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s=screen[1]
runner.run_async(function()
    local clients,reports,failures={},{},{}
    local colors={'ffcc0000','ff00cc00','ff0000cc','ffcccc00','ffcc00cc','ff00cccc'}
    local native=awful.layout.suit.corner.nw._clay~=nil
    local function capture(name,known_old_error)
        async.sleep(0.10)
        local dump=awesome._clay_tree(s)
        if not dump:find('derived 0',1,true) then failures[#failures+1]=name end
        example.save(name,dump)
        local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        local out=dir and assert(io.open(dir..'/'..name..'.geometry','w'))
        for i,c in ipairs(clients) do
            local g=c:geometry()
            local f=assert(io.open(reports[i]));local w,h=f:read('*a'):match('(%d+)%s+(%d+)');f:close()
            local sw,sh=dump:match('SURFACE '..c.class..' [^\n]-box %-?%d+,%-?%d+ (%d+)x(%d+)')
            if native or not known_old_error then
                assert(w==sw and h==sh,name..': configure differs from solved surface')
                assert(g.x>=0 and g.y>=0 and g.x+g.width+2<=1280 and g.y+g.height+2<=720,
                    name..': assigned client outside workarea')
                example.pixel(g.x+math.floor(g.width/2),g.y+math.floor(g.height/2),'#'..colors[i]:sub(3))
            end
            if out then out:write(string.format('%s %d %d %d %d configure %s %s surface %s %s\n',c.class,g.x,g.y,g.width,g.height,tostring(w),tostring(h),tostring(sw),tostring(sh))) end
        end
        if out then out:close() end
    end
    s.selected_tag.layout=awful.layout.suit.corner.nw
    s.selected_tag.master_fill_policy='expand'
    for count=0,6 do
        if count>0 then
            reports[count]=os.tmpname()
            awful.spawn{binary,'CORNER_'..count,reports[count],'0',colors[count]}
            for _=1,30 do
                clients[count]=utils.find_client_by_class('CORNER_'..count)
                if clients[count] then break end
                async.sleep(0.02)
            end
            local c=assert(clients[count]);c.floating,c.shadow,c.border_width=false,false,1
        end
        for i,wanted in ipairs(clients) do
            local current=awful.client.tiled(s)[i]
            if current~=wanted then current:swap(wanted) end
        end
        for _,masters in ipairs{1,2} do
            if native or count~=2 or masters~=2 then
                s.selected_tag.master_count=masters
                for _,orientation in ipairs{'nw','ne','sw','se'} do
                    s.selected_tag.layout=awful.layout.suit.corner[orientation]
                    for _,gap in ipairs{0,8} do
                        s.selected_tag.gap,s.selected_tag.gap_single_client=gap,true
                        s.selected_tag.master_width_factor=.5
                        capture(string.format('corner-%s-%d-master%d-gap%d',orientation,count,masters,gap),masters==2 and count>2 and count%2==0)
                    end
                end
            end
        end
        if count==1 then
            s.selected_tag.master_fill_policy='master_width_factor'
            for _,masters in ipairs{1,2} do
                s.selected_tag.master_count=masters
                for _,orientation in ipairs{'nw','ne','sw','se'} do
                    s.selected_tag.layout=awful.layout.suit.corner[orientation]
                    capture(string.format('corner-%s-centered-master%d',orientation,masters),
                        masters==1 and orientation:sub(2,2)=='e' or masters==2 and orientation:sub(1,1)=='s')
                end
            end
            s.selected_tag.master_fill_policy='expand'
        end
        if count==1 or count==3 then
            s.selected_tag.master_count=1
            for _,orientation in ipairs{'nw','ne','sw','se'} do
                s.selected_tag.layout=awful.layout.suit.corner[orientation]
                for _,factor in ipairs{.25,.75} do
                    s.selected_tag.master_width_factor=factor
                    s.selected_tag.gap_single_client=false
                    capture(string.format('corner-%s-%d-factor%d-suppress-single-gap',orientation,count,factor*100))
                end
            end
        end
        if count>0 and count<=3 then
            local events={}
            for i,c in ipairs(clients) do
                local widget=wibox.container.background(nil,'#cc6600')
                awful.titlebar(c,{size=24}).widget=widget
                for _,signal in ipairs{'button::press','button::release'} do
                    widget:connect_signal(signal,function(original,x,y,button,mods,area)
                        assert(original==widget and area.widget==widget)
                        -- Coordinates are relative to the titlebar drawable, which begins inside the border.
                        assert(x == 6 - c.border_width and y == 6 - c.border_width and button==1 and #mods==0)
                        events[#events+1]=signal..i
                    end)
                end
            end
            s.selected_tag.master_count=1
            s.selected_tag.gap,s.selected_tag.gap_single_client=8,true
            s.selected_tag.master_width_factor=.5
            for _,orientation in ipairs{'nw','ne','sw','se'} do
                s.selected_tag.layout=awful.layout.suit.corner[orientation]
                async.sleep(.12)
                for i,c in ipairs(clients) do
                    local g=c:geometry()
                    example.pixel(g.x+6,g.y+6,'#cc6600')
                    events={}
                    awful.spawn{pointer,'click',tostring(g.x+6),tostring(g.y+6),'1280','720','left'}
                    for _=1,30 do if #events==2 then break end;async.sleep(.02) end
                    assert(table.concat(events,',')=='button::press'..i..',button::release'..i,
                        'wrong original titlebar input: '..table.concat(events,','))
                end
                capture(string.format('corner-%s-%d-titlebars',orientation,count))
            end
            for _,c in ipairs(clients) do awful.titlebar.hide(c) end
        end
        -- Keep map-time layout in a valid exact-base mode before adding clients.
        s.selected_tag.master_count=1
        s.selected_tag.layout=awful.layout.suit.corner.nw
    end
    s.inspector=true
    async.sleep(.12)
    example.save('corner-inspector',awesome._clay_tree(s))
    s.inspector=false
    for _,c in ipairs(clients) do c:kill() end
    for _,report in ipairs(reports) do os.remove(report) end
    io.stderr:write('[PASS] corner finite matrix, all orientations, both privilege policies, gaps, centered single master actual configure sizes, titlebars and original real input\n')
    assert(#failures==0,'non-native corner declarations: '..table.concat(failures,', '))
    runner.done()
end)
