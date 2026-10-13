-- A centred awful.popup is a corner attachment sized by its widget at the popup band.
local runner = require('_runner')
local async = require('_async')
local gears = require('gears')
local awful = require('awful')
local wibox = require('wibox')
local example = require('_clay_example')

runner.run_async(function()
    async.sleep(0.01)
    local s = screen[1]
    local wa = s.workarea
    local popup = awful.popup {screen = s, visible = true, ontop = true,
        bg = '#ff0000', border_width = 0, shadow = false,
        placement = awful.placement.centered,
        widget = {widget = wibox.widget.textbox, text = 'centred',
            forced_width = 400, forced_height = 40}}
    gears.timer.run_delayed_calls_now()
    awesome._test_redeclare()
    local dump = awesome._clay_tree(s)
    assert(dump:match('derived 0 legacy 0'), dump)
    assert(not dump:find('LAUNCHER', 1, true), dump)
    local line = assert(dump:match('\n(  POPUP [^\n]*)'), 'POPUP root missing:\n' .. dump)
    assert(line:find('band 80', 1, true), line)
    assert(line:find('parent CENTER own CENTER', 1, true), line)
    local x, y, w, h = line:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    assert(w == 400 and h == 40, line)
    assert(math.abs((x - wa.x) - (wa.x + wa.width - x - w)) <= 1, line)
    assert(math.abs((y - wa.y) - (wa.y + wa.height - y - h)) <= 1, line)
    assert(awesome._test_redeclare() == 0, 'the next frame changed the scene')
    example.save('centered-popup', dump)
    io.stderr:write('[CENTERED] ', line, '\n')
    popup.visible = false
    io.stderr:write('[PASS] centred popup is a 400x40 POPUP at band 80 in the workarea centre\n')
    runner.done()
end)
