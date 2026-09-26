-- Equal-area host slots own their drawable contribution; real insets remain.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local wibox=require('wibox')
local clay=require('wibox.clay')
local example=require('_clay_example')
local capture=require('_widget_capture')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    local s=screen[1]
    local bars={}
    for _,edge in ipairs{'top','bottom','left','right'} do
        local leaf=wibox.widget.base.make_widget()
        clay.describe_widget(leaf,function() return {w='grow',h='grow',bg={1,0,0,1}} end,'host-content')
        local margin=wibox.container.margin(leaf,8,8,8,8)
        local horizontal=edge=='top' or edge=='bottom'
        local bar=awful.wibar{screen=s,position=edge,stretch=true,
            height=horizontal and 40 or nil,width=not horizontal and 40 or nil,
            bg='#0000ff',widget=margin}
        bars[#bars+1]=bar
        local clicks,releases=0,0
        leaf:connect_signal('button::press',function(original,x,y,button,modifiers,area)
            assert(original==leaf and area.widget==leaf and x==2 and y==2)
            assert(button==1 and #modifiers==0)
            clicks=clicks+1
        end)
        leaf:connect_signal('button::release',function(original,x,y,button,modifiers,area)
            assert(original==leaf and area.widget==leaf and x==2 and y==2)
            assert(button==1 and #modifiers==0)
            releases=releases+1
        end)
        async.sleep(0.2)
        local leaf_id
        local function check(name,combined)
            local dump=awesome._clay_tree(s)
            example.save(name,dump)
            local id=assert(dump:match('(%x+) +host%-content '))
            assert(not leaf_id or id==leaf_id,'host root changes renamed the original leaf occurrence')
            leaf_id=id
            local head=assert(dump:match('WIBAR [^\n]+'))
            assert((head:find(' clip ',1,true)~=nil)==combined,
                'host clip must belong to the actual equal-area element')
            local boxes=awesome._test_widget_boxes(bar.drawin)
            local content=assert(bar._drawable._clay_wired[margin][1].element)
            assert(not content.float and not content.wmin and not content.hmin,
                'host allocation still carries a float or previous-size minima')
            capture.assert_box(boxes[1],{x=0,y=0,width=bar.width,height=bar.height},'host root')
            local found
            for _,hit in ipairs(bar:find_widgets(10,10)) do if hit.widget==leaf then found=hit end end
            capture.assert_box(found,{x=8,y=8,width=bar.width-16,height=bar.height-16},'original leaf')
            example.pixel(bar.x+2,bar.y+2,'#0000ff')
            example.pixel(bar.x+10,bar.y+10,'#ff0000')
        end
        check('host-'..edge..'-combined',true)
        awful.spawn{pointer,'click',tostring(bar.x+10),tostring(bar.y+10),'1280','720','left'}
        for attempt=1,30 do
            if releases==1 then break end
            async.sleep(0.02)
        end
        assert(clicks==1 and releases==1,'combined host lost original widget input')
        if edge=='top' then
            bar.margins={left=5,right=7,top=3,bottom=9}
            async.sleep(0.2)
            assert(bar.x==5 and bar.y==3 and bar.width==1268 and bar.height==40)
            check('host-top-inset',false)
            bar.margins=0
            bar.stretch=false
            bar.width=180
            bar.align='right'
            async.sleep(0.2)
            assert(bar.x==1100 and bar.width==180 and bar.height==40)
            check('host-top-non-stretched',false)
            bar.stretch=true
            async.sleep(0.2)
            assert(bar.x==0 and bar.width==1280 and bar.height==40)
            check('host-top-recombined',true)
        end
        bar.visible=false
        async.sleep(0.1)
    end
    assert(#bars==4)
    io.stderr:write('[PASS] four host edges share actual clip/paint roots; margin and non-stretched areas remain distinct; original lookup, real input and pixels agree across root changes\n')
    runner.done()
end)
