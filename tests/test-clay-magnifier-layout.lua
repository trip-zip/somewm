-- Focused attachment and cyclic background membership in magnifier.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local utils = require('_utils')
local example = require('_clay_example')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s = screen[1]
runner.run_async(function()
    local clients,reports,failures={},{},{}
    local colors={'ffcc0000','ff00cc00','ff0000cc','ffcccc00'}
    s.selected_tag.layout=awful.layout.suit.magnifier
    s.selected_tag.gap_single_client=true
    for count=0,4 do
        if count>0 then
            reports[count]=os.tmpname()
            awful.spawn{binary,'MAG_'..count,reports[count],count==1 and '1400' or '0',colors[count]}
            for _=1,30 do
                clients[count]=utils.find_client_by_class('MAG_'..count)
                if clients[count] then break end
                async.sleep(0.02)
            end
            local c=assert(clients[count],'client missing')
            c.floating,c.shadow,c.border_width=false,false,1
            c.size_hints_honor=false
            awful.titlebar(c,{size=24}).widget=wibox.container.background(nil,'#cc6600')
        end
        for i,wanted in ipairs(clients) do
            local current=awful.client.tiled(s)[i]
            if current~=wanted then current:swap(wanted) end
        end
        for focused=1,math.max(1,count) do
            client.focus=clients[focused]
            if clients[focused] then clients[focused]:raise() end
            for _,gap in ipairs{0,8} do
                s.selected_tag.gap=gap
                for _,factor in ipairs{0.25,0.49,0.81} do
                    s.selected_tag.master_width_factor=factor
                    async.sleep(0.10)
                    local name=string.format('magnifier-%d-focus%d-gap%d-factor%d',count,focused,gap,factor*100)
                    local dump=awesome._clay_tree(s)
                    if not dump:find('derived 0',1,true) then failures[#failures+1]=name end
                    local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
                    local report=dir and assert(io.open(dir..'/'..name..'.geometry','w'))
                    for i,c in ipairs(clients) do
                        local g=c:geometry()
                        local f=assert(io.open(reports[i]))
                        local w,h=f:read('*a'):match('(%d+)%s+(%d+)');f:close()
                        local sw,sh=dump:match('SURFACE '..c.class..' [^\n]-box %-?%d+,%-?%d+ (%d+)x(%d+)')
                        assert(w==sw and h==sh,name..': configure differs from solved surface')
                        if i==focused then
                            example.pixel(g.x+math.floor(g.width/2),g.y+math.floor(g.height/2),'#'..colors[i]:sub(3))
                        else
                            example.pixel(g.x+10,g.y+30,'#'..colors[i]:sub(3))
                        end
                        if report then report:write(string.format('%s %d %d %d %d configure %s %s\n',c.class,g.x,g.y,g.width,g.height,w,h)) end
                    end
                    if report then report:close() end
                    example.save(name,dump)
                end
            end
            if count>0 then
                local c=clients[focused]
                local events={}
                local function press(original,x,y,button,mods)
                    local g=c:geometry()
                    assert(original==c and x==640-g.x and y==360-g.y and button==1 and #mods==0)
                    events[#events+1]='press'
                end
                local function release(original,x,y,button,mods)
                    local g=c:geometry()
                    assert(original==c and x==640-g.x and y==360-g.y and button==1 and #mods==0)
                    events[#events+1]='release'
                end
                c:connect_signal('button::press',press);c:connect_signal('button::release',release)
                awful.spawn{pointer,'click','640','360','1280','720','left'}
                for _=1,30 do if #events==2 then break end;async.sleep(0.02) end
                assert(table.concat(events,',')=='press,release','focused original client did not receive pointer input')
                c:disconnect_signal('button::press',press);c:disconnect_signal('button::release',release)
            end
        end
    end
    client.focus=clients[1]
    clients[1]:raise()
    clients[1].size_hints_honor=true
    s.selected_tag.master_width_factor=0.25
    for _,gap in ipairs{0,8} do
        s.selected_tag.gap=gap
        async.sleep(0.12)
        local dump=awesome._clay_tree(s)
        local line=assert(dump:match('SURFACE MAG_1 [^\n]+'))
        local width=tonumber(line:match('box %-?%d+,%-?%d+ (%d+)x'))
        local f=assert(io.open(reports[1]))
        local configured=tonumber(f:read('*a'):match('(%d+)'));f:close()
        assert(width==1400 and configured==width and line:find('w=grow>=1400',1,true),'focused surface minimum was lost')
        example.pixel(1000,400,'#cc0000')
        example.save('magnifier-focused-minimum-gap'..gap,dump)
    end
    s.inspector=true
    async.sleep(0.12)
    example.save('magnifier-inspector',awesome._clay_tree(s))
    s.inspector=false
    for _,c in ipairs(clients) do c:kill() end
    for _,report in ipairs(reports) do os.remove(report) end
    io.stderr:write('[PASS] magnifier0..4 clients, each focused index, three factors, gap0/8, titlebars, configures and original real input\n')
    assert(#failures==0,'non-native magnifier declarations: '..table.concat(failures,', '))
    runner.done()
end)
