-- Stock spiral/dwindle membership, paint and configure behavior.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local utils = require('_utils')
local example = require('_clay_example')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s = screen[1]

runner.run_async(function()
    local clients, reports, failures = {}, {}, {}
    local colors = {'ffcc0000', 'ff00cc00', 'ff0000cc', 'ffcccc00', 'ffcc00cc', 'ff00cccc'}
    s.selected_tag.layout = awful.layout.suit.tile
    for count = 0, 6 do
        if count > 0 then
            local report = os.tmpname()
            reports[count] = report
            awful.spawn {binary, 'SPIRAL_' .. count, report, '0', colors[count]}
            for _ = 1, 30 do
                clients[count] = utils.find_client_by_class('SPIRAL_' .. count)
                if clients[count] then break end
                async.sleep(0.02)
            end
            local c = assert(clients[count], 'client did not map')
            c.floating, c.shadow, c.border_width = false, false, 1
        end
        for i, wanted in ipairs(clients) do
            local current = awful.client.tiled(s)[i]
            if current ~= wanted then current:swap(wanted) end
        end
        for _, kind in ipairs {'spiral', 'dwindle'} do
            s.selected_tag.layout = kind == 'spiral' and awful.layout.suit.spiral or awful.layout.suit.spiral.dwindle
            for _, gap in ipairs {0, 8} do
                s.selected_tag.gap, s.selected_tag.gap_single_client = gap, true
                for _, factor in ipairs {0.25, 0.5, 0.75} do
                    s.selected_tag.master_width_factor = factor
                    async.sleep(0.10)
                    local name = string.format('%s-%d-gap%d-factor%d', kind, count, gap, factor * 100)
                    local dump = awesome._clay_tree(s)
                    if not dump:find('derived 0', 1, true) then failures[#failures + 1] = name end
                    local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
                    local report = dir and assert(io.open(dir .. '/' .. name .. '.geometry', 'w'))
                    for i, c in ipairs(clients) do
                        local g = c:geometry()
                        local f = assert(io.open(reports[i]))
                        local w, h = f:read('*a'):match('(%d+)%s+(%d+)')
                        f:close()
                        assert(tonumber(w) and tonumber(h), 'missing configure')
                        local sw, sh
                        for line in dump:gmatch('[^\n]+') do
                            if line:match('^%s+SURFACE ' .. c.class .. ' ') then
                                sw, sh = line:match('box %-?%d+,%-?%d+ (%d+)x(%d+)')
                                break
                            end
                        end
                        assert(w == sw and h == sh, 'configure differs from solved surface: ' .. name .. ' ' .. c.class)
                        example.pixel(g.x + math.floor(g.width / 2), g.y + math.floor(g.height / 2), '#' .. colors[i]:sub(3))
                        if report then report:write(string.format('%s %d %d %d %d configure %s %s\n', c.class, g.x, g.y, g.width, g.height, w, h)) end
                    end
                    if report then report:close() end
                    example.save(name, dump)
                end
            end
        end
        if count > 0 and count <= 3 then
            local titles, events = {}, {}
            for i, c in ipairs(clients) do
                local widget = wibox.container.background(nil, '#cc6600')
                local bar = awful.titlebar(c, {size = 24})
                bar.widget = widget
                titles[i] = bar
                for _, signal in ipairs {'button::press', 'button::release'} do
                    widget:connect_signal(signal, function(original, x, y, button, mods, area)
                        assert(original == widget and area.widget == widget)
                        -- Existing titlebar signals are client-relative and
                        -- include the border origin (objects/button.c).
                        assert(x == 6 and y == 6 and button == 1 and #mods == 0,
                            string.format('titlebar local coordinates: %g,%g button %s modifiers %d', x, y, tostring(button), #mods))
                        events[#events + 1] = signal .. i
                    end)
                end
            end
            for _, kind in ipairs {'spiral', 'dwindle'} do
                s.selected_tag.layout = kind == 'spiral' and awful.layout.suit.spiral or awful.layout.suit.spiral.dwindle
                s.selected_tag.gap, s.selected_tag.master_width_factor = 8, 0.5
                async.sleep(0.15)
                local name = kind .. '-' .. count .. '-titlebars'
                for i, c in ipairs(clients) do
                    local g = c:geometry()
                    example.pixel(g.x + 6, g.y + 6, '#cc6600')
                    events = {}
                    awful.spawn {pointer, 'click', tostring(g.x + 6), tostring(g.y + 6), '1280', '720', 'left'}
                    for _ = 1, 30 do if #events == 2 then break end; async.sleep(0.02) end
                    assert(table.concat(events, ',') == 'button::press' .. i .. ',button::release' .. i,
                        'original titlebar input changed: ' .. table.concat(events, ','))
                    local dump = awesome._clay_tree(s)
                    local f = assert(io.open(reports[i]))
                    local w, h = f:read('*a'):match('(%d+)%s+(%d+)')
                    f:close()
                    local sw, sh = dump:match('SURFACE ' .. c.class .. ' [^\n]-box %-?%d+,%-?%d+ (%d+)x(%d+)')
                    assert(w == sw and h == sh, 'titlebar configure differs from solved surface')
                end
                example.save(name, awesome._clay_tree(s))
            end
            for _, c in ipairs(clients) do awful.titlebar.hide(c) end
        end
    end
    s.inspector = true
    async.sleep(0.15)
    example.save('spiral-layout-inspector', awesome._clay_tree(s))
    s.inspector = false
    for _, c in ipairs(clients) do c:kill() end
    for _, report in ipairs(reports) do os.remove(report) end
    io.stderr:write('[PASS] both spiral variants at 0..6 clients, two gaps and three master factors; titlebars at 1/2/3 clients, original real input and solved configure equality\n')
    assert(#failures == 0, 'non-native spiral declarations: ' .. table.concat(failures, ', '))
    runner.done()
end)
