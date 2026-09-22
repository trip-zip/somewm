-- Native decoration acceptance: solved boxes, actual pixels and real input.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local beautiful = require('beautiful')
local clay = require('wibox.clay')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local example = require('_clay_example')
local utils = require('_utils')
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))

local function record(dump, role, owner)
    for line in dump:gmatch('[^\n]+') do
        if line:match('^%s*' .. role .. ' ' .. owner .. ' ') then return line end
    end
end
local function box(line)
    local x,y,w,h = assert(line):match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    return {x=tonumber(x),y=tonumber(y),width=tonumber(w),height=tonumber(h)}
end
local function dark(x,y)
    local r,g,b = capture.read(surface(root.content()),x,y)
    assert(r < 220 and g < 220 and b < 220, ('shadow missing at %d,%d: %d,%d,%d'):format(x,y,r,g,b))
end
local function wait_for(fn)
    for _ = 1, 500 do
        local value = fn()
        if value then return value end
        async.sleep(0.002)
    end
    example.save('shadow-timeout',awesome._clay_tree(screen[1]))
    error('timed out waiting for authored change to reach a solved frame')
end
local function save(name)
    local dump = awesome._clay_tree(screen[1])
    assert(dump:find('derived 0',1,true),dump)
    example.save(name,dump)
    return dump
end
local function shadow(dump, owner, band, src, frame, ox, oy, radius)
    local line = assert(record(dump,'SHADOW',owner),'missing SHADOW '..owner)
    if owner=='screen 1' then
        -- A shadow floats one band below its owner, so Clay lists it as a
        -- root of its own, before the owner's root.
        local head=record(dump,'POPUP',owner) or record(dump,'WIBOX',owner)
        assert(dump:find(line,1,true) < dump:find(head,1,true),
            'shadow must precede its owner in the dump')
    end
    assert(line:find('w=grow h=grow '..src..' attach PARENT',1,true),line)
    assert(line:find(('offset %d,%d expand %d,%d band %d custom'):format(ox,oy,radius,radius,band),1,true),line)
    local b = box(line)
    assert(b.x==frame.x+ox-radius and b.y==frame.y+oy-radius and
        b.width==frame.width+2*radius and b.height==frame.height+2*radius,line)
    local commands = 0
    for command in dump:gmatch('[^\n]+') do
        if command:find('CUSTOM',1,true) and command:find(('box %d,%d %dx%d '):format(b.x,b.y,b.width,b.height),1,true) then
            local bytes = tonumber(assert(command:match('raster=(%d+)')))
            assert(bytes > 0 and bytes < 10000,'shadow must use tiny tiles: '..command)
            commands = commands + 1
        end
    end
    assert(commands==1,'expected one native shadow command, got '..commands)
end

