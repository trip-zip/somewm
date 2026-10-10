-- A grid declares once and solves once per frame: after any change, one frame
-- presents the final geometry and the next frame changes nothing.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')
local capture=require('_widget_capture')
local surface=require('gears.surface')
runner.run_async(function()
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5
    local a=wibox.container.background(nil,'#ff0000');a.forced_width=40;a.forced_height=10
    local b=wibox.container.background(nil,'#00ff00');b.forced_width=70;b.forced_height=10
    g:add(a,b)
    local popup=awful.popup{screen=screen[1],x=100,y=100,visible=true,bg='#204080',widget=g}
    local function box(w,x,y)
        for _,hit in ipairs(popup:find_widgets(x,y)) do
            if hit.widget==w then return hit end
        end
    end
    local function frame(label,width,height)
        awesome._test_redeclare()
        if type(width)=='function' then width,height=width() end
        assert(popup.width==width and popup.height==height,
            label..': popup '..popup.width..'x'..popup.height..', want '..width..'x'..height)
        local dump=awesome._clay_tree(screen[1])
        assert(dump:match('roots flow 1 floating %d+ derived 0 '),label..': derived size')
        assert(awesome._test_redeclare()==0,label..': the next frame changed the scene')
        example.save('helper-'..label,dump)
    end
    -- Homogeneous with no authored size: cells take their content size.
    frame('initial',115,10)
    local ab,bb=box(a,2,2),box(b,47,2)
    assert(ab.width==40 and bb.width==70 and bb.x==45)
    example.pixel(popup.x+2,popup.y+2,'#ff0000')
    example.pixel(popup.x+42,popup.y+2,'#204080')
    example.pixel(popup.x+47,popup.y+2,'#00ff00')
    a.forced_width=100;frame('a-grow',175,10)
    a.forced_width=40;frame('a-restore',115,10)
    b.forced_width=120;b.forced_height=30;frame('b-grow-tall',165,30)
    b.forced_width=70;b.forced_height=10;frame('b-restore',115,10)
    b.visible=false;frame('hide',45,10)
    for _,hit in ipairs(popup:find_widgets(44,2)) do assert(hit.widget~=b,'hidden input') end
    b.visible=true;frame('reappear',115,10)
    g:remove(b);frame('remove',45,10)
    g:add_widget_at(b,1,2);frame('reinsert',115,10)
    local published=0
    local function count() published=published+1 end
    popup.drawable:connect_signal('clay::solved',count)
    async.sleep(.2)
    popup.drawable:disconnect_signal('clay::solved',count)
    assert(published==0,'idle grid keeps publishing')
    -- Real text: each text's own Clay measurement, read from the dump.
    local ta,tb=wibox.widget.textbox('mm'),wibox.widget.textbox('mmmmmmm')
    ta.font='monospace 12';tb.font='monospace 12'
    ta.wrap='word';tb.wrap='word'
    local function text_size(w)
        local quoted='"'..w.text:gsub('%p','%%%0')..'"'
        local tw,th=awesome._clay_tree(screen[1]):match(quoted..' font=%d+ box %-?%d+,%-?%d+ (%d+)x(%d+)')
        assert(tw,w.text)
        return tonumber(tw),tonumber(th)
    end
    local function two_texts()
        local aw,ah=text_size(ta);local bw,bh=text_size(tb)
        return aw+5+bw,math.max(ah,bh)
    end
    local function one_text()
        local tw,th=text_size(ta)
        return tw+5,th
    end
    g:reset();g:add(ta,tb)
    frame('text-initial',two_texts)
    ta.text='mmmmmmmmmmmm';frame('text-a-grow',two_texts)
    ta.text='mm';frame('text-a-restore',two_texts)
    tb.text='mmmmmmmmmmmmmmmm';frame('text-b-grow',two_texts)
    tb.text='mmmmmmm';frame('text-b-restore',two_texts)
    tb.font='monospace 20';frame('text-font-grow',two_texts)
    tb.font='monospace 12';frame('text-font-restore',two_texts)
    tb.visible=false;frame('text-hide',one_text)
    tb.visible=true;frame('text-reappear',two_texts)
    g:remove(tb);frame('text-remove',one_text)
    g:add_widget_at(tb,1,2);frame('text-reinsert',two_texts)
    local painted=0
    local im=surface(root.content())
    for y=popup.y,popup.y+popup.height-1 do
        for x=popup.x,popup.x+popup.width-1 do
            local r,green,blue=capture.read(im,x,y)
            if r~=32 or green~=64 or blue~=128 then painted=painted+1 end
        end
    end
    assert(painted>20,'text glyphs did not paint')
    popup.visible=false
    -- An authored wibox size: each cell is half of the width less the gap.
    a.forced_width,b.forced_width=nil,nil
    g:reset();g:add(a,b);g.expand=true
    popup=wibox{screen=screen[1],x=100,y=100,width=200,height=80,
        visible=true,bg='#204080',widget=g}
    frame('rounding-200',200,80)
    ab,bb=box(a,2,2),box(b,150,2)
    assert(ab.width==98 and bb.x==103 and bb.width==97)
    for _,hit in ipairs(popup:find_widgets(100,2)) do assert(hit.widget~=a and hit.widget~=b) end
    example.pixel(197,102,'#ff0000');example.pixel(198,102,'#204080')
    example.pixel(203,102,'#00ff00');example.pixel(299,102,'#00ff00')
    popup.width=201;frame('resize-201',201,80)
    ab=box(a,2,2);assert(ab.width==98)
    popup.width=200;frame('resize-restore',200,80)
    ab=box(a,2,2);assert(ab.width==98)
    popup.visible=false
    io.stderr:write('[PASS] one frame per change: content cells, growth/shrink/hide/remove/restore, real text/font, percent cells, stable idle\n')
    runner.done()
end)
