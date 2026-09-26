local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local s = screen[1]
runner.run_async(function()
    s.selected_tag.layout = awful.layout.suit.max
    local pid = awful.spawn('./build-test/test-transient-client')
    local p,c
    for _=1,30 do
        p=utils.find_client_by_class('transient_test_parent')
        if p then break end
        async.sleep(0.02)
    end
    assert(p,'parent missing')
    p.shadow,p.border_width=false,1
    awful.spawn('kill -USR1 ' .. pid)
    for _=1,30 do
        c=utils.find_client_by_class('transient_test_child')
        if c then break end
        async.sleep(0.02)
    end
    assert(c,'child missing')
    c.shadow,c.border_width=false,1
    for _,kind in ipairs {'max','fullscreen'} do
        s.selected_tag.layout=kind=='max' and awful.layout.suit.max or awful.layout.suit.max.fullscreen
        for _,gap in ipairs {0,8} do
            s.selected_tag.gap,s.selected_tag.gap_single_client=gap,true
            p.floating,c.floating=false,true
            c:geometry{x=100,y=100,width=200,height=160}
            for _,above in ipairs {false,true,false} do
                c.above=above
                async.sleep(0.1)
                local dump=awesome._clay_tree(s)
                local _,pc=dump:gsub('CLIENT transient_test_parent ', '')
                local _,cc=dump:gsub('CLIENT transient_test_child ', '')
                assert(pc==1 and cc==1,'duplicate or missing original client declarations')
                example.pixel(150,150,'#804040')
                example.save(kind .. '-gap' .. gap .. '-transient-above' .. tostring(above),dump)
            end
            p.floating,c.floating=true,false
            -- Author the floating parent area; its initial saved geometry
            -- depends on whether the first layout ran before border setup.
            p:geometry{x=40,y=40,width=300,height=200}
            async.sleep(0.1)
            local dump=awesome._clay_tree(s)
            local _,pc=dump:gsub('CLIENT transient_test_parent ', '')
            local _,cc=dump:gsub('CLIENT transient_test_child ', '')
            assert(pc==1 and cc==1,'native child of floating parent was declared incorrectly')
            example.pixel(150,150,'#804040')
            example.save(kind .. '-gap' .. gap .. '-native-transient',dump)
        end
    end
    p:kill()
    io.stderr:write('[PASS] max/fullscreen native/floating transient transitions, inherited and explicit bands, inset and full-size attachments\n')
    runner.done()
end)
