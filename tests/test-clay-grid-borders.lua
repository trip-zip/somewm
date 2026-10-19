-- Grid borders declared at the cell from authored widths: geometry, paint,
-- mutation, warnings and real pointer checks, each in one frame.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')
local capture=require('_widget_capture')
local gsurface=require('gears.surface')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
local tidy=require('_clay_tidy')
local function warnings(text)
    local path=assert(os.getenv('SOMEWM_TEST_LOG'),'SOMEWM_TEST_LOG is not set')
    local log=assert(io.open(path,'r'))
    local count=0
    for line in log:lines() do if line:find(text,1,true) then count=count+1 end end
    log:close()
    return count
end
local function frame(label)
    awesome._test_redeclare()
    local dump=awesome._clay_tree(screen[1])
    assert(dump:match('roots flow 1 floating %d+ derived 0 '),label..': derived size')
    assert(awesome._test_redeclare()==0,label..': the next frame changed the scene')
    example.save(label,dump)
end
local function hit(host,w,x,y)
    for _,h in ipairs(host:find_widgets(x,y)) do if h.widget==w then return h end end
end
local function grid_box(host)
    return assert(hit(host,host.widget,1,1),'grid has no solved box')
end
local function geometry(host,w,h)
    local b=grid_box(host)
    assert(b.width==w and b.height==h,string.format('expected %dx%d got %dx%d',w,h,b.width,b.height))
end
local function pixel(host,x,y,color)
    local b=grid_box(host);example.pixel(host.x+b.x+x,host.y+b.y+y,color)
end
-- Independent oracle: rectangles painted in order over the popup colour,
-- compared with every pixel of the grid's box.
local white,cyan,bg={1,1,1},{0,1,1},{32/255,64/255,128/255}
local leaves={{1,0,0},{0,1,0},{0,0,1},{1,1,0}}
local function oracle(host,width,height,rects)
    local cairo=require('lgi').cairo
    local surface=cairo.ImageSurface(cairo.Format.ARGB32,width,height)
    local cr=cairo.Context(surface)
    cr:set_source_rgb(bg[1],bg[2],bg[3]);cr:paint()
    for _,r in ipairs(rects) do
        cr:set_source_rgb(r[5][1],r[5][2],r[5][3]);cr:rectangle(r[1],r[2],r[3],r[4]);cr:fill()
    end
    local actual=gsurface(root.content());local box=grid_box(host)
    for y=0,height-1 do for x=0,width-1 do
        local r,g,b=capture.read(surface,x,y)
        local ar,ag,ab=capture.read(actual,host.x+box.x+x,host.y+box.y+y)
        assert(r==ar and g==ag and b==ab,
            string.format('oracle pixel (%d,%d) expected %d,%d,%d got %d,%d,%d',x,y,r,g,b,ar,ag,ab))
    end end
    io.stderr:write(string.format('[PIXELS] %dx%d every pixel matches the oracle\n',width,height))
