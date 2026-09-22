local runner=require('_runner')
local async=require('_async')

runner.run_async(function()
    awesome._test_clay_capacity(64,2)
    local name=awesome._test_add_output(640,480)
    local s
    assert(async.wait_for_condition(function()
        for candidate in screen do
            if candidate.output and candidate.output.name==name then s=candidate end
        end
        return s ~= nil
    end,2,.01), 'new output missing after rejected context allocation')
    async.sleep(.15)
    assert(not awesome._clay_tree(s), 'allocation failure unexpectedly created a context')
    awesome._clay_dirty()
    assert(async.wait_for_condition(function()
        return awesome._clay_tree(s) and awesome._clay_tree(s):find('elements',1,true)
    end,2,.01), 'output did not recover after allocation failure')
    local function frames()
        return tonumber(awesome._clay_tree(s):match(' frames (%d+)'))
    end
    local wibox=require('wibox')
    local content=wibox.layout.fixed.vertical()
    for _=1,31 do
        content:add(wibox.widget {forced_height=2, bg='#cc3322', widget=wibox.container.background})
    end
    local host=wibox {screen=s, x=s.geometry.x+10, y=s.geometry.y+10,
        width=100, height=100, visible=true, widget=content}
    awesome._test_redeclare()
    local elements,capacity=awesome._clay_tree(s):match('elements (%d+)/(%d+)')
    assert(tonumber(elements)>=32 and tonumber(capacity)==64, 'fixture did not reach the small context')
    local before=frames()
    local closed=0
    s:connect_signal('property::inspector',function()
        if not s.inspector then closed=closed+1 end
    end)
    s.inspector=true
    assert(async.wait_for_condition(function() return closed==1 end,2,.01), 'small context did not exhaust in the inspector')
    async.sleep(.15)
    assert(not s.inspector)
    assert(frames()==before+2, 'inspector exhaustion did not use exactly one retry')
    local idle=frames()
    async.sleep(.25)
    assert(frames()==idle, 'allocation or inspector exhaustion loops while idle')
    assert(awesome._clay_tree(s):find('inspector off',1,true))
    host.visible=false
    awesome._test_clay_capacity(32768)
    runner.done()
end)
