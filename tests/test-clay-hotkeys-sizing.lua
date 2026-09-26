-- Clay sizes hotkeys help within its centered WORKAREA attachment.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local beautiful = require('beautiful')
local help = require('awful.hotkeys_popup.widget')
local example = require('_clay_example')
local shape = require('gears.shape')
local function edge(value)
    return value < 0 and math.ceil(value-.5) or math.floor(value+.5)
end

runner.run_async(function()
    local s = screen[1]
    local scale = tonumber(os.getenv('SOMEWM_TEXT_TEST_SCALE') or '2')
    s.scale = scale
    async.sleep(.1)
    local width, height = math.floor(1280/scale+.5), math.floor(720/scale+.5)
    assert(s.geometry.width == width and s.geometry.height == height)
    local bar = awful.wibar {screen=s, position='top', height=60,
        widget=wibox.widget.textbox('reserved'), bg='#00ff00'}
    async.sleep(.1)
    assert(s.workarea.width == width and s.workarea.height == height-60)
    local cases = {
        {'below',width-1,height-61,3,width-6,height-66},
        {'equal',width,height-60,3,width-6,height-66},
        {'above',width+1,height-59,3,width-6,height-66},
        {'mixed',400,height,3,400,height-66},
        {'unclamped',400,140,3,400,140},
        {'no-border',width,height,0,width,height-60},
        {'override',width+1,height,3,420,height-66,420},
        {'false-override',width+1,height,3,width-6,height-66,false},
        {'override-overflow',width+1,height,3,width+80,height-66,width+80},
        {'defaults',nil,nil,3,1200<width and 1200 or width-6,800<height-60 and 800 or height-66},
    }
    for _, case in ipairs(cases) do
        local name,rw,rh,bw,ew,eh,override = unpack(case)
        beautiful.launcher_width = override
        local instance = help.new {width=rw,height=rh,border_width=bw,bg='#204080',fg='#ffffff',
            border_color='#ff0000',shape=shape.rectangle,font='Monospace 8',description_font='Monospace 8'}
        instance:_load_widget_settings()
        instance:add_hotkeys {commands={{modifiers={},keys={a='A command'}}}}
        local box = instance:_create_wibox(s, {'commands'}, false)
        box:show()
        async.sleep(.08)
        local p, origin = box.popup, s.geometry
        assert(p.width == ew and p.height == eh, name..': content dimensions')
        assert(p.x == origin.x+math.floor((width-ew)/2+.5)
            and p.y == origin.y+60+math.floor((height-60-eh)/2+.5), name..': WORKAREA center')
        local a = p.drawin.attachment
        assert(a.target == 0 and a.parent == 4 and a.own == 4)
        local dump = awesome._clay_tree(s)
        assert(dump:find(string.format('scale %.2f',scale),1,true))
        example.save('hotkeys-'..name,dump)
        local line = assert(dump:match('  LAUNCHER [^\n]+'))
        assert(line:find('attach ELEMENT',1,true))
        assert(not line:find('attach OUTPUT',1,true))
        assert(not line:find('available WORKAREA',1,true))
        assert(line:find(override and 'w=fixed('..(ew+2*bw)..')'
            or 'w=grow<='..((rw or 1200)+2*bw),1,true))
        assert(line:find('h=grow<='..((rh or 800)+2*bw),1,true))
        assert(line:find(' theme ',1,true))
        local x,y,w,h = line:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
        local left,top = (width-ew-2*bw)/2,60+(height-60-eh-2*bw)/2
        assert(tonumber(x)==edge(left) and tonumber(y)==edge(top), name..": "..line)
        assert(tonumber(w)==edge(left+ew+2*bw)-edge(left)
            and tonumber(h)==edge(top+eh+2*bw)-edge(top), name..": "..line)
        local column = p.widget:get_children()[1]
        local found = false
        for _,hit in ipairs(p:find_widgets(10,eh-2)) do
            if hit.widget == column then found = true; assert(hit.height==eh) end
        end
        assert(found, 'original column must retain its whole-height input allocation')
        example.pixel(origin.x+math.floor(width/2), p.y+eh-2, '#204080')
        if bw>0 then example.pixel(origin.x+math.floor(width/2),p.y-2,'#ff0000') end
        example.save('hotkeys-'..name,dump)
        box:hide()
    end
    beautiful.launcher_width = nil
    local instance = help.new {width=width+1,height=height+1,border_width=3,
        bg='#204080',fg='#ffffff',shape=shape.rectangle}
    instance:_load_widget_settings()
    instance:add_hotkeys {commands={{modifiers={},keys={a='A'}}}}
    local box = instance:_create_wibox(s, {'commands'}, false)
    box:show(); async.sleep(.08)
    local visible_widget = box.popup.widget
    bar.height = 100
    async.sleep(.08)
    assert(box.popup.height == height-106)
    assert(box.popup.y == s.geometry.y+103)
    assert(box.popup.widget ~= visible_widget, "workarea change retained stale pages")
    local previous_widget = box.popup.widget
    box:hide()
    local reopened_scale = scale==2 and 1.25 or 2
    s.scale = reopened_scale
    async.sleep(.1)
    box:show(); async.sleep(.08)
    local new_width,new_height = math.floor(1280/reopened_scale+.5),math.floor(720/reopened_scale+.5)
    local expected_width = width+1 < new_width and width+1 or new_width-6
    local expected_height = height+1 < new_height-100 and height+1 or new_height-106
    assert(box.popup.width==expected_width and box.popup.height==expected_height)
    assert(box.popup.widget~=previous_widget,'output change retained stale page descriptions')
    assert(awesome._clay_tree(s):find(string.format('scale %.2f',reopened_scale),1,true))
    example.save('hotkeys-reopened-output',awesome._clay_tree(s))
    box:hide(); bar:remove()

    for _,size in ipairs {{320,800},{1000,240}} do
        local name = awesome._test_add_output(size[1],size[2])
        local target
        assert(async.wait_for_condition(function()
            for candidate in screen do if candidate.output.name==name then target=candidate end end
            return target ~= nil
        end,2,.01))
        local reserved = awful.wibar {screen=target,position='top',height=60,widget=wibox.widget.textbox('bar')}
        async.sleep(.08)
        local h = help.new {width=1200,height=900,border_width=3,bg='#204080',fg='#ffffff',shape=shape.rectangle}
        h:_load_widget_settings(); h:add_hotkeys {commands={{modifiers={},keys={a='A'}}}}
        local shown = h:_create_wibox(target,{'commands'},false)
        shown:show(); async.sleep(.08)
        assert(shown.popup.width==size[1]-6 and shown.popup.height==size[2]-66)
        assert(shown.popup.x==target.geometry.x+3 and shown.popup.y==target.geometry.y+63)
        example.save('hotkeys-output-'..size[1]..'x'..size[2],awesome._clay_tree(target))
        shown:hide(); reserved:remove()
    end
    async.sleep(.1)
    runner.assert_no_errors()
    runner.done()
end)
