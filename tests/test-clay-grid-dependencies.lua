-- Public grid measurement: real text, spans, embedded/nested calendars.
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
        for _,b in clay.bindings(n) do if b.grid_state and not (b.grid_state.settled or (os.getenv('TASK19_BASELINE') and b.grid_state.columns)) then yes=false end end
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
local function text(value)
    local t=wibox.widget.textbox(value);t.font='monospace 10';t.wrap='word';t.ellipsize='none';return t
end
local function rows_fit(host,g,ws)
    local gb,gi=find(host,g)
    for _,w in ipairs(ws) do
        local b=find(host,w)
        local height=w:get_height_for_width(b.width,screen[1])
        assert(b.height>=height, string.format('wrapped height %d below oracle %d at width %d',b.height,height,b.width))
        assert(b.x+b.width<=gb.x+gb.width,'text cell exceeds grid width')
        assert(b.y+b.height<=gb.y+gb.height,'text cell exceeds grid height')
    end
    return gb,gi
end
runner.run_async(function()
    awesome.connect_signal('clay::declare',function() declares=declares+1 end)
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5
    g.homogeneous={horizontal=true,vertical=false};g.expand={horizontal=true,vertical=false};g.forced_width=90
    local ws={text('aa aa aa'),text('bb bb bb bb'),text('cc cc'),text('dd')}
    g:add((table.unpack or unpack)(ws));prepare(g)
    local popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=g,bg='#204080'}
    settle(popup,'wrap-initial');local initial=rows_fit(popup,g,ws).height
    assert(find(popup,ws[1]).width==42,'90/gap5 must allocate 42/42 plus remainder1')
    ws[2].text='bb bb bb bb bb bb bb bb bb';settle(popup,'wrap-grow')
    assert(rows_fit(popup,g,ws).height>initial)
    ws[2].text='bb bb bb bb';settle(popup,'wrap-restore');assert(rows_fit(popup,g,ws).height==initial)
    ws[2].font='monospace 18';settle(popup,'wrap-font-grow');assert(rows_fit(popup,g,ws).height>initial)
    ws[2].font='monospace 10';settle(popup,'wrap-font-restore');assert(rows_fit(popup,g,ws).height==initial)
    g.forced_width=210;settle(popup,'wrap-wide');assert(rows_fit(popup,g,ws).height<initial)
    g.forced_width=90;settle(popup,'wrap-narrow');assert(rows_fit(popup,g,ws).height==initial)
    popup.visible=false

    local span_grid=wibox.layout.grid();span_grid.column_count=2;span_grid.spacing=5
    span_grid.homogeneous={horizontal=true,vertical=false}
    span_grid.expand={horizontal=true,vertical=false};span_grid.forced_width=90
    local header=text('aa aa aa aa aa aa aa aa')
    local left,right=text('left'),text('right')
    span_grid:add_widget_at(header,1,1,1,2);span_grid:add_widget_at(left,2,1);span_grid:add_widget_at(right,2,2)
    prepare(span_grid)
    popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=span_grid,bg='#204080'}
    settle(popup,'wrapped-span-initial')
    local sh=rows_fit(popup,span_grid,{header,left,right}).height
    assert(find(popup,header).width==89,'spanning allocation loses internal gap/remainder')
    header.text='aa aa';settle(popup,'wrapped-span-shrink')
    assert(rows_fit(popup,span_grid,{header,left,right}).height<sh)
    header.text='aa aa aa aa aa aa aa aa';settle(popup,'wrapped-span-restore')
    assert(rows_fit(popup,span_grid,{header,left,right}).height==sh)
    popup.visible=false

    -- Native word minima remain floors under shortage; width growth releases
    -- wrapping height again without a content/font invalidation.
    local inner=wibox.layout.grid();inner.column_count=2;inner.spacing=5
    inner.homogeneous={horizontal=true,vertical=false};inner.expand={horizontal=true,vertical=false}
    local ta,tb=text('aa aa aa aa aa aa'),text('bb bb bb bb')
    inner:add(ta,tb)
    local embedding=wibox.container.margin(inner,3,3,2,2)
    local outer=wibox.layout.grid();outer.column_count=1;outer.spacing=5
    outer.homogeneous=false;outer.expand={horizontal=true,vertical=false};outer:add(embedding)
    prepare(outer)
    local host=wibox{screen=screen[1],x=100,y=100,width=96,height=400,visible=true,widget=outer,bg='#204080'}
    settle(host,'nested-wrap-initial')
    local ib=find(host,inner);local narrow=find(host,embedding).height
    assert(ib.width==90);rows_fit(host,inner,{ta,tb})
    host.width=216;settle(host,'nested-wrap-wide')
    assert(find(host,embedding).height<narrow,'outer retained narrow wrapped height')
    rows_fit(host,inner,{ta,tb})
    host.width=96;settle(host,'nested-wrap-narrow')
    assert(find(host,embedding).height==narrow,'nested height did not restore')
    rows_fit(host,inner,{ta,tb})
    host.width=15;settle(host,'nested-wrap-minimum')
    local _,ii=find(host,inner)
    assert(ii.grid_state.columns[1]>=14 and ii.grid_state.columns[2]>=14,'native word minima lost')
    assert(find(host,embedding).width>=39,'outer lost embedded minimum width')
    host.width=96;settle(host,'nested-wrap-minimum-restore')
    assert(find(host,embedding).height==narrow)
    tb.text='bb bb bb bb bb bb bb bb';settle(host,'nested-wrap-content-grow')
    assert(find(host,embedding).height>narrow)
    tb.text='bb bb bb bb';settle(host,'nested-wrap-content-restore')
    assert(find(host,embedding).height==narrow)
    tb.visible=false;settle(host,'nested-wrap-hide')
    assert(#solver.find(host._drawable._clay_tree,tb)==0)
    tb.visible=true;settle(host,'nested-wrap-show');assert(find(host,embedding).height==narrow)
    host.visible=false

    -- Row-spanning input remains in the original occurrence across the second
    -- row; the intentional hole beside it has no widget target.
    local spans=wibox.layout.grid();spans.column_count=3;spans.homogeneous=false;spans.spacing=5
    local red=wibox.container.background(nil,'#ff0000');red.forced_width=40;red.forced_height=55
    local green=wibox.container.background(nil,'#00ff00');green.forced_width=70;green.forced_height=20
    spans:add_widget_at(red,1,1,2,1);spans:add_widget_at(green,1,2);prepare(spans)
    popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=spans,bg='#204080'}
    settle(popup,'row-span-input')
    local rb,ri=find(popup,red);local rid=ri.id
    local hits=popup:find_widgets(rb.x+2,rb.y+rb.height-2)
    local parent_index,child_index
    for i,hit in ipairs(hits) do
        if hit.widget==spans then parent_index=i end
        if hit.widget==red then child_index=i;assert(hit.occurrence==rid) end
    end
    assert(parent_index and child_index and parent_index<child_index,'row-span parent/child input order')
    example.pixel(popup.x+rb.x+2,popup.y+rb.y+rb.height-2,'#ff0000')
    local calls={}
    for _,w in ipairs{spans,red} do
        w:connect_signal('button::press',function(original,x,y,button,_,area)
            assert(original==w and area.widget==w and button==1)
            assert(x==2 and y==rb.height-2,'row-span local pointer coordinates')
            calls[#calls+1]=w
        end)
    end
    awful.spawn{pointer,'click',tostring(popup.x+rb.x+2),tostring(popup.y+rb.y+rb.height-2),'1280','720','left'}
    async.sleep(.2)
    assert(#calls==2 and calls[1]==spans and calls[2]==red,'real row-span pointer ordering')
    for _,hit in ipairs(popup:find_widgets(50,40)) do assert(hit.widget~=red and hit.widget~=green,'hole input target') end
    red.forced_height=95;settle(popup,'row-span-grow');assert(find(popup,red).height>=95)
    red.forced_height=55;settle(popup,'row-span-restore');assert(find(popup,red).height==rb.height)
    assert(select(2,find(popup,red)).id==rid)
    popup.visible=false

    -- Actual month and year constructors, including their own full-width header,
    -- holes, week numbers, automatic rows and the year's four by three months.
    local function calendar(kind)
        local cal=wibox.widget.calendar[kind]({year=2026,month=9,day=16},'monospace 10')
        cal.spacing=3;cal.week_numbers=true
        cal.fn_embed=function(w,flag)
                if flag=='monthheader' or flag=='header' or flag=='fullheader' then
                    return wibox.container.margin(w,2,2,2,2)
                end
                return w
            end
        prepare(cal);return cal
    end
    local month=calendar('month')
    popup=awful.popup{screen=screen[1],x=30,y=30,visible=true,widget=month,bg='#204080'}
    settle(popup,'month-initial')
    local mh=popup.height;assert(mh>100)
    local function header_text(w)
        if w.set_text then return w end
        for _,c in ipairs(children(w)) do local t=header_text(c);if t then return t end end
    end
    local mt=assert(header_text(month));local old=mt.text;local mw=popup.width
    mt.text='A substantially longer localized month heading'
    settle(popup,'month-content-grow');assert(popup.width>mw)
    mt.text=old;settle(popup,'month-content-restore');assert(popup.width==mw and popup.height==mh)
    month.font='monospace 16';prepare(month);settle(popup,'month-font-grow');assert(popup.height>mh)
    month.font='monospace 10';prepare(month);settle(popup,'month-font-restore');assert(popup.height==mh)
    popup.visible=false
    local year=calendar('year')
    popup=awful.popup{screen=screen[1],x=0,y=0,visible=true,widget=year,bg='#204080',maximum_width=1100}
    settle(popup,'year-initial')
    local yh=popup.height
    local grids={}
    local function collect(w)
        if w._private.widgets and w._private.num_cols then grids[#grids+1]=w end
        for _,c in ipairs(children(w)) do collect(c) end
    end
    collect(year);assert(#grids==13,'expected outer grid plus twelve months')
    assert(grids[1]._private.num_cols==4 and grids[1]._private.num_rows==3)
    local outer=find(popup,grids[1])
    for i=2,13 do
        local b=find(popup,grids[i]);assert(b.height>100)
        assert(b.y+b.height<=outer.y+outer.height,'nested month overflows outer grid')
        for _,item in ipairs(grids[i]._private.widgets) do
            assert(#solver.find(popup._drawable._clay_tree,item.widget)==1,'month occurrence duplicated or missing')
        end
        local header=grids[i]._private.widgets[1]
        assert(header.col_span==grids[i]._private.num_cols,'month header must span all columns')
        local hb=find(popup,header.widget)
        assert(hb.width<=b.width and hb.width> b.width-8,'month header does not span allocated tracks')
    end
    year.font='monospace 14';prepare(year);settle(popup,'year-font-grow');assert(popup.height>yh)
    year.font='monospace 10';prepare(year);settle(popup,'year-font-restore');assert(popup.height==yh)
    year.forced_width=900;settle(popup,'year-wide')
    year.forced_width=550;settle(popup,'year-narrow')
    year.forced_width=nil;settle(popup,'year-width-restore');assert(popup.height==yh)
    year.week_numbers=false;prepare(year);settle(popup,'year-no-week-numbers')
    year.week_numbers=true;prepare(year);settle(popup,'year-week-numbers-restore');assert(popup.height==yh)
    year.flex_height=true;prepare(year);settle(popup,'year-flex')
    year.flex_height=false;prepare(year);settle(popup,'year-flex-restore');assert(popup.height==yh)
    local stable=solves;async.sleep(.2);assert(solves==stable,'idle grids keep scheduling')
    popup.visible=false
    io.stderr:write('[PASS] wrapped heights, growth/shrink/font/width, actual embedded month and 4x3 year\n')
    runner.done()
end)
