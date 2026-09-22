local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local check = require('_clay_capacity')
local presentation = require('_clay_grid_presentation')
local s = screen[1]
local pane = check.id('Clay__DebugViewOuterScrollPane')

runner.run_async(function()
    local host = awful.popup {screen=s, x=20, y=50, visible=true, shadow=false,
        maximum_width=800, widget=wibox.widget.textbox('calendar')}
    s.inspector = true
    for _, bottom in ipairs {false, true} do
        for cycle = 1, 3 do
            for _, kind in ipairs {'month', 'year'} do
                local calendar = wibox.widget.calendar[kind](nil, 'monospace 11')
                calendar.spacing = 5
                calendar.week_numbers = true
                calendar.date = {year=2026 + cycle, month=9, day=18}
                host.widget = calendar
                for _, font in ipairs {'monospace 11', 'monospace 14'} do
                    calendar.font = font
                    calendar.week_numbers = not calendar.week_numbers
                    awesome._test_redeclare()
                    if bottom then
                        local _, _, _, content, _, viewport = awesome._clay_scroll_get(s, pane)
                        assert(content and content > viewport, 'inspector lost scroll extent')
                        awesome._clay_scroll_set(s, pane, 0, viewport-content)
                        awesome._test_redeclare()
                    end
                    local dump, elements, map = check.check(s)
                    assert(s.inspector and dump:find('inspector on', 1, true))
                    presentation(host._drawable)
                    io.stderr:write(string.format('[CAPACITY] %s font=%s bottom=%s elements=%d map=%d\n',
                        kind, font, tostring(bottom), elements, map))
                    async.sleep(.01)
                end
            end
        end
    end
    host.visible = false
    s.inspector = false
    runner.done()
end)
