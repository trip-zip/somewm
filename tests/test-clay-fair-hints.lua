-- Protocol minima remain on surfaces without changing fair's assigned cells.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local utils=require('_utils')
local example=require('_clay_example')
local binary=assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer=assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local capture=require('_widget_capture')
local surface=require('gears.surface')
local s=screen[1]
runner.run_async(function()
    local clients,reports,failures,events={},{},{},{}
    local colors={'ffcc0000','ff00cc00','ff0000cc','ffcccc00'}
    s.selected_tag.layout=awful.layout.suit.fair
    for count=1,4 do
        reports[count]=os.tmpname()
        awful.spawn{binary,'FAIR_HINT_'..count,reports[count],count==1 and '900' or '0',colors[count]}
        for _=1,30 do
            clients[count]=utils.find_client_by_class('FAIR_HINT_'..count)
            if clients[count] then break end
            async.sleep(0.02)
        end
        local c=assert(clients[count]);c.floating,c.shadow,c.border_width=false,false,1
        c.size_hints_honor=count==1
        for _,signal in ipairs{'button::press','button::release'} do
            c:connect_signal(signal,function(original,x,y,button,mods)
                local g=c:geometry()
                assert(original==c and x==700-g.x and y==100-g.y and button==1 and #mods==0)
                events[#events+1]=signal..':'..c.class
            end)
        end
        if count>=2 then
            for i,wanted in ipairs(clients) do
                local current=awful.client.tiled(s)[i]
                if current~=wanted then current:swap(wanted) end
            end
            for _,kind in ipairs{'fairv','fairh'} do
                s.selected_tag.layout=kind=='fairv' and awful.layout.suit.fair or awful.layout.suit.fair.horizontal
                for _,gap in ipairs{0,8} do
                    s.selected_tag.gap,s.selected_tag.gap_single_client=gap,true
                    client.focus=clients[1];clients[1]:raise()
                    async.sleep(0.12)
                    local name=kind..'-'..count..'-minimum-gap'..gap
                    local dump=awesome._clay_tree(s)
                    example.save(name,dump)
                    local g=clients[1]:geometry()
                    local width=kind=='fairh' and count==2 and 1280 or 640
                    local height=kind=='fairv' and count==2 and 720 or 360
                    if g.x~=gap or g.y~=gap or g.width~=width-2-2*gap or g.height~=height-2-2*gap then
                        failures[#failures+1]=name..'-client-allocation'
                    end
                    if count==3 then
                        local last=clients[3]:geometry()
                        local x,y,w,h=640,0,640,720
                        if kind=='fairh' then x,y,w,h=0,360,1280,360 end
                        assert(last.x==x+gap and last.y==y+gap
                            and last.width==w-2-2*gap and last.height==h-2-2*gap,
                            name..'-singleton-must-fill-column')
                    end
                    local line=assert(dump:match('SURFACE FAIR_HINT_1 [^\n]+'))
                    local sw,sh=line:match('box %-?%d+,%-?%d+ (%d+)x(%d+)')
                    local f=assert(io.open(reports[1]))
                    local cw,ch=f:read('*a'):match('(%d+)%s+(%d+)');f:close()
                    assert(sw==cw and sh==ch,'configure differs from solved surface')
                    if tonumber(sw)~=math.max(900,width-2-2*gap) then failures[#failures+1]=name..'-surface-minimum' end
                    assert(line:find('w=grow>=900',1,true),'protocol floor absent')
                    local r,gc,b=capture.read(surface(root.content()),700,100)
                    local color=string.format('%02x%02x%02x',r,gc,b)
                    local visible
                    for i,obj in ipairs(clients) do if colors[i]:sub(3)==color then visible=obj end end
                    assert(visible,'unexpected overlap pixel')
                    events={}
                    awful.spawn{pointer,'click','700','100','1280','720','left'}
                    for _=1,30 do if #events==2 then break end;async.sleep(0.02) end
                    local input=table.concat(events,',')
                    assert(input=='button::press:'..visible.class..',button::release:'..visible.class,
                        'paint and original-client input disagree')
                    local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
                    if dir then
                        local out=assert(io.open(dir..'/'..name..'.geometry','w'))
                        out:write(string.format('client %d %d %d %d surface %s %s\n',g.x,g.y,g.width,g.height,sw,sh));out:close()
                        out=assert(io.open(dir..'/'..name..'.input','w'));out:write(color,' ',input,'\n');out:close()
                    end
                end
            end
        end
    end
    for _,c in ipairs(clients) do c:kill() end
    for _,report in ipairs(reports) do os.remove(report) end
    assert(#failures==0,table.concat(failures,', '))
    runner.done()
end)
