-- Shared-area contributions apply equally to built-in and ad-hoc describers.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local awful = require('awful')
local clay = require('wibox.clay')
local example = require('_clay_example')
local capture = require('_widget_capture')

local function custom(name, describe)
    local w = wibox.widget.base.make_widget()
    clay.describe_widget(w, describe, name)
    return w
end

runner.run_async(function()
    for _, ad_hoc in ipairs{false, true} do
        local leaf = custom('contribution-content', function()
            return {w='grow',h='grow',bg={1,0,0,1}}
        end)
        local margin = ad_hoc and custom('contribution-padding', function()
            return {pad={8,8,8,8},specs=clay.whole_box(leaf)}
        end) or wibox.container.margin(leaf,8,8,8,8)
        local background = ad_hoc and custom('contribution-background', function()
            return {bg={0,0,1,1},specs=clay.whole_box(margin)}
        end) or wibox.container.background(margin,'#0000ff')
        local host = wibox {screen=screen[1],x=100,y=100,width=200,height=60,
            visible=true,bg='#204080',widget=background}
        async.sleep(0.2)
        local boxes=awesome._test_widget_boxes(host.drawin)
        example.save(ad_hoc and 'contributions-ad-hoc-before' or 'contributions-built-in-before',
            awesome._clay_tree(screen[1]))
        assert(#boxes==3,'background and padding must share one real element')
        capture.assert_box(boxes[2],{x=0,y=0,width=200,height=60},'combined outer element')
        capture.assert_box(boxes[3],{x=8,y=8,width=184,height=44},'distinct inset content')
        local found={}
        for _, hit in ipairs(host:find_widgets(2,2)) do found[hit.widget]=hit end
        assert(found[background] and found[margin] and not found[leaf],
            'padding lookup lost original objects or included the inset child')
        capture.assert_box(found[background],boxes[2],'original background area')
        capture.assert_box(found[margin],boxes[2],'original padding area')
        local list=host._drawable._clay_wired
        assert(list[background][1].element==list[margin][1].element,
            'aliases must name the same real solved element')
        assert(list[leaf][1].element~=list[margin][1].element)
        example.pixel(102,102,'#0000ff')
        example.pixel(110,110,'#ff0000')
        local popup = awful.popup {screen=screen[1],visible=false,ontop=true,
            bg='#00ff00',border_width=0,shadow=false,
            preferred_positions={'bottom'},preferred_anchors={'middle'},
            widget=custom('contribution-popup-content',function() return {w=20,h=10} end)}
        -- Select the original padding object, which no longer owns a separate
        -- Clay element. The public anchor must resolve its combined element.
        popup:move_next_to{widget=margin,x=0,y=0,width=1,height=1}
        async.sleep(0.2)
        assert(popup.x==190 and popup.y==160,'folded padding attachment has the wrong area')
        local before=awesome._clay_tree(screen[1])
        local target=assert(before:match('POPUP [^\n]- target (%x+)'))
        local target_line=assert(before:match('\n    '..target..' ([^\n]+)'),
            'attachment target is not a real element')
        assert(target_line:find('box 100,100 200x60',1,true),
            'attachment alias did not name the combined outer element')
        example.pixel(192,162,'#00ff00')
        host.x=200
        async.sleep(0.2)
        assert(popup.x==290 and popup.y==160,'attachment did not follow its folded target')
        local dump=awesome._clay_tree(screen[1])
        assert(dump:find('target '..target..' ',1,true),'host movement changed target identity')
        example.pixel(292,162,'#00ff00')
        local r,g,b=capture.read(require('gears.surface')(root.content()),192,162)
        assert(not (r==0 and g==255 and b==0),'old attachment pixels remained')
        example.save(ad_hoc and 'contributions-ad-hoc' or 'contributions-built-in',dump)
        io.stderr:write('[PASS] '..(ad_hoc and 'ad-hoc' or 'built-in')
            ..' background/padding share a real element, original areas and paint survive, attachment to folded padding follows movement\n')
        popup.visible,host.visible=false,false
        async.sleep(0.1)
    end
    local content=custom('contribution-deep-content',function()
        return {w='grow',h='grow',bg={1,0,0,1}}
    end)
    local widgets,wrapped={content},content
    for _=1,256 do
        wrapped=wibox.container.margin(wrapped,0,0,0,0)
        widgets[#widgets+1]=wrapped
    end
    local presses={}
    for i,widget in ipairs(widgets) do
        widget:buttons{awful.button({},1,function() presses[#presses+1]=i end)}
    end
    local host=wibox{screen=screen[1],x=100,y=100,width=200,height=60,
        visible=true,widget=wrapped}
    async.sleep(0.2)
    assert(#awesome._test_widget_boxes(host.drawin)==2,
        'zero-padding chain must share one content element under its host')
    local hits=host:find_widgets(2,2)
    assert(#hits==257,'deep binding list lost an original widget')
    for i,hit in ipairs(hits) do
        assert(hit.widget==widgets[258-i],'deep original-widget order changed')
        capture.assert_box(hit,{x=0,y=0,width=200,height=60},'deep shared area')
    end
    local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
    awful.spawn{pointer,'click','102','102','1280','720','left'}
    async.sleep(0.3)
    assert(#presses==257,'real pointer delivery lost a folded widget')
    for i,value in ipairs(presses) do assert(value==258-i,'deep input order changed') end
    example.save('contributions-deep-bindings',awesome._clay_tree(screen[1]))
    io.stderr:write('[PASS] 257 original Lua widgets share one real content element; all lookup areas and real left-click deliveries retain original order\n')
    host.visible=false
    runner.done()
end)
