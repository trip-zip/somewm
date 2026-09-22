-- Allocated textboxes retain their sizing area; content-sized text and a
-- sole root contribution can bind directly to native TEXT.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local wibox=require('wibox')
local clay=require('wibox.clay')
local example=require('_clay_example')
local capture=require('_widget_capture')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

local function original_node(node,widget)
    if node.widget==widget then return node end
    for _,child in ipairs(node.children or {}) do
        local found=original_node(child,widget)
        if found then return found end
    end
end

runner.run_async(function()
    require('beautiful').font='monospace 10'
    local kept_hosts={}
    for _,ad_hoc in ipairs{false,true} do
        local backing=wibox.widget.textbox('A')
        local label=backing
        if ad_hoc then
            label=wibox.widget.base.make_widget(nil,nil,{enable_properties=true})
            -- The supported ad-hoc describer contributes the same text policy;
            -- only label, not the backing descriptor's object, is in the tree.
            clay.describe_widget(label,function(_,fg,st)
                return backing._clay.describe(backing,fg,st)
            end,'ad-hoc-textbox')
        end
        local margin=wibox.container.margin(label,8,8,4,4)
        local host=awful.popup{screen=screen[1],minimum_width=120,maximum_width=120,
            minimum_height=50,maximum_height=50,visible=true,bg='#0000ff',fg='#ffffff',
            shadow=false,border_width=0,placement=awful.placement.top_left,
            offset={x=100,y=100},widget=margin}
        kept_hosts[#kept_hosts+1]=host
        local calls={}
        for _,widget in ipairs{margin,label} do
            widget:connect_signal('button::press',function(original,x,y,button,modifiers,area)
                assert(original==widget and area.widget==widget)
                assert(button==1 and #modifiers==0)
                if widget==label then
                    assert(x==area.width-2 and y==area.height-2,'text hit used the glyph area')
                else assert(x==host.width-10 and y==host.height-6) end
                calls[#calls+1]=widget
            end)
        end
        for _,state in ipairs{
            {name='left-top',text='A',halign='left',valign='top',width=120},
            {name='wrapped-center',text='AA BB',halign='center',valign='center',width=50},
            {name='right-bottom',text='CCC',halign='right',valign='bottom',width=120},
        } do
            backing.text,backing.halign,backing.valign=state.text,state.halign,state.valign
            assert(backing._private.layout:get_alignment()==state.halign:upper()
                and backing._private.valign==state.valign)
            if ad_hoc then label:emit_signal('widget::layout_changed') end
            host.minimum_width,host.maximum_width=state.width,state.width
            async.sleep(0.2)
            local hit
            for _,item in ipairs(host:find_widgets(host.width-10,host.height-6)) do
                if item.widget==label then hit=item end
            end
            capture.assert_box(hit,{x=8,y=4,width=host.width-16,height=42},'original text area')
            local name='text-area-'..(ad_hoc and 'ad-hoc-' or 'built-in-')..state.name
            local dump=awesome._clay_tree(screen[1])
            example.save(name,dump)
            local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
            if dir then
                local f=assert(io.open(dir..'/'..name..'.rgba','wb'))
                f:write(capture.new(screen[1],100,100,host.width,50):shot());f:close()
            end
            local bound=assert(original_node(host._drawable._clay_tree,label))
            assert(not bound.text and bound.children[1].text==state.text,
                'an independently allocated textbox must retain its sizing container')
            calls={}
            awful.spawn{pointer,'click',tostring(host.x+host.width-10),
                tostring(host.y+host.height-6),'1280','720','left'}
            async.sleep(0.2)
            assert(#calls==2 and calls[1]==margin and calls[2]==label,
                'text representation lost original parent/child input order')
        end
        local target
        for _,hit in ipairs(host:find_widgets(110,44)) do if hit.widget==label then target=hit end end
        assert(target)
        local content=wibox.widget.base.make_widget()
        clay.describe_widget(content,function() return {w=20,h=10,bg={0,1,0,1}} end,'text-popup-content')
        local popup=awful.popup{screen=screen[1],visible=false,bg='#00ff00',border_width=0,
            shadow=false,preferred_positions={'right'},preferred_anchors={'front'},widget=content}
        kept_hosts[#kept_hosts+1]=popup
        popup:move_next_to(target)
        async.sleep(0.2)
        assert(popup.x==212 and popup.y==104,'attachment used text glyphs instead of widget area')
        example.pixel(214,106,'#00ff00')
        local before=awesome._clay_tree(screen[1])
        local id=assert(before:match('POPUP [^\n]- target (%x+)[^\n]- box 212,104 20x10'))
        local line=assert(before:match('\n    '..id..' ([^\n]+)'))
        assert(line:find('box 108,104 104x42',1,true),'attachment target is not the actual widget-sized element')
        host.offset={x=200,y=100}
        async.sleep(0.2)
        assert(popup.x==312 and popup.y==104)
        local dump=awesome._clay_tree(screen[1])
        assert(dump:find('target '..id..' ',1,true),'text occurrence changed when its host moved')
        example.pixel(314,106,'#00ff00')
        example.save('text-attachment-'..(ad_hoc and 'ad-hoc' or 'built-in'),dump)
        screen[1].inspector=true
        async.sleep(0.2)
        dump=awesome._clay_tree(screen[1])
        assert(dump:find('target '..id..' ',1,true),'inspector changed the native text target')
        example.pixel(314,106,'#00ff00')
        example.save('text-inspector-'..(ad_hoc and 'ad-hoc' or 'built-in'),dump)
        screen[1].inspector=false
        popup.visible=false
        label.forced_width=30
        async.sleep(0.2)
        assert(not assert(original_node(host._drawable._clay_tree,label)).text,
            'an authored sizing floor must retain its real container')
        example.save('text-retained-bound-'..(ad_hoc and 'ad-hoc' or 'built-in'),awesome._clay_tree(screen[1]))
        host.visible=false
        async.sleep(0.1)
    end
    for _,content_sized in ipairs{false,true} do
        local label=wibox.widget.textbox('Native')
        local root=label
        if content_sized then
            root=wibox.widget.base.make_widget()
            clay.describe_widget(root,function()
                return {specs={{widget=label,w='fit',h='fit'}}}
            end,'ad-hoc-content-slot')
        end
        local host=wibox{screen=screen[1],x=100,y=100,width=160,height=60,
            visible=true,bg='#0000ff',fg='#ffffff',widget=root}
        kept_hosts[#kept_hosts+1]=host
        async.sleep(0.2)
        local node=assert(host._drawable._clay_wired[label][1].element)
        assert(node.text=='Native' and node.text_layout,'compatible text did not own a native TEXT element')
        if content_sized then
            assert(node.box.width>0 and node.box.width<160 and node.box.height>0 and node.box.height<60)
        else capture.assert_box(node.box,{x=0,y=0,width=160,height=60},'sole root text') end
        local hit
        for _,area in ipairs(host:find_widgets(1,1)) do if area.widget==label then hit=area end end
        assert(hit and hit.width==node.box.width and hit.height==node.box.height)
        example.save(content_sized and 'text-content-slot' or 'text-sole-root',awesome._clay_tree(screen[1]))
        host.visible=false
        async.sleep(0.1)
    end
    io.stderr:write('[PASS] built-in/ad-hoc allocated textboxes retain containers; alignment/wrapping pixels, original parent/child input and moving attachments agree; content-sized and sole-root text bind to native TEXT\n')
    runner.done()
end)
