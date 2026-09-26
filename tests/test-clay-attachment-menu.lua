local runner=require('_runner')
local awful=require('awful')
local example=require('_clay_example')
local menu, child
local called=0
runner.run_steps {
    function()
        require('gears.wallpaper').set('#123456')
        menu=awful.menu {items={{'Sub',{{'Action',function() called=called+1 end}}},
            {'Other',function() end}}, theme={width=120,height=24,border_width=0,
                bg_normal='#ff0000',bg_focus='#ff0000'}}
        menu:show {coords={x=200,y=100}}
        return true
    end,
    function(n)
        local g=menu.wibox:geometry()
        if g.width~=120 or g.height~=48 then assert(n<20,'menu does not fit declared items'); return end
        assert(g.x==200 and g.y==100)
        example.pixel(202,102,'#ff0000')
        menu:item_enter(1)
        menu:exec(1,{exec=false})
        child=menu.child[1]
        assert(child)
        return true
    end,
    function(n)
        local g=child.wibox:geometry()
        if g.x~=320 or g.y~=100 then assert(n<20,'submenu did not attach to opener'); return end
        local a=child.wibox.drawin.attachment
        assert(a.target==require('wibox.clay').identity(menu.items[1]._background))
        assert(a.parent==6 and a.own==0)
        example.pixel(322,102,'#ff0000')
        -- Move the parent using explicit input; child has no geometry callback.
        menu:hide(); menu:show {coords={x=400,y=200}}
        menu:item_enter(1); menu:exec(1,{exec=false})
        return true
    end,
    function(n)
        local g=child.wibox:geometry()
        if g.x~=520 or g.y~=200 then assert(n<20,'submenu did not follow parent'); return end
        example.pixel(522,202,'#ff0000'); example.pixel(322,102,'#123456')
        child:exec(1,{exec=true})
        assert(called==1)
        return true
    end,
    function(n)
        if awesome._clay_tree(screen[1]):find('  POPUP ',1,true) then
            assert(n<20,'closed menu still declared'); return
        end
        io.stderr:write('[PASS] menu fit, submenu target ID, moved painted attachment, action and closure\n')
        return true
    end,
}
