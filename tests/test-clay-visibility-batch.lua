-- A frame that adds thousands of nodes must toggle the output tree once, not
-- let wlroots walk the scene per node. The cursor is an IMAGE command on every
-- output, and the batch used to refuse any frame that had one.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local s = screen[1]

runner.run_async(function()
    local host = awful.popup {screen=s, x=20, y=50, visible=true, shadow=false,
        maximum_width=800, widget=wibox.widget.textbox('calendar')}
    s.inspector = true
    local calendar = wibox.widget.calendar.year(nil, 'monospace 14')
    calendar.week_numbers = true
    calendar.date = {year=2027, month=9, day=18}
    host.widget = calendar
    awesome._test_redeclare()
    local dump = awesome._clay_tree(s)
    local created = tonumber(dump:match(' created (%d+) '))
    assert(created and created > 10000, dump:match('[^\n]*\n[^\n]*'))
    assert(dump:find(' batched 1 ', 1, true), dump:match('[^\n]*\n[^\n]*'))
    assert(dump:find('IMAGE', 1, true), 'the cursor is in the frame')

    -- Nothing changed: no membership change, so no toggle.
    awesome._test_redeclare()
    dump = awesome._clay_tree(s)
    assert(dump:find(' created 0 ', 1, true) and dump:find(' batched 0 ', 1, true),
        dump:match('[^\n]*\n[^\n]*'))

    s.inspector = false
    host.visible = false
    runner.done()
end)
