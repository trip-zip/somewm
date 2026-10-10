-- Public membership mutations must update the same occurrences, pixels and hits.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
local colors={}
local function leaf(color)
    local w=wibox.container.background(nil,color)
    w.forced_width=20;w.forced_height=10
    colors[w]=color
    return w
end
runner.run_async(function()
    local g=wibox.layout.grid()
    g.spacing=5;g.minimum_row_height=10
    local a,b,c=leaf('#ff0000'),leaf('#00ff00'),leaf('#0000ff')
    g:add(a,b)
    local host=awful.popup{screen=screen[1],placement=awful.placement.top_left,offset={x=100,y=100},visible=true,bg='#204080',widget=g}
    local ids={}
    local function find(w,x,y)
        for _,area in ipairs(host:find_widgets(x,y)) do
            if area.widget==w then return area end
        end
    end
    -- Each expected entry: widget, x, y, width, height, and for a repeated
    -- widget the occurrence index it stands for.
    local function frame(label,expected)
        awesome._test_redeclare()
        assert(awesome._clay_tree(screen[1]):match('roots flow 1 floating %d+ derived 0 '),label..': derived size')
        for _,e in ipairs(expected) do
            local area=assert(find(e[1],e[2]+2,e[3]+2),label..': native lookup')
            assert(area.x==e[2] and area.y==e[3] and area.width==e[4] and area.height==e[5],
                label..': box '..table.concat({area.x,area.y,area.width,area.height},','))
            ids[e[1]]=ids[e[1]] or {}
            local seen=ids[e[1]][e[6] or 1]
            if seen then assert(area.occurrence==seen,label..': occurrence changed') end
            ids[e[1]][e[6] or 1]=area.occurrence
            example.pixel(host.x+e[2]+2,host.y+e[3]+2,colors[e[1]])
        end
        assert(awesome._test_redeclare()==0,label..': unstable scene')
        example.save(label,awesome._clay_tree(screen[1]))
        io.stderr:write('[PUBLIC] '..label..' geometry pixels lookup identity idle PASS\n')
    end
    local function hole(x,y)
        for _,hit in ipairs(host:find_widgets(x,y)) do
            assert(hit.widget~=a and hit.widget~=b and hit.widget~=c,'hole acquired a child target')
        end
        example.pixel(host.x+x,host.y+y,'#204080')
    end
    frame('initial',{{a,0,0,20,10},{b,0,15,20,10}})
    assert(g:get_widget_position(b).row==2)
    assert(g:insert_row(2)==2)
    frame('insert-row',{{a,0,0,20,10},{b,0,30,20,10}});hole(2,17)
    assert(g:remove_row(2)==2)
    frame('remove-row',{{a,0,0,20,10},{b,0,15,20,10}})
    assert(g:extend_row(1)==1)
    -- A row span occupies its first row only.
    frame('extend-row',{{a,0,0,20,10},{b,0,30,20,10}})
    assert(g:get_widget_position(a).row_span==2)
    g:remove_row(2)
    frame('restore-row',{{a,0,0,20,10},{b,0,15,20,10}})
    g:insert_column(1)
    frame('insert-column',{{a,5,0,20,10},{b,5,15,20,10}});hole(2,2)
    g:remove_column(1)
    frame('remove-column',{{a,0,0,20,10},{b,0,15,20,10}})
    g:extend_column(1)
    -- A column span is one cell around its content.
    frame('extend-column',{{a,0,0,20,10},{b,0,15,20,10}})
    assert(g:get_widget_position(a).col_span==2)
    g:remove_column(2)
    frame('restore-column',{{a,0,0,20,10},{b,0,15,20,10}})
    assert(g:replace_widget(a,c))
    frame('replace',{{c,0,0,20,10},{b,0,15,20,10}})
    assert(g:get_widget_position(a)==nil and g:get_widgets_at(1,1)[1]==c)
    assert(g:remove_widgets_at(1,1))
    frame('remove-at',{{b,0,15,20,10}});hole(2,2)
    assert(g:add_widget_at(c,1,1));ids[c]=nil
    frame('reinsert',{{c,0,0,20,10},{b,0,15,20,10}})
    c.visible=false
    frame('hidden',{{b,0,15,20,10}});hole(2,2)
    assert(g:get_widgets_at(1,1)[1]==c,'logical lookup must retain hidden membership')
    c.visible=true
    frame('restored',{{c,0,0,20,10},{b,0,15,20,10}})
    g.column_count=3;g.row_count=3
    frame('forced-counts',{{c,0,0,20,10},{b,0,15,20,10}})
    assert(host.width==30 and host.height==40)
    g.column_count=nil;g.row_count=nil
    g.orientation='horizontal';assert(g.orientation=='horizontal')
    g:add(a);ids[a]=nil
    assert(g:get_widget_position(a).row==1 and g:get_widget_position(a).col==2)
    frame('horizontal-add',{{c,0,0,20,10},{b,0,15,20,10},{a,25,0,20,10}})
    g:add_widget_at(c,2,2)
    frame('repeated',{{c,0,0,20,10,1},{c,25,15,20,10,2},{b,0,15,20,10},{a,25,0,20,10}})
    local first,second=ids[c][1],ids[c][2]
    assert(first~=second)
    -- Hidden, both of c's cells are empty columns and take no width.
    c.visible=false;awesome._test_redeclare();hole(2,2)
    for _,hit in ipairs(host:find_widgets(27,17)) do assert(hit.widget~=c,'hidden occurrence acquired a target') end
    c.visible=true
    frame('repeated-restored',{{c,0,0,20,10,1},{c,25,15,20,10,2}})
    local calls={}
    for _,w in ipairs{g,c} do
        w:connect_signal('button::press',function(original,x,y,button,_,area)
            assert(original==w and area.widget==w and button==1)
            assert(x==(w==g and 27 or 2) and y==(w==g and 17 or 2))
            if w==c then assert(area.occurrence==second) end
            calls[#calls+1]=w
        end)
    end
    awful.spawn{pointer,'click','127','117','1280','720','left'}
    assert(async.wait_for_condition(function() return #calls==2 end,2,.01))
    assert(calls[1]==g and calls[2]==c)
    g:reset();ids={}
    frame('empty',{})
    assert(not find(g,0,0),'zero-area grid has a pointer target')
    g.forced_width=40;g.forced_height=25
    frame('empty-forced',{})
    local forced=assert(find(g,2,2),'authored empty allocation must remain a pointer target')
    assert(forced.width==40 and forced.height==25)
    g.forced_width=nil;g.forced_height=nil
    g:set_children{a,b};g.column_count=2
    frame('set-children',{{a,0,0,20,10},{b,25,0,20,10}})
    local published=0
    host.drawable:connect_signal('clay::solved',function() published=published+1 end)
    async.sleep(.25)
    assert(published==0,'stable grid keeps publishing')
    host.visible=false
    runner.done()
end)
