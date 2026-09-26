-- A widget hit names a placement, including repeated references in one host.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local wibox=require('wibox')
local clay=require('wibox.clay')
local example=require('_clay_example')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    local shared=wibox.widget.base.make_widget(nil,nil,{enable_properties=true})
    clay.describe_widget(shared,function() return {w=50,h=20,bg={1,0,0,1}} end,'attachment-occurrence')
    local row=wibox.layout.fixed.horizontal(shared,shared)
    local host=wibox{screen=screen[1],x=100,y=100,width=200,height=40,
        visible=true,bg='#204080',widget=row}
    local popup=awful.popup{screen=screen[1],visible=false,bg='#00ff00',shadow=false,
        border_width=0,preferred_positions={'right'},preferred_anchors={'front'},
        widget=wibox.widget.textbox('Target')}
    local presses,last_hit=0
    shared:connect_signal('button::press',function(original,x,y,button,modifiers,hit)
        assert(original==shared and hit.widget==shared)
        assert(button==1 and #modifiers==0 and x==2 and y==2)
        presses,last_hit=presses+1,hit
        popup:move_next_to(hit)
    end)
    async.sleep(0.2)
    awful.spawn{pointer,'click','152','102','1280','720','left'}
    async.sleep(0.3)
    assert(presses==1 and last_hit.x==50 and last_hit.width==50,
        'real click did not identify the second original occurrence')
    local first=awesome._clay_tree(screen[1])
    example.save('attachment-second-occurrence',first)
    assert(popup.x==200 and popup.y==100,
        'popup chose a different placement of the clicked widget: '..popup.x..','..popup.y)
    example.pixel(popup.x+popup.width-2,popup.y+popup.height-2,'#00ff00')
    local native=first:match('(%x+)%s+attachment%-occurrence [^\n]-box 150,100 50x40')
    assert(native and first:find('target '..native,1,true),
        'attachment does not name the clicked occurrence actual Clay element')
    local token=last_hit.occurrence
    assert(token and popup.drawin.attachment.occurrence==token)
    screen[1].inspector=true
    async.sleep(0.2)
    local inspected=awesome._clay_tree(screen[1])
    assert(inspected:find('inspector on',1,true) and inspected:find('target '..native,1,true))
    example.pixel(popup.x+popup.width-2,popup.y+popup.height-2,'#00ff00')
    example.save('attachment-occurrence-inspector',inspected)
    screen[1].inspector=false
    local spacer=wibox.widget.base.make_widget()
    clay.describe_widget(spacer,function() return {w=10,h=20} end,'attachment-spacer')
    row:insert(1,spacer)
    async.sleep(0.2)
    assert(popup.x==210 and popup.y==100 and popup.drawin.attachment.occurrence==token,
        'attachment lost its occurrence when an unrelated sibling was inserted')
    host.x=300
    async.sleep(0.2)
    assert(popup.x==410 and popup.y==100,'moving the host did not move its selected attachment')
    example.pixel(popup.x+popup.width-2,popup.y+popup.height-2,'#00ff00')
    example.save('attachment-moved-occurrence',awesome._clay_tree(screen[1]))
    popup.visible=false
    -- Programmatic show on the same original object uses the hovered hit.
    awful.spawn{pointer,'move','362','102','1280','720'}
    async.sleep(0.2)
    popup:move_next_to(shared)
    async.sleep(0.2)
    assert(popup.x==410 and popup.drawin.attachment.occurrence==token,
        'programmatic hovered target lost its placement')
    example.save('attachment-hovered-occurrence',awesome._clay_tree(screen[1]))
    popup.visible=false
    awful.spawn{pointer,'move','900','500','1280','720'}
    async.sleep(0.2)
    local ok,err=pcall(popup.move_next_to,popup,shared)
    assert(not ok and tostring(err):find('ambiguous attachment target',1,true),
        'unqualified duplicate target must report ambiguity')
    popup:move_next_to(last_hit)
    row:remove(3)
    async.sleep(0.2)
    local removed=awesome._clay_tree(screen[1])
    example.save('attachment-removed-occurrence',removed)
    assert(not removed:find('  POPUP ',1,true),
        'a removed target rebound to the surviving copy of the same widget')
    example.pixel(412,102,'#204080')
    row:add(shared)
    async.sleep(0.2)
    assert(not awesome._clay_tree(screen[1]):find('  POPUP ',1,true),
        'a new placement reused a retired occurrence token')
    popup.visible=false
    local other=wibox{screen=screen[1],x=500,y=200,width=100,height=40,
        visible=true,bg='#204080',widget=shared}
    async.sleep(0.2)
    popup:move_next_to{widget=shared,drawable=other._drawable}
    async.sleep(0.2)
    assert(popup.x==600 and popup.y==200,'explicit host did not select its unique original placement')
    example.pixel(popup.x+popup.width-2,popup.y+popup.height-2,'#00ff00')
    example.save('attachment-explicit-host',awesome._clay_tree(screen[1]))
    popup.visible=false
    assert(awesome._test_add_output(800,600))
    async.sleep(0.2)
    local s=screen[2]
    local remote=wibox{screen=s,x=s.geometry.x+100,y=s.geometry.y+100,
        width=140,height=60,visible=true,bg='#204080',widget=shared}
    async.sleep(0.2)
    local hit
    for _, item in ipairs(remote:find_widgets(2,2)) do
        if item.widget==shared then hit=item end
    end
    assert(hit and hit.occurrence~=token and hit.width==140)
    popup:move_next_to(hit)
    async.sleep(0.2)
    assert(popup.screen==s and popup.x==remote.x+140 and popup.y==remote.y,
        'event target on another output selected the wrong host or occurrence')
    assert(popup.drawin.attachment.occurrence==hit.occurrence)
    example.pixel(popup.x+popup.width-2,popup.y+popup.height-2,'#00ff00')
    example.save('attachment-another-output',awesome._clay_tree())
    popup.visible,host.visible,other.visible,remote.visible=false,false,false,false
    -- No host has compiled this fresh widget yet. One copy is in a popup
    -- declared after the dependent popup; the fallback must still detect it.
    local fresh=wibox.widget.base.make_widget()
    clay.describe_widget(fresh,function() return {w=50,h=20,bg={1,0,0,1}} end,'fresh-target')
    local early=wibox{screen=screen[1],x=700,y=300,width=80,height=40,
        visible=true,bg='#204080',widget=fresh}
    local dependent=awful.popup{screen=screen[1],visible=false,bg='#00ff00',shadow=false,
        border_width=0,preferred_positions={'right'},preferred_anchors={'front'},
        widget=wibox.widget.textbox('Ambiguous')}
    local late=awful.popup{screen=screen[1],visible=true,bg='#0000ff',shadow=false,
        border_width=0,placement=awful.placement.top_left,offset={x=900,y=300},widget=fresh}
    dependent:move_next_to(fresh)
    async.sleep(0.2)
    for _, object in ipairs(awesome._test_declare_order(screen[1])) do
        assert(object~=dependent.drawin,'first-frame ambiguity selected an already-declared copy')
    end
    example.save('attachment-first-frame-ambiguity',awesome._clay_tree(screen[1]))
    late.visible=false
    dependent:move_next_to(fresh)
    async.sleep(0.2)
    assert(dependent.x==780 and dependent.y==300,'unique remaining target did not become selectable')
    example.pixel(dependent.x+dependent.width-2,dependent.y+dependent.height-2,'#00ff00')
    example.save('attachment-ambiguity-resolved',awesome._clay_tree(screen[1]))
    dependent.visible,early.visible=false,false
    io.stderr:write('[PASS] real clicked and hovered original occurrence survives sibling insertion and host movement; ambiguous calls are reported; removed targets stay absent; explicit hosts and second-output hits select their actual element\n')
    runner.done()
end)
