-- X11 content intent is solved inside the decorated Clay frame. Exercise
-- the real ConfigureRequest/ConfigureNotify loop, including unchanged and
-- partial requests, bursts, gravity, and compositor policy.
-- timeout: 60
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-x11-configure-client'))
local spawned, logs = {}, {}

local function command(args)
    local text = binary
    for _, value in ipairs(args) do text = text .. ' ' .. tostring(value) end
    local pipe = assert(io.popen(text))
    local result = pipe:read('*a')
    assert(pipe:close(), text)
    return result
end
local function parse(text)
    local x,y,w,h = text:match('^(%-?%d+) (%-?%d+) (%d+) (%d+)')
    return x and {tonumber(x),tonumber(y),tonumber(w),tonumber(h)}
end
local function query(c) return assert(parse(command {'query',c.window})) end
local function same(a,b)
    for i=1,4 do if a[i] ~= b[i] then return false end end
    return true
end
local function geometry(c) return {c.x,c.y,c.width,c.height} end
local function read(path)
    local f = assert(io.open(path)); local text = f:read('*a'); f:close(); return text
end
local function wait_box(c, expected)
    assert(async.wait_for_condition(function() return same(query(c), expected) end, 5),
        'X11 geometry: wanted '..table.concat(expected,',')..' got '..table.concat(query(c),','))
