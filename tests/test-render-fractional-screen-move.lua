-- Real outputs exercise texture submission after mixed-DPI tasklist reflow.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local beautiful = require('beautiful')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local example = require('_clay_example')
local utils = require('_utils')

runner.run_async(function()
    assert(awesome._test_add_output(1200, 900), 'real second output required')
    assert(async.wait_for_condition(function() return screen.count() == 2 end, 5))
    local screens = {screen[1], screen[2]}
    screens[1].scale, screens[2].scale = 1, 1.5
    beautiful.font = 'sans 10'
    beautiful.bg_normal, beautiful.bg_focus = '#282828', '#3c3836'
    local bars = {}
    for i, s in ipairs(screens) do
        bars[i] = awful.wibar {screen=s, position='top', height=32, widget={
            layout=wibox.layout.fixed.horizontal,
            {text='tasks', forced_width=71, widget=wibox.widget.textbox},
            awful.widget.tasklist {screen=s, filter=awful.widget.tasklist.filter.currenttags},
        }}
    end
    local clients, reports = {}, {}
    for i = 1, 3 do
        reports[i] = os.tmpname()
        awful.spawn {assert(utils.binary_or_skip('./build-test/test-transient-client')),
            'RASTER_MOVE_'..i, reports[i]}
        clients[i] = async.wait_for_client('RASTER_MOVE_'..i, 5)
        local c = clients[i]
        c.floating, c.border_width, c.shadow = true, 0, false
        c.name = 'Fractional tasklist label '..i
        awful.titlebar.hide(c)
    end
    for move = 1, 24 do
        local c = clients[1 + (move % 3)]
        local s = screens[1 + (move % 2)]
        c:move_to_screen(s)
        c:geometry {x=s.geometry.x+80+move, y=s.geometry.y+80, width=240, height=160}
        c:activate {context='test', raise=true}
        bars[1].widget.children[1].forced_width = 71 + move % 4
        bars[2].widget.children[1].forced_width = 71 + move % 4
        async.sleep(0.08)
        awesome._test_redeclare()
        assert(c.screen == s and c:isvisible(), 'client did not migrate')
        local g = c:geometry()
        assert(g.width == 240 and g.height == 160, 'logical allocation changed')
        local f = assert(io.open(reports[1 + move % 3]))
        local configured = f:read('*a'); f:close()
        assert(configured == '240 160\n', 'client configure: '..configured)
        -- Read the composited client, independently of the tree dump.
        local im = surface(s.content)
        local x = math.floor((g.x-s.geometry.x+120)*s.scale)
        local y = math.floor((g.y-s.geometry.y+80)*s.scale)
        local r, green, b = capture.read(im, x, y)
        assert(r == 64 and green == 64 and b == 64, 'client pixels lost on migration')
        for _, output_screen in ipairs(screens) do
            local dump = awesome._clay_tree(output_screen)
            assert(not dump:find('[tree!=scene]', 1, true), dump)
            assert(dump:find('TEXT', 1, true), 'tasklist/bar text disappeared')
        end
        if move == 24 then
            for i, output_screen in ipairs(screens) do
                example.save('fractional-output-'..i, awesome._clay_tree(output_screen))
            end
        end
    end
    for _, c in ipairs(clients) do c:kill() end
    for _, bar in ipairs(bars) do bar:remove() end
    for _, path in ipairs(reports) do os.remove(path) end
    io.stderr:write('[PASS] 24 migrations: scales 1/1.5, tasklist reflow, configure sizes, pixels and tree==scene\n')
    runner.done()
end)
