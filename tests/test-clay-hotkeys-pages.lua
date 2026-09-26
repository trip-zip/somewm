-- Page membership measurements never supply element rectangles or authored bounds.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local wibox = require('wibox')
local help = require('awful.hotkeys_popup.widget')
local example = require('_clay_example')

local function entries(widget, counts)
    if widget.get_text then
        for entry in widget:get_text():gmatch('ENTRY%d%d%d') do counts[entry]=(counts[entry] or 0)+1 end
    end
    for _,child in ipairs(widget:get_children()) do entries(child,counts) end
end

runner.run_async(function()
    local s = screen[1]
    s.scale = tonumber(os.getenv('SOMEWM_TEXT_TEST_SCALE') or '1')
    async.sleep(.1)
    local bar = awful.wibar {screen=s,position='top',height=60,widget=wibox.widget.textbox('bar')}
    local instance = help.new {width=300,height=160,border_width=3,bg='#204080',fg='#ffffff',
        font='Monospace 8',description_font='Monospace 8',shape=require('gears.shape').rectangle}
    local keys = {}
    for i=1,100 do keys['k'..i]=string.format('ENTRY%03d',i) end
    instance:add_hotkeys {commands={{modifiers={},keys=keys}},
        more={{modifiers={},keys={a='ENTRY101',b='ENTRY102'}}},
        filtered={{modifiers={},keys={a='ENTRY999'}}}}
    instance:add_group_rules('filtered',{rule={class='AbsentApplication'}})
    instance:show_help(nil,s,{show_awesome_keys=false})
    async.sleep(.08)
    local box = select(2,next(instance._cached_wiboxes[s]))
    local popup = box.popup
    local function traverse(expected,label)
        for _=1,200 do box:page_prev() end
        assert(box.current_page==1)
        _keygrabber.inject('Prior',true); _keygrabber.inject('Prior',false)
        assert(box.current_page==1)
        local found, pages = {},0
        while true do
            async.sleep(.02)
            pages=pages+1
            assert(pages<=expected,'unbounded page navigation')
            local current = {}
            entries(popup.widget,current)
            assert(next(current),'empty or marker-only page')
            assert(popup.height<=instance.height, 'ordinary records overflow the page height')
            local function visible_records(widget)
                if widget.get_text and widget:get_text():find('ENTRY%d%d%d') then
                    local bound = assert(popup._drawable._clay_wired[widget])[1].element.box
                    assert(bound.y>=0 and bound.y+bound.height<=popup.height,
                        'record allocation is outside its reachable page')
                end
                for _,child in ipairs(widget:get_children()) do visible_records(child) end
            end
            visible_records(popup.widget)
            for key,count in pairs(current) do found[key]=(found[key] or 0)+count end
            assert(not current.ENTRY999,'filtered group leaked into pages')
            local first = popup.widget:get_children()[1]
            assert(first and popup._drawable._clay_wired[first], 'original column lost its input binding')
            assert(#popup:find_widgets(10,10)>0)
            example.save(label..'-page-'..pages,awesome._clay_tree(s))
            local previous = box.current_page
            _keygrabber.inject('Next',true); _keygrabber.inject('Next',false)
            if box.current_page==previous then break end
        end
        assert(pages>=3,'fixture must exercise several pages')
        local count=0
        for key,n in pairs(found) do assert(n==1,'entry repeated: '..key);count=count+1 end
        assert(count==expected, 'lost entries: '..count..' expected '..expected)
        for i=1,expected do assert(found[string.format('ENTRY%03d',i)],'entry unreachable') end
        local last = box.current_page
        _keygrabber.inject('Prior',true); _keygrabber.inject('Prior',false)
        assert(box.current_page==last-1)
        _keygrabber.inject('Next',true); _keygrabber.inject('Next',false)
        assert(box.current_page==last)
        _keygrabber.inject('Escape',true); _keygrabber.inject('Escape',false)
        assert(not popup.visible)
    end
    traverse(102,'initial')
    instance:show_help(nil,s,{show_awesome_keys=false})
    local same = popup.widget
    box:hide()
    instance:show_help(nil,s,{show_awesome_keys=false})
    assert(popup.widget==same,'unchanged reopening replaced content identities')
    box:hide()
    instance:add_hotkeys {commands={{modifiers={},keys={new='ENTRY103'}}}}
    instance.font,instance.description_font='Monospace 12','Monospace 12'
    instance.width,instance.height=360,240
    beautiful.launcher_width=380
    bar.height=100
    async.sleep(.08)
    instance:show_help(nil,s,{show_awesome_keys=false})
    assert(select(2,next(instance._cached_wiboxes[s])).popup==popup,'cache refresh replaced popup identity')
    async.sleep(.08)
    assert(popup.width==380 and popup.minimum_width==380 and popup.minimum_height==240)
    assert(popup.drawin.attachment.width==380)
    traverse(103,'refreshed')
    beautiful.launcher_width=nil
    bar:remove()

    for _,height in ipairs {20,140} do
        local h = help.new {width=100,height=height,border_width=3,font='Monospace 8',description_font='Monospace 8',
            bg='#204080',fg='#ffffff',shape=require('gears.shape').rectangle}
        h:_load_widget_settings()
        h:add_hotkeys {wide={{modifiers={},keys={a=string.rep('W',100)..' ENTRY001',b='ENTRY002'}}}}
        local shown = h:_create_wibox(s,{'wide'},false)
        shown:show();async.sleep(.08)
        local counts={}
        for _=1,4 do
            local current={};entries(shown.popup.widget,current);assert(next(current))
            for key,n in pairs(current) do counts[key]=(counts[key] or 0)+n end
            local previous=shown.current_page;shown:page_next()
            if previous==shown.current_page then break end
            async.sleep(.02)
        end
        assert(counts.ENTRY001==1 and counts.ENTRY002==1)
        example.save('oversized-first-'..height,awesome._clay_tree(s))
        shown:hide()
    end
    beautiful.hotkeys_font,beautiful.hotkeys_description_font='Monospace 8','Monospace 8'
    local themed = help.new {width=400,height=240,border_width=3,bg='#204080',fg='#ffffff',
        shape=require('gears.shape').rectangle}
    themed:add_hotkeys {commands={{modifiers={},keys={a='ENTRY001'}}}}
    themed:show_help(nil,s,{show_awesome_keys=false})
    async.sleep(.08)
    local cached = select(2,next(themed._cached_wiboxes[s]))
    local old_widget = cached.popup.widget
    cached:hide()
    beautiful.hotkeys_font,beautiful.hotkeys_description_font='Monospace 12','Monospace 12'
    beautiful.hotkeys_opacity=.8
    themed:show_help(nil,s,{show_awesome_keys=false})
    async.sleep(.08)
    assert(themed.font=='Monospace 12' and cached.popup.widget~=old_widget)
    assert(cached.popup.opacity==.8 and themed.bg=='#204080')
    local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
    local p = cached.popup
    awful.spawn {pointer,'click',tostring(p.x+p.width/2),tostring(p.y+p.height/2),
        tostring(s.geometry.width),tostring(s.geometry.height),'left'}
    assert(async.wait_for_condition(function() return not p.visible end,2,.01), 'pointer dismissal failed')
    beautiful.hotkeys_font,beautiful.hotkeys_description_font,beautiful.hotkeys_opacity=nil,nil,nil

    local imported = help.new {width=400,height=240,border_width=0,bg='#204080',fg='#ffffff'}
    awful.key({},'F11',function() end,{description='ENTRY001',group='imported'})
    imported:show_help(nil,s)
    async.sleep(.08)
    local imported_box = select(2,next(imported._cached_wiboxes[s]))
    local imported_popup = imported_box.popup
    imported_box:hide()
    awful.key({},'F12',function() end,{description='ENTRY002',group='imported'})
    imported:show_help(nil,s)
    async.sleep(.08)
    assert(select(2,next(imported._cached_wiboxes[s])).popup==imported_popup)
    local imported_entries={};entries(imported_popup.widget,imported_entries)
    assert(imported_entries.ENTRY001==1 and imported_entries.ENTRY002==1)
    imported_box:hide()
    runner.done()
end)