end
local function spawn(name, gravity)
    local path = os.tmpname(); logs[#logs+1] = path
    local pid = awful.spawn {binary,'create',name,tostring(gravity),path}
    spawned[#spawned+1] = pid
    local c
    assert(async.wait_for_condition(function()
        for _, candidate in ipairs(client.get()) do
            if candidate.name == name then c=candidate; return true end
        end
    end, 10), 'client did not map: '..name)
    return c,path,pid
end
local function request(c,path,mask,box,count)
    local before = #read(path)
    command {'request',c.window,mask,box[1],box[2],box[3],box[4],count or 1}
    assert(async.wait_for_condition(function() return #read(path)>before end,5),
        'unchanged/denied request was not acknowledged')
    return before
end
local function assert_replies(path, before, expected)
    for line in read(path):sub(before+1):gmatch('[^\n]+') do
        assert(same(assert(parse(line)),expected), 'intermediate X11 geometry: '..line)
    end
end
local function set_frame(c)
    c:geometry {x=100,y=100,width=400,height=300}
end
local function tree_box(c, role)
    for line in awesome._clay_tree(c.screen):gmatch('[^\n]+') do
        if line:match('^%s*'..role..' '..c.class..' ') then
            return parse((line:match('box (.*)$') or ''):gsub(',',' '):gsub('x',' ')),line
        end
    end
    error('missing '..role..' in tree')
end
runner.run_async(function()
    -- Warm the lazy Xwayland server before the small test client; the
    -- existing X11 tests document the first-client property/map race.
    local warm,_,pid=spawn('configure_warmup',10)
    awesome.kill(pid,15)
    assert(async.wait_for_condition(function() return not warm.valid end,5))
    local function decorate_first(first)
        if first.name ~= 'configure_first' then return end
        first.floating=true; first.border_width=0; first.animation=false
        awful.titlebar(first,{position='top',size=24})
        command {'request',first.window,15,100,100,400,300}
    end
    client.connect_signal('request::manage',decorate_first)
    local first,_,first_pid=spawn('configure_first',10)
    wait_box(first,{100,100,400,300})
    async.sleep(.1)
    assert(same(query(first),{100,100,400,300}),'first solve shifted content request')
    client.disconnect_signal('request::manage',decorate_first)
    awesome.kill(first_pid,15)
    assert(async.wait_for_condition(function() return not first.valid end,5))
    local c,path = spawn('configure_intent',10)
    assert(c.opacity==1,'X11 clients must default to fully opaque')
    c.floating=true; c.border_width=3; c.shadow=false; c.animation=false
    awful.titlebar(c,{position='top',size=24})
    awful.titlebar(c,{position='left',size=11})
    awful.titlebar(c,{position='right',size=7})
    awful.titlebar(c,{position='bottom',size=13})
    set_frame(c)
    local content={114,127,382,263}
    wait_box(c,content)
    async.sleep(.05)
    for _,mask in ipairs {15,3,12,1,2,4,8} do
        for _=1,3 do
            local before=request(c,path,mask,content)
            wait_box(c,content)
            assert(same(geometry(c),{100,100,400,300}),'unchanged request altered frame')
            assert_replies(path,before,content)
            assert(same(tree_box(c,'SURFACE'),content),'Clay/X11 disagreement')
        end
    end
    local before=request(c,path,15,{119,134,392,275},100)
    wait_box(c,{119,134,392,275})
    assert(same(geometry(c),{105,107,410,312}),'burst accumulated changes')
    assert_replies(path,before,{119,134,392,275})
    -- The content request appears in the tree; the frame fits around it.
    local dump=awesome._clay_tree(c.screen)
    assert(dump:find('derived 0 legacy 0',1,true),dump)
    -- Actual position-only and width-only changes preserve omitted axes.
    before=request(c,path,3,{129,144,0,0})
    wait_box(c,{129,144,392,275})
    assert(same(geometry(c),{115,117,410,312}),'position intent was not settled')
    assert_replies(path,before,{129,144,392,275})
    before=request(c,path,4,{0,0,420,0})
    wait_box(c,{129,144,420,275})
    assert_replies(path,before,{129,144,420,275})
    -- Lua frame moves must publish one coherent content box as well.
    before=#read(path)
    c:geometry {x=200,y=180,width=500,height=350}
    wait_box(c,{214,207,482,313})
    assert_replies(path,before,{214,207,482,313})
    -- A Lua policy handling the request supersedes its content intent.
    local function override(target)
        if target == c then c:geometry {x=200,y=180,width=500,height=350} end
    end
    set_frame(c); wait_box(c,content)
    c:connect_signal('property::_x11_configure',override)
    before=request(c,path,15,{20,30,200,150})
    wait_box(c,{214,207,482,313})
    assert_replies(path,before,{214,207,482,313})
    c:disconnect_signal('property::_x11_configure',override)
    -- Changed decorations use their newly solved inset for StaticGravity.
    awful.titlebar(c,{position='left',size=19})
    awful.titlebar(c,{position='top',size=31})
    request(c,path,15,{300,250,400,280})
    wait_box(c,{300,250,400,280})
    awful.titlebar(c,{position='left',size=11})
    awful.titlebar(c,{position='top',size=24})
    -- All directional gravities use matching points of the reference box
    -- and decorated frame. Static keeps the content origin unchanged.
    for gravity=1,10 do
        command {'hints',c.window,gravity,0,0,0,0}
        set_frame(c); wait_box(c,content)
        local desired={300,250,400,280}
        local x,y
        if gravity==10 then x,y=300,250
        else
            local column=(gravity-1)%3
            local row=math.floor((gravity-1)/3)
            x=300-column*12+14 -- outer width = content + 24
            y=250-row*21.5+27 -- outer height = content + 43
            -- Match the renderer's rounding of solved bounding boxes.
            x,y=math.floor(x+.5),math.floor(y+.5)
        end
        before=request(c,path,15,desired)
        wait_box(c,{x,y,400,280})
        assert_replies(path,before,{x,y,400,280})
        local dx = gravity==10 and 0 or ((gravity-1)%3)*10
        local dy = gravity==10 and 0 or math.floor((gravity-1)/3)*5
        before=request(c,path,12,{0,0,420,290})
        wait_box(c,{x-dx,y-dy,420,290})
        assert_replies(path,before,{x-dx,y-dy,420,290})
    end
    -- A tiled/fullscreen client acknowledges its compositor allocation.
    c.floating=false
    c.screen.selected_tag.layout=awful.layout.suit.tile
    async.sleep(.15)
    local tiled=query(c)
    before=request(c,path,15,{20,30,100,80})
    wait_box(c,tiled); assert_replies(path,before,tiled)
    c.fullscreen=true; async.sleep(.15)
    local full=query(c)
    before=request(c,path,15,{20,30,100,80})
    wait_box(c,full); assert_replies(path,before,full)
    c.fullscreen=false; c.floating=true
    c.screen.selected_tag.layout=awful.layout.suit.floating
    c.maximized=true; async.sleep(.15)
    local maximized=query(c)
    before=request(c,path,15,{20,30,100,80})
    wait_box(c,maximized); assert_replies(path,before,maximized)
    c.maximized=false
    c.aspect_ratio=2
    c:geometry {x=100,y=100,width=400,height=200}
    async.sleep(.15)
    local constrained=query(c)
    before=request(c,path,15,{20,30,100,80})
    wait_box(c,constrained); assert_replies(path,before,constrained)
    c.aspect_ratio=0
    -- A config supplying its own client composite owns the allocation,
    -- and still acknowledges requests even though describe() is bypassed.
    c.floating=false
    c.screen.selected_tag.layout={name='custom_x11_allocation',arrange=function() end,
        _clay=function()
            return {name='WORKAREA',w='grow',h='grow',children={
                {name='CLIENT',client=c,float=true,x=40,y=50,w=300,h=200,
                    wsrc='layout',hsrc='layout',children={
                        {name='SURFACE',surface=c,w='grow',h='grow'}}}}}
        end}
    async.sleep(.15)
    local custom=query(c)
    before=request(c,path,15,{20,30,100,80})
    wait_box(c,custom); assert_replies(path,before,custom)
    assert(c._x11_configure==nil,'custom composite did not consume request')
    c.screen.selected_tag.layout=awful.layout.suit.floating
    c.floating=true
    -- Protocol minima and maxima constrain the content slot in Clay.
    command {'hints',c.window,10,200,150,450,330}
    async.sleep(.1)
    set_frame(c); wait_box(c,content)
    request(c,path,12,{0,0,100,100})
    wait_box(c,{114,127,200,150})
    request(c,path,12,{0,0,600,500})
    wait_box(c,{114,127,450,330})
    -- Border-only and undecorated controls stay unchanged as well.
    command {'hints',c.window,10,0,0,0,0}
    for _,side in ipairs {'top','left','right','bottom'} do awful.titlebar.hide(c,side) end
    for _,border in ipairs {0,3} do
        c.border_width=border
        set_frame(c)
        local bare={100+border,100+border,400,300}
        wait_box(c,bare)
        before=request(c,path,15,bare,8)
        wait_box(c,bare); assert_replies(path,before,bare)
    end
    -- An idle X11 client must keep its painted buffer when Clay borrows
    -- its scene again. Hovering must not be needed to undo opacity zero.
    local original_tag=c.screen.selected_tag
    local other=awful.tag.add('x11_opacity_check',{screen=c.screen,layout=awful.layout.suit.floating})
    other:view_only(); async.sleep(.15)
    original_tag:view_only(); async.sleep(.15)
    local r,g,b,a=require('_widget_capture').read(require('gears.surface')(c.content),20,20)
    assert(r==255 and g==255 and b==255 and a==255,
        string.format('X11 pixels lost after tag switch: %d,%d,%d,%d',r,g,b,a))
    other:delete()
    for _,process in ipairs(spawned) do awesome.kill(process,15) end
    assert(async.wait_for_condition(function() return not c.valid end,5))
    for _,log in ipairs(logs) do os.remove(log) end
    io.stderr:write('[PASS] X11 content requests, acknowledgements, masks, bursts, gravity and policy\n')
    runner.done()
end)
