-- Public grid overlap: native geometry, paint, publication and real input.
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
local function geometry(host,w,x,y,width,height)
    local b=find(host,w)
    assert(b.x==x and b.y==y and b.width==width and b.height==height,
        string.format('geometry expected %d,%d %dx%d got %d,%d %dx%d',x,y,width,height,b.x,b.y,b.width,b.height))
end
local function pixel(host,x,y,color) example.pixel(host.x+x,host.y+y,color) end
local function floats(host,w)
    return solver.find(host._drawable._clay_tree,w)
end
local function attach(host,w,class)
    local n=floats(host,w)[1].node
    assert(n.float and n._attach and n._attach.spacer)
    assert(not n._attach.bindings and not n._attach.bg and not n._attach.shape)
    if class then assert(n._attach.class==class) else assert(n._attach._settle) end
    return n._attach
end
runner.run_async(function()
    awesome.connect_signal('clay::declare',function() declares=declares+1 end)
    local cases;local run=tidy.run;tidy.run=function(v) cases=v end
    require('test-clay-tidy-grid');tidy.run=run
    for _,case in ipairs(cases) do if case.name=='tidy-grid-native-overlap' then
        local state=case.create();prepare(state.grid);settle(state.popup,'accepted-overlap')
        case.verify(state,awesome._clay_tree(screen[1]))
        local gb=find(state.popup,state.grid);local ob=find(state.popup,state.widgets[3])
        assert(gb.width==115 and gb.height==20 and ob.x-gb.x==45 and ob.y==gb.y and ob.width==200 and ob.height==60)
        attach(state.popup,state.widgets[3]);pixel(state.popup,gb.x+50,gb.y+2,'#0000ff')
        state.popup.visible=false
    end end
    local g=wibox.layout.grid();g.column_count=2;g.row_count=2;g.spacing=5
    g.homogeneous=false;g.superpose=true;g.minimum_row_height=20
    local a,b=tidy.leaf(40,20,'#ff0000'),tidy.leaf(70,20,'#00ff00')
    g:add(a,b);prepare(g)
    local host=wibox{screen=screen[1],x=100,y=100,width=300,height=100,visible=true,ontop=true,bg='#204080',widget=g}
    settle(host,'base')
    local aid,bid=select(2,find(host,a)).id,select(2,find(host,b)).id
    local o=tidy.leaf(200,60,'#0000ff');g:add_widget_at(o,1,2)
    settle(host,'insert');geometry(host,a,0,0,40,20);geometry(host,b,45,0,70,20);geometry(host,o,45,0,200,60);attach(host,o)
    local oid=select(2,find(host,o)).id
    o.forced_width=250;o.forced_height=80;settle(host,'overlay-grow');geometry(host,b,45,0,70,20)
    o.forced_width=nil;o.forced_height=nil;settle(host,'overlay-restore');geometry(host,o,45,0,200,60)
    o.visible=false;settle(host,'hide');assert(#floats(host,o)==0);pixel(host,50,5,'#00ff00')
    o.visible=true;settle(host,'show');assert(select(2,find(host,o)).id==oid)
    g:remove(o);settle(host,'remove');pixel(host,50,5,'#00ff00')
    g:add_widget_at(o,1,2);settle(host,'reinsert')
    -- Mutate logical spans without replacing the authored occurrence.
    local function span(r,c,rs,cs)
        local item=g._private.widgets[#g._private.widgets]
        item.row,item.col,item.row_span,item.col_span=r,c,rs,cs
        g:emit_signal('widget::layout_changed')
    end
    oid=select(2,find(host,o)).id
    span(1,1,2,2);settle(host,'span');attach(host,o,'grid.span-area');geometry(host,o,0,0,200,60)
    assert(select(2,find(host,o)).id==oid)
    span(1,2,2,1);settle(host,'row-span');attach(host,o,'grid.span-area');geometry(host,o,45,0,200,60)
    span(1,2,1,1);settle(host,'span-restore');attach(host,o)
    host.width=400;settle(host,'resize');geometry(host,o,45,0,200,60)
    host.width=300;settle(host,'resize-restore');geometry(host,b,45,0,70,20)
    assert(select(2,find(host,a)).id==aid and select(2,find(host,b)).id==bid)
    -- Repeated references stay distinct, and later authored floats paint last
    -- even when their target precedes another target in row-major order.
    local top=tidy.leaf(100,35,'#ffff00');g:add_widget_at(top,1,1)
    settle(host,'reverse-anchor-order');pixel(host,50,5,'#ffff00')
    g:add_widget_at(top,1,2);settle(host,'repeated')
    local repeated=floats(host,top);assert(#repeated==2 and repeated[1].binding.id~=repeated[2].binding.id)
    assert(repeated[1].box.x==0 and repeated[2].box.x==45)
    local known={[g]=true,[a]=true,[b]=true,[o]=true,[top]=true}
    local calls,releases={},{}
    local clickx,clicky=50,5
    for w in pairs(known) do
        for _,event in ipairs{'button::press','button::release'} do
            w:connect_signal(event,function(original,x,y,button,_,area)
                assert(original==w and area.widget==w and button==1)
                assert(x==clickx-area.x and y==clicky-area.y,'pointer and published coordinates disagree')
                local list=event=='button::press' and calls or releases
                list[#list+1]=area.occurrence
            end)
        end
    end
    local function hits(x,y)
        local ids={}
        for _,hit in ipairs(host:find_widgets(x,y)) do
            assert(known[hit.widget],'anchor introduced an input target')
            ids[#ids+1]=hit.occurrence
        end
        return ids
    end
    local function click(x,y)
        clickx,clicky=x,y;calls={};releases={}
        local expected=hits(x,y)
        awful.spawn{pointer,'click',tostring(host.x+x),tostring(host.y+y),'1280','720','left'}
        async.sleep(.2)
        assert(table.concat(expected,',')==table.concat(calls,','),'real press disagrees with native lookup')
        assert(table.concat(expected,',')==table.concat(releases,','),'real release disagrees with native lookup')
        io.stderr:write('[INPUT] '..phase..' occurrences='..table.concat(expected,',')..' real press/release agree\n')
        return expected
    end
    local pass=click(50,5);assert(#pass==5,'passthrough must include grid, base, overlay and repeated occurrences')
    local describe=top._clay.describe
    local capture=false;local ox,oy=0,0
    top._clay={describe=function(...)
        local n=describe(...);n.passthrough=not capture;n.x=ox;n.y=oy;return n
    end}
    capture=true;top:emit_signal('widget::layout_changed');settle(host,'capture')
    local captured=click(50,5);assert(#captured==1 and captured[1]==floats(host,top)[2].binding.id,'native capture must stop at the top floating root')
    capture=false;ox=-55;oy=-10;top:emit_signal('widget::layout_changed');settle(host,'negative-offsets')
    repeated=floats(host,top);assert(repeated[2].box.x==-10 and repeated[2].box.y==-10)
    pixel(host,0,0,'#ffff00');click(2,2)
    -- Outside-host input goes through real scene picking. The verification
    -- build's direct lookup API requires a point already picked on its host.
    calls={};releases={}
    awful.spawn{pointer,'click',tostring(host.x-2),tostring(host.y+2),'1280','720','left'}
    async.sleep(.2);assert(#calls==0 and #releases==0,'negative float receives clipped outside input')
    local cap=require('_widget_capture');local im=require('gears.surface')(root.content())
    local r,gg,bb=cap.read(im,host.x-2,host.y+2);assert(not(r==255 and gg==255 and bb==0),'negative float paints outside host clip')
    ox=0;oy=0;top:emit_signal('widget::layout_changed');settle(host,'offset-restore')
    g:remove(top);g:remove(top);settle(host,'remove-repeated')
    -- A span anchor must neither erase borders/holes nor capture a pointer.
    o.visible=false;g.border_width=1;g.border_color='#ffffff';span(1,1,2,2)
    settle(host,'border-hidden-span');pixel(host,51,15,'#ffffff');pixel(host,80,45,'#ffffff')
    assert(#hits(80,45)==1,'empty span area acquired a target')
    o.visible=true;settle(host,'border-span-show');attach(host,o,'grid.span-area')
    geometry(host,a,6,6,40,20);geometry(host,b,57,6,70,20);geometry(host,o,6,6,200,60)
    pixel(host,51,15,'#0000ff');pixel(host,80,45,'#0000ff')
    o.visible=false;settle(host,'border-span-hide');pixel(host,51,15,'#ffffff');pixel(host,80,45,'#ffffff')
    g:add_column_border(2,3,{color='#00ffff',dashes={4,2},caps='round'})
    settle(host,'custom-border-hidden');pixel(host,52,11,'#00ffff')
    o.visible=true;settle(host,'custom-border-show');pixel(host,52,11,'#0000ff')
    g:remove(o);settle(host,'border-span-remove');pixel(host,52,11,'#00ffff')
    g:add_widget_at(o,1,1,2,2);settle(host,'border-span-reinsert')
    attach(host,o,'grid.span-area');click(8,8)
    g:add_widget_at(o,1,1,2,2);settle(host,'repeated-span')
    local shared=floats(host,o);assert(#shared==2 and shared[1].node._attach==shared[2].node._attach)
    assert(shared[1].binding.id~=shared[2].binding.id)
    g:remove(o);g:remove(o);settle(host,'repeated-span-remove')
    -- Reuse the same object as an in-flow and an overlaid occurrence.
    g:add_widget_at(a,1,2);settle(host,'flow-and-overlay')
    shared=floats(host,a);assert(#shared==2 and not shared[1].node.float and shared[2].node.float)
    assert(shared[1].binding.id==aid and shared[1].binding.id~=shared[2].binding.id)
    g:remove(a);g:remove(a);g:add_widget_at(a,1,1);settle(host,'flow-restore')
    local stable,idle_declares=solves,declares;async.sleep(.25);assert(stable==solves and idle_declares==declares,'stable overlap keeps scheduling updates')
    io.stderr:write('[TIMER IDLE] overlap callbacks=0 declarations=0\n')
    g:add_widget_at(o,1,1,2,2);settle(host,'inspector-span')
    screen[1].inspector=true;awesome._test_redeclare();example.save('overlap-inspector',awesome._clay_tree(screen[1]));screen[1].inspector=false
    host.visible=false
    -- Wrapped/nested overlay dependencies settle independently without ever
    -- becoming grid sizing samples.
    g=wibox.layout.grid();g.column_count=2;g.spacing=5;g.homogeneous=false;g.superpose=true
    a,b=tidy.leaf(40,20,'#ff0000'),tidy.leaf(70,20,'#00ff00');g:add(a,b)
    local inner=wibox.layout.grid();inner.column_count=1
    local text=wibox.widget.textbox('aa aa aa aa aa aa aa');text.font='monospace 10';text.wrap='word'
    inner:add(text);inner.forced_width=70
    g:add_widget_at(inner,1,2);prepare(g)
    host=awful.popup{screen=screen[1],x=100,y=100,visible=true,bg='#204080',widget=g}
    settle(host,'nested-overlay');geometry(host,g,0,0,115,20)
    local th=find(host,inner).height;assert(th==text:get_height_for_width(70,screen[1]) and th>20)
    text.text='aa aa aa aa aa aa aa aa aa aa aa aa aa aa';settle(host,'nested-overlay-content')
    geometry(host,g,0,0,115,20);assert(find(host,inner).height==text:get_height_for_width(70,screen[1]) and find(host,inner).height>th)
    text.text='aa aa aa aa aa aa aa';settle(host,'nested-overlay-restore')
    geometry(host,g,0,0,115,20);assert(find(host,inner).height==th)
    text.font='monospace 16';settle(host,'nested-overlay-font');geometry(host,g,0,0,115,20)
    text.font='monospace 10';settle(host,'nested-overlay-font-restore');assert(find(host,inner).height==th)
    b.forced_width=100;settle(host,'base-grow-under-overlay');geometry(host,g,0,0,145,20)
    b.forced_width=nil;settle(host,'base-restore-under-overlay');geometry(host,g,0,0,115,20)
    stable,idle_declares=solves,declares;async.sleep(.25)
    io.stderr:write(string.format('[TIMER DRAIN] nested overlay callbacks=%d declarations=%d\n',solves-stable,declares-idle_declares))
    assert(stable==solves,'nested overlay keeps requesting helper updates')
    idle_declares=declares;async.sleep(.25)
    assert(stable==solves and idle_declares==declares,'nested overlay keeps scheduling updates')
    io.stderr:write('[TIMER IDLE] nested overlay callbacks=0 declarations=0\n')
    host.visible=false
    -- Bridge references are local, earlier declarations; malformed references
    -- are rejected before anything can use an old generation's index.
    local raw=drawin{width=10,height=10}
    local target={w=10,h=10,spacer=true}
    local function rejected(tree)
        local ok,why=raw.drawable:_clay_nodes(tree)
        assert(not ok and why=='malformed','invalid attachment was admitted: '..tostring(why))
    end
    rejected{w=10,h=10,children={{w=10,h=10,float=true,_attach=target},target}}
    rejected{w=10,h=10,children={{w=10,h=10,float=true,_attach={}}}}
    rejected{w=10,h=10,children={target,{w=10,h=10,_attach=target}}}
    runner.done()
end)
