-- Hotkeys help is one horizontal overflow of columns; the page keys scroll it by a viewport.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local wibox = require('wibox')
local help = require('awful.hotkeys_popup.widget')
local example = require('_clay_example')

-- Every ENTRY in the dump's text nodes, with the box of the node holding it.
local function entries(dump)
    local counts, boxes = {}, {}
    for text, y, h in dump:gmatch('text "(.-)" font=%d+ box %-?%d+,(%-?%d+) %d+x(%d+)') do
        for entry in text:gmatch('ENTRY%d%d%d') do
            counts[entry] = (counts[entry] or 0) + 1
            boxes[#boxes+1] = {tonumber(y), tonumber(h)}
        end
    end
    return counts, boxes
end

local function launcher(dump)
    return dump:match('\n(  LAUNCHER .-)\n  %S') or dump:match('\n(  LAUNCHER .*)')
end

runner.run_async(function()
    local s = screen[1]
    s.scale = tonumber(os.getenv('SOMEWM_TEXT_TEST_SCALE') or '1')
    beautiful.hotkeys_rows = 5
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
    local function key(name)
        _keygrabber.inject(name,true); _keygrabber.inject(name,false)
        async.sleep(.05)
        return popup.widget:_scroll_record()
    end
    local function near(a,b) return math.abs(a-b)<.01 end
    local function traverse(expected,columns,label)
        local dump = awesome._clay_tree(s)
        local root = assert(launcher(dump))
        local _,overflows = root:gsub(' scroll=x scrolled=','')
        assert(overflows==1,'one horizontal overflow node')
        assert(not root:find('w=fit>=',1,true),'a column was told a minimum')
        assert(not root:find('derived',1,true))
        local _,margins = root:gsub('wibox%.container%.margin w=fit h=grow row pad %d+,0,0,0','')
        assert(margins==columns,'one FIT column per five rows: '..margins)
        local counts, boxes = entries(root)
        local count = 0
        for entry,n in pairs(counts) do assert(n==1,'entry repeated: '..entry); count=count+1 end
        assert(count==expected,'lost entries: '..count..' expected '..expected)
        assert(not counts.ENTRY999,'filtered group leaked into the columns')
        for _,b in ipairs(boxes) do
            local top = popup.y-s.geometry.y
            assert(b[1]>=top and b[1]+b[2]<=top+popup.height,'a record lies outside the popup height')
        end
        local _,markers = root:gsub('▽','')
        assert(markers==columns-2,'leftover markers: '..markers)
        assert(not root:find('Next Page',1,true) and not root:find('Prev Page',1,true))
        assert(popup._drawable._clay_wired[popup.widget:get_children()[1]],'first column lost its input binding')
        assert(#popup:find_widgets(10,10)>0)
        example.save(label..'-start',dump)

        local offset, content, viewport = key('Prior')
        assert(near(offset,0) and content>viewport*2,'the fixture must overflow by several viewports: '..table.concat({tostring(offset),tostring(content),tostring(viewport)},' '))
        local pages = 0
        repeat
            local previous = offset
            offset = key('Next')
            pages = pages+1
            assert(pages<=content/viewport+1,'unbounded page navigation')
            assert(near(offset,math.max(previous-viewport,viewport-content)),
                'Next did not scroll by one viewport: '..previous..' -> '..offset)
            assert(awesome._clay_tree(s):find(string.format('scroll=x scrolled=%g ',-offset),1,true))
        until near(offset,previous)
        assert(near(offset,viewport-content),'Next stopped before the end')
        example.save(label..'-end',awesome._clay_tree(s))
        assert(near(key('Prior'),math.min(offset+viewport,0)))
        assert(near(key('Next'),viewport-content))
        _keygrabber.inject('Escape',true); _keygrabber.inject('Escape',false)
        assert(not popup.visible)
    end
    traverse(102,21,'initial')
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
    assert(popup.width==380 and popup.height==240)
    assert(assert(awesome._clay_tree(s):match('  LAUNCHER [^\n]+'))
        :find('w=fixed(386) theme h=grow<=246 user',1,true))
    traverse(103,22,'refreshed')
    beautiful.launcher_width=nil
    bar:remove()

    for _,height in ipairs {20,140} do
        local h = help.new {width=100,height=height,border_width=3,font='Monospace 8',description_font='Monospace 8',
            bg='#204080',fg='#ffffff',shape=require('gears.shape').rectangle}
        h:_load_widget_settings()
        h:add_hotkeys {wide={{modifiers={},keys={a=string.rep('W',100)..' ENTRY001',b='ENTRY002'}}}}
        local shown = h:_create_wibox(s,{'wide'},false)
        shown:show();async.sleep(.08)
        local dump = awesome._clay_tree(s)
        local counts = entries(assert(launcher(dump)))
        assert(counts.ENTRY001==1 and counts.ENTRY002==1)
        example.save('oversized-first-'..height,dump)
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
    local imported_entries = entries(assert(launcher(awesome._clay_tree(s))))
    assert(imported_entries.ENTRY001==1 and imported_entries.ENTRY002==1)
    imported_box:hide()
    beautiful.hotkeys_rows = nil
    runner.done()
end)
