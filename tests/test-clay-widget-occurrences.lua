-- Repeated Lua objects have distinct, stable bindings to real Clay elements.
local runner = require('_runner')
local wibox = require('wibox')
local clay = require('wibox.clay')
local example = require('_clay_example')
local host, host2, layout, shared, before, last
local function ids(s)
    local result = {}
    for id in awesome._clay_tree(s or screen[1]):gmatch('(%x+) +occurrence%-leaf ') do
        result[#result+1] = id
    end
    return result
end
runner.run_steps {
    function()
        shared = wibox.widget.base.make_widget()
        clay.describe_widget(shared, function()
            return {w=50,h=20,bg={1,0,0,1}}
        end, 'occurrence-leaf')
        layout = wibox.layout.fixed.horizontal(shared, shared)
        host = wibox {screen=screen[1],x=100,y=100,width=200,height=40,
            visible=true,bg='#204080',widget=layout}
        return true
    end,
    function(n)
        local dump = awesome._clay_tree(screen[1])
        if n<3 or dump~=last then last=dump; assert(n<20); return end
        before=ids()
        assert(#before==2 and before[1]~=before[2], 'duplicate widgets need distinct real elements')
        for _, x in ipairs{10,60} do
            local found
            for _, hit in ipairs(host:find_widgets(x,10)) do
                if hit.widget==shared then
                    assert(not found, 'one point delivered duplicate hits for one occurrence')
                    found=hit
                end
            end
            assert(found and found.width==50, 'original shared object lost its occurrence area')
            assert(found.x==(x==10 and 0 or 50), 'shared object has the other occurrence box')
        end
        example.save('occurrences-before-insert',dump)
        local spacer = wibox.widget.base.make_widget()
        clay.describe_widget(spacer,function() return {w=5,h=20} end,'occurrence-spacer')
        layout:insert(1,spacer)
        last=nil
        return true
    end,
    function(n)
        local dump=awesome._clay_tree(screen[1])
        if n<3 or dump~=last then last=dump; assert(n<20); return end
        example.save('occurrences-after-insert',dump)
        local after=ids()
        assert(#after==2 and after[1]==before[1] and after[2]==before[2],
            'unrelated sibling insertion changed real occurrence IDs: '
                ..table.concat(before,',')..' -> '..table.concat(after,','))
        layout:remove(1)
        last=nil
        return true
    end,
    function(n)
        local dump=awesome._clay_tree(screen[1])
        if n<3 or dump~=last then last=dump; assert(n<20); return end
        local after=ids()
        assert(after[1]==before[1] and after[2]==before[2])
        io.stderr:write('[PASS] duplicate Lua widget lookup areas and real occurrence IDs survive sibling insertion/removal\n')
        awesome._test_add_output(800,600)
        last=nil
        return true
    end,
    function(n)
        if screen.count()<2 then assert(n<20); return end
        if not host2 then
            local s=screen[2]
            host2=wibox {screen=s,x=s.geometry.x+100,y=s.geometry.y+100,
                width=140,height=60,visible=true,bg='#204080',widget=shared}
            return
        end
        local dump=awesome._clay_tree()
        if dump~=last then last=dump; assert(n<20); return end
        local second=ids(screen[2])
        assert(#second==1 and second[1]~=before[1] and second[1]~=before[2],
            'a second output reused another placement ID')
        local found
        for _, hit in ipairs(host2:find_widgets(10,10)) do
            if hit.widget==shared then found=hit end
        end
        assert(found and found.width==140 and found.height==60,
            'second output lookup used the first output allocation')
        shared:set_forced_width(70)
        last=nil
        return true
    end,
    function(n)
        local dump=awesome._clay_tree()
        if n<3 or dump~=last then last=dump; assert(n<20); return end
        local found
        for _, hit in ipairs(host:find_widgets(80,10)) do
            if hit.widget==shared then found=hit end
        end
        assert(found and found.x==70 and found.width==70,
            'shared property change did not update every first-output occurrence')
        local second
        for _, hit in ipairs(host2:find_widgets(10,10)) do
            if hit.widget==shared then second=hit end
        end
        assert(second and second.width==140 and second.height==60)
        local after=ids()
        assert(after[1]==before[1] and after[2]==before[2])
        example.save('occurrences-two-outputs',dump)
        io.stderr:write('[PASS] one original widget on two real outputs has separate solved areas and stable IDs; property change updates all occurrences\n')
        host.visible,host2.visible=false,false
        return true
    end,
}