end
local oracles={
    ['tidy-grid-borders']={63,63,{{0,0,1,63,white},{0,0,63,1,white},{31,0,1,63,white},
        {0,31,63,1,white},{62,0,1,63,white},{0,62,63,1,white},
        {6,6,20,20,leaves[1]},{37,6,20,20,leaves[2]},{6,37,20,20,leaves[3]},{37,37,20,20,leaves[4]}}},
    -- The span is its content wide; the hole is its padding wide and is filled.
    ['tidy-grid-border-span-hole']={43,63,{{0,0,1,63,white},{0,0,32,1,white},{31,0,1,31,white},
        {0,31,43,1,white},{31,31,12,32,white},{0,62,31,1,white},
        {6,6,20,20,leaves[1]},{6,37,20,20,leaves[2]}}},
    -- The dashed column border is drawn as a solid line inside the outer
    -- and row borders around it.
    ['tidy-grid-custom-border']={67,65,{{0,0,2,65,white},{0,0,67,2,white},{65,0,2,65,white},
        {0,63,67,2,white},{0,32,67,1,white},{32,2,3,30,cyan},{32,33,3,30,cyan},
        {7,7,20,20,leaves[1]},{40,7,20,20,leaves[2]},{7,38,20,20,leaves[3]},{40,38,20,20,leaves[4]}}},
}
runner.run_async(function()
    -- The three accepted tidy fixtures, with their numerical and pixel oracles.
    local cases;local run=tidy.run;tidy.run=function(v) cases=v end
    require('test-clay-tidy-grid');tidy.run=run
    for _,case in ipairs(cases) do
        local expected=oracles[case.name]
        if expected then
            local state=case.create();frame(case.name)
            case.verify(state,awesome._clay_tree(screen[1]))
            oracle(state.popup,expected[1],expected[2],expected[3])
            state.popup.visible=false
        end
    end
    assert(warnings('wibox.layout.grid dashes is drawn as a solid line')==1,'dashes warned more or less than once')
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5
    g.minimum_row_height=20
    g.border_width=1;g.border_color='#ffffff'
    local a,b,c,d=tidy.leaf(20,20,'#ff0000'),tidy.leaf(20,20,'#00ff00'),tidy.leaf(20,20,'#0000ff'),tidy.leaf(20,20,'#ffff00')
    g:add(a,b,c,d)
    local popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=g,bg='#204080'}
    frame('standard');geometry(popup,63,63)
    local aid=hit(popup,a,10,10).occurrence
    -- Columns follow each row's content: only the first row widens.
    a.forced_width=40;frame('size-grow');geometry(popup,83,63)
    a.forced_width=nil;frame('size-restore');geometry(popup,63,63)
    -- An empty cell takes no width beyond its padding, and is filled.
    d.visible=false;frame('hide');pixel(popup,37,45,'#ffffff')
    assert(not hit(popup,d,45,45))
    d.visible=true;frame('show');pixel(popup,45,45,'#ffff00')
    g:remove(d);frame('remove');pixel(popup,37,45,'#ffffff')
    g:add_widget_at(d,2,2);frame('reinsert');pixel(popup,45,45,'#ffff00')
    g.border_color={inner='#ff00ff',outer='#00ffff'};frame('colors')
    pixel(popup,0,15,'#00ffff');pixel(popup,31,15,'#ff00ff');pixel(popup,15,31,'#ff00ff')
    local gradient={type='linear',from={0,0},to={63,0},stops={{0,'#ff0000'},{1,'#0000ff'}}}
    g.border_color={inner=gradient,outer=gradient};frame('gradient')
    pixel(popup,0,15,'#204080');pixel(popup,31,15,'#204080')
    assert(warnings('wibox.layout.grid border_color is not a solid color and is transparent')==1)
    g.border_color='#ffffff';frame('colors-restore');pixel(popup,0,15,'#ffffff')
    g.border_width={inner=1,outer=2};g:add_column_border(2,3,{color='#00ffff',dashes={4,6},dash_offset=1,caps='butt'})
    frame('custom-dashes');geometry(popup,67,65)
    pixel(popup,33,11,'#00ffff');pixel(popup,33,16,'#00ffff')
    g:add_row_border(2,4,{color='#ff00ff'})
    frame('row-override');geometry(popup,67,68);pixel(popup,11,33,'#ff00ff')
    g:add_row_border(2,0,{});frame('zero-override');geometry(popup,67,59)
    g:add_row_border(2,nil,{});frame('nil-override');geometry(popup,67,65)
    g:add_column_border(2,nil,{});g.border_width=1;frame('style-restore');geometry(popup,63,63)
    g.border_width={inner=2,outer=0};frame('inner-only');geometry(popup,52,52)
    pixel(popup,0,0,'#ff0000');pixel(popup,25,10,'#ffffff')
    g.border_width={inner=0,outer=2};frame('outer-only');geometry(popup,59,59)
    pixel(popup,0,15,'#ffffff');pixel(popup,29,15,'#204080')
    g.border_width=0;frame('borders-off');geometry(popup,45,45)
    pixel(popup,22,10,'#204080');pixel(popup,0,10,'#ff0000')
    g.border_width=1;frame('borders-on');geometry(popup,63,63)
    assert(hit(popup,a,10,10).occurrence==aid,'style mutation replaced original occurrence')
    -- A column span is one cell around its content.
    g:remove(b);g:remove(a);g:add_widget_at(a,1,1,1,2);frame('column-span')
    assert(hit(popup,a,10,10).width==20);pixel(popup,20,15,'#ff0000');pixel(popup,31,15,'#ffffff')
    g:add_column_border(2,3,{color='#00ffff'});frame('custom-span')
    geometry(popup,65,63);pixel(popup,32,45,'#00ffff');pixel(popup,20,15,'#ff0000')
    g:add_column_border(2,nil,{});frame('custom-span-restore')
    a.visible=false;frame('hidden-span');pixel(popup,3,15,'#ffffff')
    a.visible=true;frame('restored-span');pixel(popup,15,15,'#ff0000')
    g:remove(a);g:add_widget_at(a,1,1);g:add_widget_at(b,1,2);frame('span-restore')
    pixel(popup,31,15,'#ffffff');pixel(popup,40,15,'#00ff00')
    -- A row span occupies its first row; the slot below it is a hole.
    g:remove(c);g:remove(a);g:add_widget_at(a,1,1,2,1);frame('row-span')
    assert(warnings('wibox.layout.grid row_span occupies its first row only')==1)
    pixel(popup,15,15,'#ff0000');pixel(popup,3,45,'#ffffff')
    g.border_color={inner=gradient,outer='#ffffff'};frame('hole-gradient')
    assert(awesome._clay_tree(screen[1]):find(' fill linear 0,0 63,0 stops 0:1,0,0,1 1:0,0,1,1',1,true),'the hole carries no fill record')
    assert(not pcall(pixel,popup,2,45,'#ffffff'),'the hole is still white')
    assert(warnings('wibox.layout.grid border_color is not a solid color and is transparent')==1)
    g.border_color='#ffffff'
    local ab=hit(popup,a,10,10)
    assert(ab.height==20)
    local calls={}
    for _,w in ipairs{g,a} do
        w:connect_signal('button::press',function(original,x,y,button,_,area)
            assert(original==w and area.widget==w and button==1)
            if w==a then assert(x==2 and y==ab.height-2 and area.occurrence==ab.occurrence) end
            calls[#calls+1]=w
        end)
    end
    awful.spawn{pointer,'click',tostring(popup.x+ab.x+2),tostring(popup.y+ab.y+ab.height-2),'1280','720','left'}
    async.sleep(.2);assert(#calls==2 and calls[1]==g and calls[2]==a,'native grid/cell pointer order')
    g:remove(d);frame('hole-input')
    for _,h in ipairs(popup:find_widgets(45,45)) do
        assert(h.widget~=a and h.widget~=b and h.widget~=c and h.widget~=d,'hole acquired a cell target')
    end
    local published=0
    local function count() published=published+1 end
    popup.drawable:connect_signal('clay::solved',count)
    async.sleep(.2);assert(published==0,'borders keep publishing')
    popup.drawable:disconnect_signal('clay::solved',count)
    popup.visible=false
    -- Wrapping text in a bordered grid with an authored width: the row
    -- follows the text in one frame.
    g=wibox.layout.grid();g.column_count=2;g.spacing=5
    g.minimum_row_height=20
    g.border_width=1;g.border_color='#ffffff'
    g.forced_width=100;g.expand={horizontal=true,vertical=false}
    local t=wibox.widget.textbox('aa aa aa aa');t.font='monospace 10';t.wrap='word';g:add(t,tidy.leaf(20,20,'#00ff00'))
    popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,widget=g,bg='#204080'}
    frame('text');local height=grid_box(popup).height
    t.text='aa aa aa aa aa aa aa aa';frame('content-grow');assert(grid_box(popup).height>height)
    t.text='aa aa aa aa';frame('content-restore');assert(grid_box(popup).height==height)
    t.font='monospace 18';frame('font-grow');assert(grid_box(popup).height>height)
    t.font='monospace 10';frame('font-restore');assert(grid_box(popup).height==height)
    g.forced_width=180;frame('width-grow');g.forced_width=100;frame('width-restore')
    assert(grid_box(popup).height==height)
    popup.visible=false
    runner.done()
end)
