-- Public grid border geometry, paint, mutation and real pointer checks.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local clay=require('wibox.clay')
local describe=wibox.layout.grid._clay.describe
local example=require('_clay_example')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
local solver=dofile('tests/_grid_solver.lua')
local phase,solves,declares='initial',0,0
local function children(w)
    if w._private.container then return {w._private.container} end
    return w:get_children()
end
local function prepare(w)
    if w._clay==wibox.layout.grid._clay then
        w._clay={describe=function(...)
            local node,why=describe(...)
            assert(node,why)
            assert(node._settle)
            -- Observe committed geometry; private settlement runs independently.
            node.solved=function(n)
                solves=solves+1
                local state=solver.find(n,w)[1].binding.grid_state
                io.stderr:write(string.format('[GRID] %s id=%s phase=%s settled=%s box=%dx%d updates=%d\n',
                    phase,tostring(n.occurrence),tostring(state.phase),tostring(state.settled),
                    n.box.width,n.box.height,state.updates))
            end
            return node
        end}
    end
    for _,c in ipairs(children(w)) do prepare(c) end
end
local function find(host,w)
    local found=solver.find(host._drawable._clay_tree,w)
    assert(#found==1,'missing/duplicate original occurrence')
    return found[1].box,found[1].binding
end
local function ready(host)
    local yes=true
    local function walk(n)
        for _,b in clay.bindings(n) do if b.grid_state and not b.grid_state.settled then yes=false end end
        for _,c in ipairs(n.children or {}) do walk(c) end
    end
    walk(host._drawable._clay_tree);return yes
end
local function settle(host,label)
    phase=label
    local before,dc=solves,declares
    local output_solves=0
    local frames=0
    repeat
        frames=frames+1
        local mutations=awesome._test_redeclare()
        io.stderr:write(string.format('[FRAME] %s frame=%d grid_callbacks=%d declarations=%d mutations=%d ready=%s\n',
            label,frames,solves-before,declares-dc,mutations,tostring(ready(host))))
        example.save(label..'-frame-'..frames,awesome._clay_tree(screen[1]))
        assert(frames<=12,'dependency did not settle: '..label)
    until ready(host)
    local settled_solves,settled_declares=solves-before,declares-dc
    output_solves=settled_declares
    local updates={}
    local function remember(n,check)
        for _,b in clay.bindings(n) do
            if b.grid_state then
                if check then assert(updates[b]==b.grid_state.updates,'stable helper requested update')
                else updates[b]=b.grid_state.updates end
            end
        end
        for _,c in ipairs(n.children or {}) do remember(c,check) end
    end
    remember(host._drawable._clay_tree)
    assert(awesome._test_redeclare()==0,'stable frame mutates scene')
    remember(host._drawable._clay_tree,true)
    io.stderr:write(string.format('[SETTLED] %s grid_callbacks=%d solves=%d declarations=%d frames=%d idle_callbacks=%d idle_declarations=%d idle_updates=0\n',
        label,settled_solves,output_solves,settled_declares,frames,solves-before-settled_solves,declares-dc-settled_declares))
end
local tidy=require('_clay_tidy')
local function grid()
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5
    g.minimum_column_width=20;g.minimum_row_height=20
    g.border_width=1;g.border_color='#ffffff';return g
end
local function pixel(host,g,x,y,color)
    local b=find(host,g);example.pixel(host.x+b.x+x,host.y+b.y+y,color)
end
local function geometry(host,g,w,h)
    local b=find(host,g);assert(b.width==w and b.height==h,string.format('expected %dx%d got %dx%d',w,h,b.width,b.height))
end
-- Independent fixed accepted geometry, rendered only as a test oracle.
local function accepted_pixels(host,g,custom,span)
    local cairo=require('lgi').cairo
    local width,height=custom and 67 or 63,custom and 65 or 63
    local surface=cairo.ImageSurface(cairo.Format.ARGB32,width,height)
    local cr=cairo.Context(surface)
    cr:set_source_rgb(1,1,1);cr:paint()
    if custom then
        cr:set_source_rgb(0,1,1);cr:set_line_width(3);cr:set_dash({4,2},1);cr:set_line_cap(cairo.LineCap.ROUND)
        cr:move_to(33.5,0);cr:line_to(33.5,height);cr:stroke()
    end
    local pad=custom and 7 or 6
    local secondx,secondy=custom and 40 or 37,custom and 38 or 37
    local areas=span and {{6,6,51,20,1,0,0},{6,37,20,20,0,1,0}}
        or {{pad,pad,20,20,1,0,0},{secondx,pad,20,20,0,1,0},
            {pad,secondy,20,20,0,0,1},{secondx,secondy,20,20,1,1,0}}
    for _,a in ipairs(areas) do
        cr:set_source_rgb(32/255,64/255,128/255);cr:rectangle(a[1]-5,a[2]-5,a[3]+10,a[4]+10);cr:fill()
        cr:set_source_rgb(a[5],a[6],a[7]);cr:rectangle(a[1],a[2],a[3],a[4]);cr:fill()
    end
    local cap=require('_widget_capture');local actual=require('gears.surface')(root.content());local box=find(host,g)
    for y=0,height-1 do for x=0,width-1 do
        local r,gg,b=cap.read(surface,x,y);local ar,ag,ab=cap.read(actual,host.x+box.x+x,host.y+box.y+y)
        assert(math.abs(r-ar)<=(custom and 4 or 0) and math.abs(gg-ag)<=(custom and 4 or 0) and math.abs(b-ab)<=(custom and 4 or 0),
            string.format('accepted full pixels (%d,%d) expected %d,%d,%d got %d,%d,%d',x,y,r,gg,b,ar,ag,ab))
    end end
    io.stderr:write(string.format('[PIXELS] accepted %dx%d span=%s every pixel matches independent oracle\n',width,height,tostring(span)))
end
runner.run_async(function()
    awesome.connect_signal('clay::declare',function() declares=declares+1 end)
    -- Run the exact three accepted creators and numerical/pixel/lookup oracles.
    local cases;local run=tidy.run;tidy.run=function(v) cases=v end
    require('test-clay-tidy-grid');tidy.run=run
    for _,case in ipairs(cases) do
        if case.name=='tidy-grid-borders' or case.name=='tidy-grid-custom-border' or case.name=='tidy-grid-border-span-hole' then
            local state=case.create();prepare(state.grid);settle(state.popup,case.name)
            case.verify(state,awesome._clay_tree(screen[1]))
            accepted_pixels(state.popup,state.grid,case.name=='tidy-grid-custom-border',case.name=='tidy-grid-border-span-hole')
            pixel(state.popup,state.grid,0,15,'#ffffff')
            pixel(state.popup,state.grid,15,3,'#204080')
            if case.name=='tidy-grid-border-span-hole' then
                pixel(state.popup,state.grid,31,15,'#ff0000')
                pixel(state.popup,state.grid,45,45,'#ffffff')
                pixel(state.popup,state.grid,35,45,'#ffffff')
            elseif case.name=='tidy-grid-borders' then
                pixel(state.popup,state.grid,31,15,'#ffffff')
                pixel(state.popup,state.grid,15,31,'#ffffff')
            end
            state.popup.visible=false
        end
    end
    local g=grid();local a,b,c,d=tidy.leaf(20,20,'#ff0000'),tidy.leaf(20,20,'#00ff00'),tidy.leaf(20,20,'#0000ff'),tidy.leaf(20,20,'#ffff00')
    g:add(a,b,c,d);prepare(g)
    local popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=g,bg='#204080'}
    settle(popup,'standard');geometry(popup,g,63,63)
    local _,ai=find(popup,a);local aid=ai.id
    a.forced_width=40;settle(popup,'size-grow');geometry(popup,g,103,63)
    a.forced_width=nil;settle(popup,'size-restore');geometry(popup,g,63,63)
    d.visible=false;settle(popup,'hide');pixel(popup,g,45,45,'#ffffff')
    assert(#solver.find(popup._drawable._clay_tree,d)==0)
    d.visible=true;settle(popup,'show');pixel(popup,g,45,45,'#ffff00')
    g:remove(d);settle(popup,'remove');pixel(popup,g,45,45,'#ffffff')
    g:add_widget_at(d,2,2);settle(popup,'reinsert');pixel(popup,g,45,45,'#ffff00')
    g.border_color={inner='#ff00ff',outer='#00ffff'};settle(popup,'colors')
    pixel(popup,g,0,15,'#00ffff');pixel(popup,g,31,15,'#ff00ff')
    local gradient={type='linear',from={0,0},to={63,0},stops={{0,'#ff0000'},{1,'#0000ff'}}}
    g.border_color={inner=gradient,outer=gradient};settle(popup,'gradient')
    local cairo=require('lgi').cairo;local oracle=cairo.ImageSurface(cairo.Format.ARGB32,63,63)
    local cr=cairo.Context(oracle);cr:set_source(require('gears.color')(gradient));cr:paint()
    local capture=require('_widget_capture')
    for _,point in ipairs{{0,15},{31,15},{15,31},{62,15}} do
        local r,gg,bb=capture.read(oracle,point[1],point[2])
        local gb=find(popup,g)
        local ar,ag,ab=capture.read(require('gears.surface')(root.content()),popup.x+gb.x+point[1],popup.y+gb.y+point[2])
        assert(math.abs(r-ar)<=1 and math.abs(gg-ag)<=1 and math.abs(bb-ab)<=1,'gradient source restarts at segment')
    end
    g.border_color='#ffffff';settle(popup,'colors-restore')
    g.border_width={inner=1,outer=2};g:add_column_border(2,3,{color='#00ffff',dashes={4,6},dash_offset=1,caps='butt'})
    settle(popup,'custom-butt');geometry(popup,g,67,65)
    pixel(popup,g,33,11,'#00ffff');pixel(popup,g,33,16,'#ffffff')
    for _,cap in ipairs{'round','square','butt','round','butt','square'} do
        g:add_column_border(2,3,{color='#00ffff',dashes={4,6},dash_offset=1,caps=cap})
        settle(popup,'custom-'..cap);pixel(popup,g,33,13,cap=='butt' and '#ffffff' or '#00ffff');pixel(popup,g,33,16,'#ffffff')
    end
    g:add_row_border(2,4,{color='#ff00ff',dashes={5,5},caps='butt'})
    settle(popup,'row-override');geometry(popup,g,67,68);pixel(popup,g,11,33,'#ff00ff')
    g:add_row_border(2,0,{});settle(popup,'zero-override');geometry(popup,g,67,59)
    g:add_row_border(2,nil,{});settle(popup,'nil-override');geometry(popup,g,67,65)
    g:add_column_border(2,nil,{});g.border_width=1;settle(popup,'style-restore');geometry(popup,g,63,63)
    g.border_width={inner=2,outer=0};settle(popup,'inner-only');geometry(popup,g,52,52)
    pixel(popup,g,0,0,'#ff0000');pixel(popup,g,25,10,'#ffffff')
    g.border_width={inner=0,outer=2};settle(popup,'outer-only');geometry(popup,g,59,59)
    pixel(popup,g,0,15,'#ffffff');pixel(popup,g,29,15,'#204080')
    g.border_width=0;settle(popup,'borders-off');geometry(popup,g,45,45)
    pixel(popup,g,22,10,'#204080');pixel(popup,g,0,10,'#ff0000')
    g.border_width=1;settle(popup,'borders-on');geometry(popup,g,63,63)
    assert(select(2,find(popup,a)).id==aid,'style mutation replaced original occurrence')
    g:remove(b);g:remove(a);g:add_widget_at(a,1,1,1,2);settle(popup,'column-span')
    pixel(popup,g,31,15,'#ff0000');pixel(popup,g,31,3,'#204080')
    g:add_column_border(2,3,{color='#00ffff'});settle(popup,'custom-span')
    geometry(popup,g,65,63);pixel(popup,g,32,15,'#ff0000');pixel(popup,g,32,45,'#00ffff')
    g:add_column_border(2,nil,{});settle(popup,'custom-span-restore')
    a.visible=false;settle(popup,'hidden-span');pixel(popup,g,31,15,'#ffffff');pixel(popup,g,15,15,'#ffffff')
    a.visible=true;settle(popup,'restored-span');pixel(popup,g,31,15,'#ff0000')
    g:remove(a);g:add_widget_at(a,1,1);g:add_widget_at(b,1,2);settle(popup,'span-restore')
    pixel(popup,g,31,15,'#ffffff')
    g:remove(c);g:remove(a);g:add_widget_at(a,1,1,2,1);settle(popup,'row-span')
    local ab,abind=find(popup,a)
    pixel(popup,g,15,31,'#ff0000');pixel(popup,g,3,31,'#204080')
    local calls={}
    for _,w in ipairs{g,a} do
        w:connect_signal('button::press',function(original,x,y,button,_,area)
            assert(original==w and area.widget==w and button==1)
            if w==a then assert(x==2 and y==ab.height-2 and area.occurrence==abind.id) end
            calls[#calls+1]=w
        end)
    end
    awful.spawn{pointer,'click',tostring(popup.x+ab.x+2),tostring(popup.y+ab.y+ab.height-2),'1280','720','left'}
    async.sleep(.2);assert(#calls==2 and calls[1]==g and calls[2]==a,'native grid/span pointer order')
    g:remove(d);settle(popup,'hole-input')
    for _,hit in ipairs(popup:find_widgets(45,45)) do assert(hit.widget~=a and hit.widget~=b and hit.widget~=c and hit.widget~=d,'hole acquired a cell target') end
    local stable=solves;async.sleep(.2);assert(solves==stable,'borders keep requesting frames')
    popup.visible=false
    -- Content/font and width dependencies with borders use natural-width,
    -- minimum-width and height measurement stages.
    g=grid();g.forced_width=100;g.expand={horizontal=true,vertical=false}
    local t=wibox.widget.textbox('aa aa aa aa');t.font='monospace 10';t.wrap='word';g:add(t,tidy.leaf(20,20,'#00ff00'));prepare(g)
    popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=g,bg='#204080'}
    settle(popup,'text');local height=find(popup,g).height
    t.text='aa aa aa aa aa aa aa aa';settle(popup,'content-grow');assert(find(popup,g).height>height)
    t.text='aa aa aa aa';settle(popup,'content-restore');assert(find(popup,g).height==height)
    t.font='monospace 18';settle(popup,'font-grow');assert(find(popup,g).height>height)
    t.font='monospace 10';settle(popup,'font-restore');assert(find(popup,g).height==height)
    g.forced_width=180;settle(popup,'width-grow');g.forced_width=100;settle(popup,'width-restore');assert(find(popup,g).height==height)
    stable=solves;async.sleep(.2);assert(solves==stable)
    popup.visible=false
    runner.done()
end)
