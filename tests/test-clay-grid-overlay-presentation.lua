-- A superposed widget floats over the cell it starts in: Clay attaches it to
-- that cell, so it follows the cell in the same frame.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')
local tidy=require('_clay_tidy')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
runner.run_async(function()
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5;g.superpose=true
    g.homogeneous=false
    local a,b=tidy.leaf(40,20,'#ff0000'),tidy.leaf(70,20,'#00ff00')
    local over=tidy.leaf(0,0,'#0000ff');over.forced_width=30;over.forced_height=10
    g:add(a,b);g:add_widget_at(over,1,2)
    local host=awful.popup{screen=screen[1],x=100,y=100,visible=true,bg='#204080',widget=g}
    local function find(w,x,y)
        for _,hit in ipairs(host:find_widgets(x,y)) do if hit.widget==w then return hit end end
    end
    local function frame(label,x)
        awesome._test_redeclare()
        local dump=awesome._clay_tree(screen[1])
        assert(dump:match('roots flow 1 floating %d+ derived 0 '),label..': derived size')
        assert(dump:find('wibox.widget.base w=fixed(30) user h=fixed(10) user row attach ELEMENT',1,true),
            label..': overlay is not attached to an element')
        local box=assert(find(over,x+1,1),label..': overlay has no native target')
        assert(box.x==x and box.y==0 and box.width==30 and box.height==10,
            label..': overlay '..table.concat({box.x,box.y,box.width,box.height},','))
        example.pixel(host.x+x+1,host.y+1,'#0000ff')
        example.pixel(host.x+x+1,host.y+15,'#00ff00')
        assert(host.width==x+70 and host.height==20,label..': overlay enlarged the grid')
        assert(awesome._test_redeclare()==0,label..': the next frame changed the scene')
        example.save('overlay-'..label,dump)
    end
    frame('initial',45)
    a.forced_width=60;frame('anchor-moves',65)
    a.forced_width=nil;frame('anchor-restores',45)
    -- Overlays pass input through by default: the real press reaches what
    -- the native lookup names at that point, in its order.
    local expected,calls={},{}
    for _,hit in ipairs(host:find_widgets(50,5)) do
        if hit.widget==over or hit.widget==b then expected[#expected+1]=hit.widget end
    end
    assert(#expected==2,'native lookup misses the overlay or its cell')
    for _,w in ipairs{over,b} do
        w:connect_signal('button::press',function() calls[#calls+1]=w end)
    end
    awful.spawn{pointer,'click',tostring(host.x+50),tostring(host.y+5),'1280','720','left'}
    assert(async.wait_for_condition(function() return #calls==2 end,2,.01))
    assert(calls[1]==expected[1] and calls[2]==expected[2],'real press disagrees with native lookup')
    host.visible=false
    runner.done()
end)