runner.run_async(function()
    require('gears.wallpaper').set('#ffffff')
    beautiful.shadow_enabled, beautiful.shadow_drawin_enabled = true,true
    beautiful.shadow_radius, beautiful.shadow_spread = 12,0
    beautiful.shadow_offset_x, beautiful.shadow_offset_y = -15,-15
    beautiful.shadow_opacity, beautiful.shadow_color = 0.75,'#000000'
    awesome.shadow_reload()
    local hits = 0
    local under = wibox {screen=screen[1],x=0,y=0,width=1280,height=720,
        type='desktop',bg='#ffffff',visible=true,shadow=false,
        widget=wibox.widget.textbox(' ')}
    under:connect_signal('button::press',function() hits=hits+1 end)
    awful.spawn {binary,'SHADOW_CLIENT'}
    local c = wait_for(function() return utils.find_client_by_class('SHADOW_CLIENT') end)
    c.floating, c.border_width = true,2
    c:geometry{x=120,y=120,width=240,height=160}
    local d = wibox {screen=screen[1],x=500,y=120,width=200,height=100,
        bg='#ff0000',border_width=2,border_color='#0000ff',visible=true,
        shape=function(cr,w,h) require('gears.shape').rounded_rect(cr,w,h,10) end,
        widget=wibox.widget.textbox(' ')}
    local dump = wait_for(function()
        local tree = awesome._clay_tree(screen[1])
        local line=record(tree,'CLIENT','SHADOW_CLIENT')
        if line and box(line).x==120 and record(tree,'WIBOX','screen 1') then return tree end
    end)
    local cf,df = box(record(dump,'CLIENT','SHADOW_CLIENT')),box(record(dump,'WIBOX','screen 1'))
    assert(record(dump,'WIBOX','screen 1'):find('radius 8',1,true),'rounded frame missing on first open')
    shadow(dump,'SHADOW_CLIENT',19,'theme',cf,-15,-15,12)
    shadow(dump,'screen 1',24,'theme',df,-15,-15,12)
    for _,f in ipairs{cf,df} do
        dark(f.x-20,f.y+40); dark(f.x+40,f.y-20)
        example.pixel(f.x-28,f.y+40,'#ffffff')
        example.pixel(f.x+40,f.y-28,'#ffffff')
        -- The default offset covers the entire right/bottom falloff with the owner.
        example.pixel(f.x+f.width+1,f.y+40,'#ffffff')
        example.pixel(f.x+40,f.y+f.height+1,'#ffffff')
        awful.spawn {pointer,'click',tostring(f.x-20),tostring(f.y+40),'1280','720','left'}
        local want=hits+1
        wait_for(function() return hits==want end)
    end
    save('shadow-theme-client-and-wibox')
    assert(awesome._test_redeclare()==0,'idle shadow scene must not mutate')
    local centered = {radius=12,offset_x=0,offset_y=0,spread=0,corner_radius=0,opacity=0.75,color='#000000'}
    c.shadow,d.shadow = centered,centered
    wait_for(function() return record(awesome._clay_tree(screen[1]),'SHADOW','SHADOW_CLIENT'):find('offset 0,0',1,true) end)
    dump=save('shadow-four-edges')
    for _,f in ipairs{cf,df} do
        for _,p in ipairs{{f.x-5,f.y+40},{f.x+f.width+4,f.y+40},{f.x+40,f.y-5},{f.x+40,f.y+f.height+4}} do dark(p[1],p[2]) end
        for _,p in ipairs{{f.x-13,f.y+40},{f.x+f.width+12,f.y+40},{f.x+40,f.y-13},{f.x+40,f.y+f.height+12}} do example.pixel(p[1],p[2],'#ffffff') end
    end
    shadow(dump,'SHADOW_CLIENT',19,'user',cf,0,0,12)
    shadow(dump,'screen 1',24,'user',df,0,0,12)
    -- A rounded border's paint is independent of drawin content opacity.
    d.shadow=false
    d.shape=function(cr,w,h) require('gears.shape').rounded_rect(cr,w,h,10) end
    wait_for(function() return not record(awesome._clay_tree(screen[1]),'SHADOW','screen 1') end)
    for _,opacity in ipairs{1,0.25} do
        d.opacity=opacity
        wait_for(function()
            local _,g= capture.read(surface(root.content()),df.x+30,df.y+30)
            return opacity==1 and g==0 or opacity==0.25 and g>180
        end)
        example.pixel(df.x,df.y,'#ffffff')
        example.pixel(df.x+3,df.y+2,'#0000ff')
        example.pixel(df.x+10,df.y,'#0000ff')
        example.save('shadow-rounded-ring-'..opacity,awesome._clay_tree(screen[1]))
    end
    d.visible=false; c:kill()
    wait_for(function() return not c.valid end)

    -- Inspect the first observed solved frame at each new width, including first open.
    -- Never wait for the shadow to catch up to the border/content frame.
    local leaf = wibox.widget.base.make_widget(nil,nil,{enable_properties=true})
    clay.describe_widget(leaf,function() return {w=leaf.forced_width,h=40,bg={1,0,0,1}} end,'shadow-popup-content')
    leaf.forced_width=80
    local popup=awful.popup {screen=screen[1],visible=true,ontop=true,bg='#ff0000',
        border_width=3,border_color='#0000ff',shadow={radius=6,offset_x=6,offset_y=6,opacity=1},
        placement=function(d) awful.placement.top_left(d,{offset={x=750,y=350}}) end,widget=leaf}
    for i,width in ipairs{80,160,40} do
        leaf.forced_width=width
        dump=wait_for(function()
            local tree=awesome._clay_tree(screen[1]); local line=record(tree,'POPUP','screen 1')
            if line and box(line).width==width+6 then return tree end
        end)
        local f=box(record(dump,'POPUP','screen 1'))
        shadow(dump,'screen 1',79,'user',f,6,6,6)
        example.pixel(f.x+1,f.y+15,'#0000ff')
        example.pixel(f.x+f.width-1,f.y+15,'#0000ff')
        example.pixel(f.x+4,f.y+15,'#ff0000')
        dark(f.x+f.width+5,f.y+20)
        example.pixel(f.x+f.width+12,f.y+20,'#ffffff')
        save(i==1 and 'shadow-popup-first-open' or 'shadow-popup-width-'..width)
    end
    popup.border_width=5; popup.border_color='#00ff00'; popup.shadow=centered
    dump=wait_for(function()
        local tree=awesome._clay_tree(screen[1]);local line=record(tree,'POPUP','screen 1')
        if line and box(line).width==50 then return tree end
    end)
    local f=box(record(dump,'POPUP','screen 1'))
    shadow(dump,'screen 1',79,'user',f,0,0,12)
    example.pixel(f.x+f.width-1,f.y+15,'#00ff00');dark(f.x+f.width+4,f.y+20)
    save('shadow-popup-style-change')
    popup.shadow={radius=6,offset_x=6,offset_y=6,corner_radius=8,opacity=0.5,color='#00000080',clip_directional=false}
    wait_for(function() return record(awesome._clay_tree(screen[1]),'SHADOW','screen 1'):find('expand 6,6',1,true) end)
    example.pixel(f.x+f.width+1,f.y+20,'#bfbfbf')
    save('shadow-color-alpha-and-rounded-tiles')
    popup.shadow={radius=6,offset_x=6,offset_y=6,corner_radius=8,opacity=0.5,color='#00000080',clip_directional=true}
    async.sleep(0.02)
    example.pixel(f.x+f.width+1,f.y+20,'#bfbfbf')
    popup.visible=false;under.visible=false
    -- The bundled tile producer also puts in-flow client shadows under surfaces.
    screen[1].selected_tag.layout=awful.layout.suit.tile
    screen[1].selected_tag.gap=12
    awful.spawn {binary,'SHADOW_TILE_A'};awful.spawn {binary,'SHADOW_TILE_B'}
    local a=wait_for(function() return utils.find_client_by_class('SHADOW_TILE_A') end)
    local b=wait_for(function() return utils.find_client_by_class('SHADOW_TILE_B') end)
    a.floating=false;b.floating=false
    dump=wait_for(function()
        local tree=awesome._clay_tree(screen[1]);local line=record(tree,'SHADOW','SHADOW_TILE_B')
        if line and line:find('band -1',1,true) then return tree end
    end)
    wait_for(function()
        local tree=awesome._clay_tree(screen[1])
        local im=surface(root.content())
        for _,name in ipairs{'SHADOW_TILE_A','SHADOW_TILE_B'} do
            local content=box(record(tree,'SURFACE',name))
            local r,g,b=capture.read(im,content.x+content.width-2,content.y+50)
            if r~=64 or g~=64 or b~=64 then return false end
        end
        dump=tree
        return true
    end)
    for _,name in ipairs{'SHADOW_TILE_A','SHADOW_TILE_B'} do
        local frame=box(record(dump,'CLIENT',name));local content=box(record(dump,'SURFACE',name))
        shadow(dump,name,-1,'theme',frame,-15,-15,12)
        dark(frame.x-1,frame.y+50)
        example.pixel(content.x+1,content.y+50,'#404040')
        example.pixel(content.x+content.width-2,content.y+50,'#404040')
    end
    save('shadow-tiled-gap-and-neighbour')
    a:kill();b:kill()
    io.stderr:write('[PASS] native shadow boxes, one command/owner, shared tile bytes, theme/user bands, pixels, passthrough, rounded opacity and FIT first-open/resize\n')
    runner.done()
end)
