-- Native widget floats: solved/lookup areas, paint, capture, offsets and clock.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local capture = require('_widget_capture')
local example = require('_clay_example')
local surface = require('gears.surface')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    local s = screen[1]
    local desktop = surface(root.content())
    local a = capture.leaf_widget(100, 20, '#ff0000')
    local b = capture.leaf_widget(40, 60, '#00ff00')
    a.forced_width, a.forced_height = 100, 20
    b.forced_width, b.forced_height = 40, 60
    local stack = wibox.layout.stack(a, b)
    stack.forced_width, stack.forced_height = 120, 80
    local bar = wibox {screen=s, x=100, y=100, width=180, height=100,
        visible=true, bg='#101010', widget=wibox.container.place(stack, 'left', 'top')}
    local function box(widget)
        return assert(bar._drawable._clay_wired[widget])[1].element.box
    end
    local function check(widget, x, y, w, h)
        capture.assert_box(box(widget), {x=x,y=y,width=w,height=h}, 'original widget')
    end
    local function pixel(x,y,color)
        example.pixel(bar.x+x,bar.y+y,color)
    end
    local calls = {}
    for i, widget in ipairs {a,b} do
        widget:connect_signal('button::press', function(original,x,y,button)
            assert(original==widget and x==10 and y==10 and button==1)
            calls[#calls+1]=i
        end)
    end
    local function click()
        awful.spawn{pointer,'click','110','110','1280','720','left'}
        async.sleep(0.2)
    end
    async.sleep(0.3)
    check(stack,0,0,120,80); check(a,0,0,100,20); check(b,0,0,40,60)
    pixel(10,10,'#00ff00'); pixel(60,10,'#ff0000'); pixel(60,40,'#101010')
    local hits=bar:find_widgets(10,10)
    local found={}; for _,hit in ipairs(hits) do found[hit.widget]=hit end
    assert(found[a] and found[b] and found[stack])
    assert(found[a].width==100 and found[b].height==60)
    click(); assert(table.concat(calls,',')=='1,2', 'top float did not pass click through')
    example.save('widget-overlap-native',awesome._clay_tree(s))

    stack:swap(1,2); async.sleep(0.2)
    pixel(10,10,'#ff0000')
    stack.top_only=true; async.sleep(0.2)
    pixel(10,10,'#00ff00'); pixel(60,10,'#101010')
    stack:raise(2); async.sleep(0.2)
    pixel(10,10,'#ff0000'); pixel(10,40,'#101010')
    stack.top_only=false; stack.spacing=3
    stack.horizontal_offset=4; stack.vertical_offset=2
    async.sleep(0.2)
    check(a,3,3,100,20); check(b,7,5,40,60)
    example.save('widget-overlap-offsets',awesome._clay_tree(s))

    -- FIT width follows the first child; the taller float cannot size it.
    stack.spacing=0; stack.horizontal_offset=0; stack.vertical_offset=0
    stack.forced_width=nil; stack.forced_height=nil
    bar.widget=wibox.layout.fixed.horizontal(stack)
    async.sleep(0.2)
    assert(box(stack).width==100, 'stack did not fit its in-flow child')
    check(a,0,0,100,20); check(b,0,0,40,60)
    example.save('widget-overlap-unforced',awesome._clay_tree(s))

    bar.widget=wibox.container.place(stack,'left','top')
    async.sleep(0.2)
    check(stack,0,0,100,20)
    check(a,0,0,100,20); check(b,0,0,40,60)
    pixel(10,40,'#00ff00')
    a:set_visible(false)
    async.sleep(0.2)
    check(stack,0,0,40,60); check(b,0,0,40,60)
    for _, hit in ipairs(bar:find_widgets(10,10)) do
        assert(hit.widget~=a, 'hidden child received a hit')
    end
    stack.top_only=true
    async.sleep(0.2)
    check(b,0,0,40,60)
    b:set_visible(false)
    async.sleep(0.2)
    for _, hit in ipairs(bar:find_widgets(10,10)) do
        assert(hit.widget~=stack and hit.widget~=a and hit.widget~=b,
            'empty stack received a hit')
    end
    a:set_visible(true); b:set_visible(true); stack.top_only=false
    async.sleep(0.2)
    check(stack,0,0,100,20)
    example.save('widget-overlap-promoted',awesome._clay_tree(s))

    -- Exercise the C reader and declaration's actual capture/point fields.
    clay.describe_widget(b,function()
        return {w=40,h=60,bg=clay.solid_rgba('#00ff00'),
            parent=0,own=0,passthrough=false}
    end,'capture-leaf')
    stack.forced_width,stack.forced_height=120,80
    bar.widget=wibox.container.place(stack,'left','top')
    b:emit_signal('widget::layout_changed'); async.sleep(0.2)
    calls={}; click(); assert(table.concat(calls,',')=='2', 'capture did not stop the lower float')
    assert(awesome._clay_tree(s):find('parent LEFT_TOP own LEFT_TOP pointer capture',1,true))
    example.save('widget-overlap-capture',awesome._clay_tree(s))
    -- Bottom-right points and a minimum-sized float still leave the forced
    -- parent at 120x80, with the leaf's independent 70x45 lookup area.
    b.forced_width,b.forced_height=nil,nil
    clay.describe_widget(b,function()
        return {w="fit",h="fit",wmin=70,hmin=45,
            bg=clay.solid_rgba('#00ff00'),parent=8,own=8}
    end,'minimum-leaf')
    b:emit_signal('widget::layout_changed'); async.sleep(0.2)
    check(stack,0,0,120,80); check(b,50,35,70,45)
    pixel(60,40,'#00ff00'); pixel(130,40,'#101010')
    example.save('widget-overlap-minimum',awesome._clay_tree(s))
    local function frames()
        return assert(tonumber(awesome._clay_tree(s):match('^[^\n]- frames (%d+) passes ')))
    end
    local before=frames()
    bar.width=80
    local r,g,bv
    local dr,dg,db=capture.read(desktop,190,110)
    for _=1,100 do
        async.sleep(0.02)
        if frames()>before then
            r,g,bv=capture.read(surface(root.content()),190,110)
            if r==dr and g==dg and bv==db then break end
        end
    end
    assert(r==dr and g==dg and bv==db, 'float painted beyond its host clip')
    example.save('widget-overlap-clipped',awesome._clay_tree(s))
    bar.visible=false
    local overlap_bar=bar -- retain the hidden drawin through pointer release

    -- The bundled clock composition, at two actual bar widths, including
    -- glyph pixels and all original object bindings.
    local clock=wibox.widget.textclock('Fri Sep 12  09:14')
    local inset=wibox.container.margin(clock,8,8,0,0)
    local background=wibox.container.background(inset,'#303030')
    local place=wibox.container.place(background,'center')
    local overlay=wibox.layout.stack(wibox.container.background(nil,'#101010'),place)
    bar=wibox {screen=s,x=100,y=100,width=400,height=32,visible=true,
        bg='#101010',fg='#ffffff',widget=overlay}
    local old_width
    for _, width in ipairs {400,640} do
        bar.width=width; async.sleep(0.3)
        local c=box(background)
        assert(math.abs(c.x+c.width/2-width/2)<=1 and math.abs(c.y+c.height/2-16)<=1,
            'clock box is not centered')
        assert(not old_width or old_width==c.width, 'clock intrinsic width changed')
        old_width=c.width
        check(place,0,0,width,bar.height)
        if c.x~=0 or c.y~=0 or c.width~=width or c.height~=bar.height then
            assert(bar._drawable._clay_wired[place][1].element~=bar._drawable._clay_wired[background][1].element)
        end
        assert(bar._drawable._clay_wired[inset][1].element==bar._drawable._clay_wired[background][1].element)
        local glyph=box(clock)
        local image=surface(root.content())
        local minx,maxx,count=math.huge,-math.huge,0
        for y=math.floor(glyph.y),math.floor(glyph.y+glyph.height)-1 do
            for x=math.floor(glyph.x),math.floor(glyph.x+glyph.width)-1 do
                local r,g,bv=capture.read(image,bar.x+x,bar.y+y)
                if r>180 and g>180 and bv>180 then
                    minx,maxx,count=math.min(minx,x),math.max(maxx,x),count+1
                end
            end
        end
        assert(count>50 and math.abs((minx+maxx)/2-width/2)<4,'glyph pixels are not centered')
        local placed=bar._drawable._clay_wired[place][1].element
        assert(placed.align.x=='center' and placed.align.y=='center')
        local originals={}
        for _,hit in ipairs(bar:find_widgets(glyph.x+1,glyph.y+1)) do originals[hit.widget]=true end
        assert(originals[place] and originals[background] and originals[clock],
            'centered content did not pass lookup through its original containers')
        example.save('widget-clock-'..width,awesome._clay_tree(s))
    end
    bar.visible=false
    assert(not overlap_bar.visible)
    io.stderr:write('[PASS] native overlap boxes/lookup/pixels/click-through/capture, reorder/top-only/offsets, unforced stack; centered clock boxes and glyphs at 400/640\n')
    runner.done()
end)
