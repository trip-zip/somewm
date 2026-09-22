local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local check = require('_clay_capacity')
local s = screen[1]

local function children(count, overflow)
    local layout = overflow and wibox.layout.overflow.vertical() or wibox.layout.fixed.vertical()
    for _ = 1, count do
        layout:add(wibox.widget {forced_height=2, bg='#cc3322', widget=wibox.container.background})
    end
    return layout
end

runner.run_async(function()
    local hosts = {}
    for i = 1, 5 do
        hosts[i] = wibox {screen=s, x=20+(i-1)*165, y=100, width=160, height=100,
            visible=true, widget=children(1999, i==5)}
    end
    awesome._test_redeclare()
    local dump, elements = check.check(s)
    assert(elements > 8192, 'fixture did not exceed the old context capacity')
    local total = 0
    for _, host in ipairs(hosts) do
        assert(host._drawable._clay_tree)
        total = total + check.count(host._drawable._clay_tree)
    end
    local scroll = hosts[5].widget
    scroll.scroll_factor = .5
    awesome._test_redeclare()
    local record = {scroll._private.drawable:_clay_scroll_get(scroll._private.content.id)}
    assert(record[2] and record[2] < 0, 'large fixture did not scroll')
    local hits = hosts[5]:find_widgets(5,5)
    assert(#hits > 0)
    for cycle = 1, 8 do
        hosts[1].widget = children(1999)
        s.inspector = cycle % 2 == 0
        awesome._test_redeclare()
        dump, elements = check.check(s)
        assert(elements > 8192)
        local after = {scroll._private.drawable:_clay_scroll_get(scroll._private.content.id)}
        assert(after[2] == record[2], 'ID churn reset scrolling')
        assert(#hosts[5]:find_widgets(5,5) == #hits, 'ID churn changed unchanged input mappings')
        io.stderr:write(string.format('[LARGE] cycle=%d %s\n', cycle, dump:match('[^\n]+')))
        async.sleep(.01)
    end
    local sixth = wibox {screen=s, x=20, y=220, width=160, height=100,
        visible=true, widget=children(2047)}
    awesome._test_redeclare()
    assert(sixth._drawable._clay_tree, '12048 nodes plus small overflow overhead should be admitted')
    total = total + check.count(sixth._drawable._clay_tree)
    assert(total <= 12288 and total+401 > 12288, 'incorrect budget fixture arithmetic: '..total)
    local refused = wibox {screen=s, x=200, y=220, width=160, height=100,
        visible=true, widget=children(400)}
    awesome._test_redeclare()
    dump = check.check(s)
    assert(dump:find("over the output's element budget", 1, true), dump)
    for _, host in ipairs(hosts) do assert(host._drawable._clay_tree) end
    io.stderr:write(string.format('[LARGE] admitted widget nodes=%d refused additional=401\n', total))
    refused.visible, sixth.visible = false, false
    for _, host in ipairs(hosts) do host.visible=false end
    s.inspector=false
    runner.done()
end)
