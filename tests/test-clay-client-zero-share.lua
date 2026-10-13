-- An explicit zero share is distinct from an unspecified GROW allocation.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local utils=require('_utils')
local example=require('_clay_example')
local binary=assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer=assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s=screen[1]
runner.run_async(function()
    local clients,reports,failures,events={},{},{},{}
    s.selected_tag.layout=awful.layout.suit.tile
    for i=1,2 do
        reports[i]=os.tmpname()
        awful.spawn{binary,'ZERO_'..i,reports[i],'0',i==1 and 'ffcc0000' or 'ff00cc00'}
        for _=1,30 do
            clients[i]=utils.find_client_by_class('ZERO_'..i)
            if clients[i] then break end
            async.sleep(.02)
        end
        local c=assert(clients[i]);c.floating,c.shadow,c.border_width=false,false,1
        for _,signal in ipairs{'button::press','button::release'} do
            c:connect_signal(signal,function(original,x,y,button,mods)
                local g=c:geometry()
                assert(original==c and x==700-g.x and y==400-g.y and button==1 and #mods==0)
                events[#events+1]=signal..i
            end)
        end
    end
    for i,wanted in ipairs(clients) do
        local current=awful.client.tiled(s)[i]
        if current~=wanted then current:swap(wanted) end
    end
    local policies={tile=awful.layout.suit.tile,corner=awful.layout.suit.corner.nw,magnifier=awful.layout.suit.magnifier}
    for _,name in ipairs{'tile','corner','magnifier'} do
        s.selected_tag.layout=policies[name]
        s.selected_tag.master_count=1
        s.selected_tag.gap,s.selected_tag.gap_single_client=0,true
        client.focus=clients[1]
        local previous_config={}
        for sequence,factor in ipairs{.5,0,1,.5} do
            s.selected_tag.master_width_factor=factor
            async.sleep(.15)
            local key=name..'-factor'..factor..(sequence==4 and '-restored' or '')
            local dump=awesome._clay_tree(s)
            example.save(key,dump)
            local zero=factor==0 and dump:find('percent(0)',1,true)
            if factor==0 and not zero then failures[#failures+1]=key end
            if zero then
                -- Empty native surfaces stay declared, while their scene nodes
                -- are disabled. They must not cover or receive B's real click.
                example.pixel(700,400,'#00cc00')
                events={}
                awful.spawn{pointer,'click','700','400','1280','720','left'}
                for _=1,30 do if #events==2 then break end;async.sleep(.02) end
                assert(table.concat(events,',')=='button::press2,button::release2')
            end
            local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
            local out=dir and assert(io.open(dir..'/'..key..'.geometry','w'))
            for i,c in ipairs(clients) do
                local g=c:geometry()
                local f=assert(io.open(reports[i]));local config=f:read('*a');f:close()
                local sw,sh=dump:match('SURFACE '..c.class..' [^\n]-box %-?%d+,%-?%d+ (%d+)x(%d+)')
                local cw,ch=config:match('(%d+)%s+(%d+)')
                if tonumber(sw)>0 and tonumber(sh)>0 then
                    assert(cw==sw and ch==sh,'positive surface configure mismatch: '..key)
                else
                    -- The existing protocol path skips zero-area configures.
                    assert(config==previous_config[i],'empty surface sent a new size: '..key)
                end
                previous_config[i]=config
                if out then out:write(c.class,' ',g.x,' ',g.y,' ',g.width,' ',g.height,' configure ',config,'\n') end
            end
            if out then out:close() end
            if dir and zero then
                local f=assert(io.open(dir..'/'..key..'.input','w'))
                f:write(table.concat(events,','),'\n');f:close()
            end
        end
    end
    for _,c in ipairs(clients) do c:kill() end
    for _,p in ipairs(reports) do os.remove(p) end
    assert(#failures==0,'explicit zero share became unspecified: '..table.concat(failures,', '))
    runner.done()
end)
