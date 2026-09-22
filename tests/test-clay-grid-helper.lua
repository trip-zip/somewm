-- Public grid compiler, bridge and text lifecycle with solved-stage counters.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local clay=require('wibox.clay')
local describe=wibox.layout.grid._clay.describe
local example=require('_clay_example')
local capture=require('_widget_capture')
local surface=require('gears.surface')
local function find(tree,w)
    for _,b in clay.bindings(tree) do if b.widget==w then return tree.box,b end end
    for _,c in ipairs(tree.children or {}) do local box,b=find(c,w);if box then return box,b end end
end
runner.run_async(function()
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5
    local traces,phase={},'initial'
    g._clay={describe=function(...)
        local node,why=describe(...)
        if not node then return node,why end
        local solved=node.solved
        node.solved=function(n)
            solved(n)
            local b,item=find(n,g)
            traces[#traces+1]={phase=phase,w=b.width,h=b.height,
                state=item.grid_state,columns=table.concat(item.grid_state.columns,',')}
            io.stderr:write(string.format('[SOLVE] %s %dx%d tracks=%s phase_solves=%d updates=%d\n',
                phase,b.width,b.height,traces[#traces].columns,item.grid_state.solves,item.grid_state.updates))
        end
        return node
    end}
    local a=wibox.container.background(nil,'#ff0000');a.forced_width=40;a.forced_height=10
    local b=wibox.container.background(nil,'#00ff00');b.forced_width=70;b.forced_height=10
    g:add(a,b)
    local popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,bg='#204080',widget=g}
    local declares=0
    local function declared() declares=declares+1 end
    awesome.connect_signal('clay::declare',declared)
    local function settle(label,width,height)
        phase=label
        local before,dc=#traces,declares
        local frames=0
        repeat
            awesome._test_redeclare();frames=frames+1
            local _,binding=find(popup._drawable._clay_tree,g)
            assert(frames<=3,'helper did not settle')
            if binding.grid_state.solves>=2 then break end
        until false
        assert(popup.width==width and popup.height==height,
            label..': unexpected popup '..popup.width..'x'..popup.height)
        local count=#traces-before
        assert(count==2,label..': expected natural/allocation solves, got '..count)
        local _,binding=find(popup._drawable._clay_tree,g)
        local updates=binding.grid_state.updates
        local settled_declares=declares-dc
        assert(awesome._test_redeclare()==0,label..': stable grid redeclared')
        assert(binding.grid_state.updates==updates,label..': stable grid requested an update')
        io.stderr:write(string.format('[SETTLED] %s solves=%d declare_passes=%d synchronous_frames=%d\n',
            label,count,settled_declares,frames))
        io.stderr:write(string.format('[FORCED IDLE] %s solves=%d declaration_updates=0\n',label,#traces-before-count))
    end
    settle('initial',145,10)
    local ab,ai=find(popup._drawable._clay_tree,a)
    local bb,bi=find(popup._drawable._clay_tree,b)
    local aid,bid=ai.id,bi.id
    assert(ab.width==70 and bb.width==70 and bb.x-ab.x==75)
    example.pixel(popup.x+2,popup.y+2,'#ff0000')
    example.pixel(popup.x+72,popup.y+2,'#204080')
    example.pixel(popup.x+77,popup.y+2,'#00ff00')
    example.save('helper-initial',awesome._clay_tree(screen[1]))
    a.forced_width=100;settle('a-grow',205,10)
    a.forced_width=40;settle('a-restore',145,10)
    b.forced_width=120;b.forced_height=30;settle('b-grow-tall',245,30)
    b.forced_width=70;b.forced_height=10;settle('b-restore',145,10)
    b.visible=false;settle('hide',85,10)
    for _,hit in ipairs(popup:find_widgets(47,2)) do assert(hit.widget~=b,'hidden input') end
    example.pixel(popup.x+47,popup.y+2,'#204080')
    b.visible=true;settle('reappear',145,10)
    assert(select(2,find(popup._drawable._clay_tree,a)).id==aid)
    assert(select(2,find(popup._drawable._clay_tree,b)).id==bid)
    g:remove(b);settle('remove',85,10)
    g:add_widget_at(b,1,2);settle('reinsert',145,10)
    local stable=#traces
    async.sleep(.2)
    assert(#traces==stable,'idle grid keeps scheduling layouts')
    -- Real text: native measurement, both-child mutation, font changes and
    -- removal/hiding. Preferred Pango sizes are an independent test oracle.
    local ta,tb=wibox.widget.textbox('mm'),wibox.widget.textbox('mmmmmmm')
    ta.font='monospace 12';tb.font='monospace 12'
    ta.wrap='word';tb.wrap='word'
    local function text_extent()
        local aw,ah=ta:get_preferred_size(screen[1]);local bw,bh=tb:get_preferred_size(screen[1])
        return math.max(aw,bw)*2+5,math.max(ah,bh)
    end
    g:reset();g:add(ta,tb)
    settle('text-initial',text_extent())
    ta.text='mmmmmmmmmmmm';settle('text-a-grow',text_extent())
    ta.text='mm';settle('text-a-restore',text_extent())
    tb.text='mmmmmmmmmmmmmmmm';settle('text-b-grow',text_extent())
    tb.text='mmmmmmm';settle('text-b-restore',text_extent())
    tb.font='monospace 20';settle('text-font-grow',text_extent())
    tb.font='monospace 12';settle('text-font-restore',text_extent())
    tb.visible=false
    local tw,th=ta:get_preferred_size(screen[1]);settle('text-hide',tw*2+5,th)
    tb.visible=true;settle('text-reappear',text_extent())
    g:remove(tb);settle('text-remove',tw*2+5,th)
    g:add_widget_at(tb,1,2);settle('text-reinsert',text_extent())
    local painted=0
    local im=surface(root.content())
    for y=popup.y,popup.y+popup.height-1 do
        for x=popup.x,popup.x+popup.width-1 do
            local r,green,blue=capture.read(im,x,y)
            if r~=32 or green~=64 or blue~=128 then painted=painted+1 end
        end
    end
    assert(painted>20,'text glyphs did not paint')
    example.save('helper-text',awesome._clay_tree(screen[1]))
    popup.visible=false
    g:reset();g:add(a,b);g.expand=true
    popup=wibox{screen=screen[1],x=100,y=100,width=200,height=80,
        visible=true,bg='#204080',widget=g}
    settle('rounding-200',200,80)
    ab=find(popup._drawable._clay_tree,a);bb=find(popup._drawable._clay_tree,b)
    assert(ab.width==97 and bb.width==97 and bb.x-ab.x==102)
    for _,hit in ipairs(popup:find_widgets(98,2)) do assert(hit.widget~=a and hit.widget~=b) end
    example.pixel(196,102,'#ff0000');example.pixel(197,102,'#204080')
    example.pixel(202,102,'#00ff00');example.pixel(299,102,'#204080')
    popup.width=201;settle('resize-201',201,80)
    ab=find(popup._drawable._clay_tree,a);assert(ab.width==98)
    popup.width=25;settle('resize-shortage',25,80)
    ab=find(popup._drawable._clay_tree,a);assert(ab.width==70)
    popup.width=200;settle('resize-restore',200,80)
    ab=find(popup._drawable._clay_tree,a);assert(ab.width==97)
    example.save('helper-rounding',awesome._clay_tree(screen[1]))
    awesome.disconnect_signal('clay::declare',declared)
    popup.visible=false
    io.stderr:write('[PASS] automatic shared sizing, growth/shrink/hide/remove/restore, real text/font, published boxes/pixels, bounded solves and stable idle\n')
    runner.done()
end)
