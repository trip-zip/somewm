-- Geometry/order reads expose the completed frame without declaring or solving.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')

local function index(order,object)
    for i,value in ipairs(order) do if value==object then return i end end
    error('object missing from completed draw order')
end

runner.run_async(function()
    local failures={}
    local function check(ok,message)
        if not ok then
            failures[#failures+1]=message
            io.stderr:write('[FAIL] '..message..'\n')
        end
        return ok
    end
    local a=wibox{screen=screen[1],x=100,y=100,width=100,height=50,
        visible=true,bg='#ff0000',widget=wibox.widget.textbox('A')}
    local b=wibox{screen=screen[1],x=100,y=100,width=100,height=50,
        visible=true,bg='#0000ff',widget=wibox.widget.textbox('B')}
    async.sleep(0.2)
    local before=awesome._test_declare_order(screen[1])
    assert(index(before,a.drawin)<index(before,b.drawin))
    example.pixel(180,140,'#0000ff')
    a.ontop=true
    -- The event loop has not rendered this new input yet. A query must not
    -- silently replace the solved tree with what a future frame would draw.
    local pending=awesome._test_declare_order(screen[1])
    example.save('queries-before-next-frame',awesome._clay_tree(screen[1]))
    local unchanged=check(index(pending,a.drawin)<index(pending,b.drawin),
        'order query performed an auxiliary solve before the next output frame')
    example.pixel(180,140,'#0000ff')
    if unchanged then
        for _=1,10 do
            local order=awesome._test_declare_order(screen[1])
            assert(index(order,a.drawin)<index(order,b.drawin))
        end
    end
    async.sleep(0.2)
    local after=awesome._test_declare_order(screen[1])
    assert(index(after,a.drawin)>index(after,b.drawin))
    example.pixel(180,140,'#ff0000')
    example.save('queries-after-next-frame',awesome._clay_tree(screen[1]))
    a.visible,b.visible=false,false
    local label=wibox.widget.textbox('A')
    local popup=awful.popup{screen=screen[1],visible=true,bg='#00ff00',shadow=false,
        border_width=0,placement=awful.placement.top_left,offset={x=300,y=200},widget=label}
    async.sleep(0.2)
    local width=popup.width
    label.text='A much longer popup label'
    popup:_apply_size_now()
    check(popup.width==width,'popup size read performed an isolated measurement solve')
    async.sleep(0.2)
    assert(popup.width>width,'normal output frame did not solve the changed popup content')
    local g=popup:geometry()
    example.pixel(g.x+g.width-2,g.y+g.height-2,'#00ff00')
    example.save('queries-popup-size',awesome._clay_tree(screen[1]))
    popup.visible=false
    -- Both attachments open in one event turn. The second targets a widget
    -- that has never had a solved box; native declaration supplies its area.
    local opener=wibox.widget.textbox('Opener')
    local parent=awful.popup{screen=screen[1],visible=true,bg='#ff0000',shadow=false,
        border_width=0,placement=awful.placement.top_left,offset={x=400,y=300},widget=opener}
    local child=awful.popup{screen=screen[1],visible=true,bg='#0000ff',shadow=false,
        border_width=0,preferred_positions={'right'},preferred_anchors={'front'},
        widget=wibox.widget.textbox('Child')}
    child:move_next_to{widget=opener,x=0,y=0,width=1,height=1}
    async.sleep(0.2)
    assert(parent.x==400 and parent.y==300)
    assert(child.x==parent.x+parent.width and child.y==parent.y,
        'first-open chained popup did not follow the newly declared opener')
    example.pixel(parent.x+parent.width-2,parent.y+parent.height-2,'#ff0000')
    example.pixel(child.x+child.width-2,child.y+child.height-2,'#0000ff')
    example.save('queries-first-open-chain',awesome._clay_tree(screen[1]))
    child.visible,parent.visible=false,false
    assert(#failures==0,table.concat(failures,'; '))
    io.stderr:write('[PASS] order/geometry reads preserve the completed frame; changed stacking and popup size appear with matching pixels after the normal output frame\n')
    runner.done()
end)
