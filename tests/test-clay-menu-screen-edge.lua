-- A menu opened at a point near the screen's far corner stays on the screen,
-- and the screen area around it still takes the pointer.
local runner=require('_runner')
local awful=require('awful')
local wibox=require('wibox')
local example=require('_clay_example')
local s=screen[1]
local g=s.geometry
local menu, below
local entered=false
runner.run_steps {
    function()
        root.wallpaper(require('gears.color')('#123456'))
        below=wibox {screen=s,x=g.x+20,y=g.y+g.height-60,width=60,height=40,
            bg='#00ff00',visible=true}
        below:connect_signal('mouse::enter',function() entered=true end)
        menu=awful.menu {items={{'One',function() end},{'Two',function() end}},
            theme={width=120,height=24,border_width=2,border_color='#0000ff',
                bg_normal='#ff0000',bg_focus='#ff0000'}}
        menu:show {coords={x=g.x+g.width-10,y=g.y+g.height-10}}
        return true
    end,
    function(n)
        local mg=menu.wibox:geometry()
        -- The border sits outside the geometry, as on AwesomeWM.
        if mg.x+mg.width+2~=g.x+g.width or mg.y+mg.height+2~=g.y+g.height then
            assert(n<20,('menu %dx%d+%d+%d left the screen %dx%d'):format(
                mg.width,mg.height,mg.x,mg.y,g.width,g.height)); return
        end
        assert(mg.width==120 and mg.height==48, 'menu does not fit its items')
        example.pixel(g.width-3,g.height-3,'#ff0000')
        example.pixel(g.width-1,g.height-1,'#0000ff')
        local dump=awesome._clay_tree(s)
        assert(dump:match('roots flow 1 floating %d+ derived 0 '),'derived size')
        example.save('menu-screen-edge',dump)
        mouse.coords {x=g.x+50,y=g.y+g.height-40}
        mouse._fake_motion(1,0)
        mouse._fake_motion(-1,0)
        return true
    end,
    function(n)
        if not entered then assert(n<20,'the area around the menu took the pointer'); return end
        -- An open point well inside the screen keeps its corner at the point.
        menu:hide()
        menu:show {coords={x=g.x+200,y=g.y+100}}
        return true
    end,
    function(n)
        local mg=menu.wibox:geometry()
        if mg.x~=g.x+200 or mg.y~=g.y+100 then
            assert(n<20,('menu at %d,%d, not at the point'):format(mg.x,mg.y)); return
        end
        menu:hide()
        below.visible=false
        io.stderr:write('[PASS] menu slides inside the screen, pointer passes around it\n')
        return true
    end,
}
