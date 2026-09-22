-- Native percent slots retain their area when a protocol minimum overhangs.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local report, other_report = os.tmpname(), os.tmpname()

runner.run_async(function()
    local s, a, b = screen[1]
    awful.spawn {binary, 'SPIRAL_HINT_A', report, '900', 'ffcc0000'}
    awful.spawn {binary, 'SPIRAL_HINT_B', other_report, '0', 'ff0000cc'}
    for _ = 1, 40 do
        a, b = utils.find_client_by_class('SPIRAL_HINT_A'), utils.find_client_by_class('SPIRAL_HINT_B')
        if a and b then break end
        async.sleep(0.02)
    end
    assert(a and b)
    for _, c in ipairs {a, b} do c.floating, c.shadow, c.border_width = false, false, 1 end
    a.size_hints_honor = true
    if awful.client.tiled(s)[1] ~= a then a:swap(b) end
    s.selected_tag.gap, s.selected_tag.master_width_factor = 0, 0.5
    local failures, events = {}, {}
    for _, c in ipairs {a, b} do
        for _, signal in ipairs {'button::press', 'button::release'} do
            c:connect_signal(signal, function(original, x, y, button, mods)
                assert(original == c and button == 1 and #mods == 0)
                local g = c:geometry()
                assert(x == 700 - g.x and y == 100 - g.y)
                events[#events + 1] = signal .. ':' .. c.class
            end)
        end
    end
    for _, layout in ipairs {awful.layout.suit.spiral, awful.layout.suit.spiral.dwindle} do
        s.selected_tag.layout = layout
        async.sleep(0.15)
        local dump = awesome._clay_tree(s)
        example.save(layout.name .. '-protocol-minimum', dump)
        local line = assert(dump:match('SURFACE SPIRAL_HINT_A [^\n]+'))
        local width = tonumber(line:match('box %-?%d+,%-?%d+ (%d+)x'))
        local f = assert(io.open(report))
        local configured = tonumber(f:read('*a'):match('(%d+)'))
        f:close()
        assert(width == 900 and configured == width, 'protocol minimum was not configured from the solved surface')
        if not dump:find('CLIENT SPIRAL_HINT_A w=percent(0.5)', 1, true)
                or not dump:match('CLIENT SPIRAL_HINT_A [^\n]-box 0,0 640x720') then
            failures[#failures + 1] = layout.name
        end
        assert(line:find('w=grow>=900', 1, true), 'protocol floor is absent from the real surface')
        example.pixel(10, 100, '#cc0000')
        example.pixel(1000, 100, '#0000cc')
        -- Ordinary native flow paints the second client after the first.
        -- Save baseline differences without hiding the remaining checks.
        if not pcall(example.pixel, 700, 100, '#0000cc') then
            failures[#failures + 1] = layout.name .. '-overhang-paint'
        end
        events = {}
        awful.spawn {pointer, 'click', '700', '100', '1280', '720', 'left'}
        for _ = 1, 30 do if #events == 2 then break end; async.sleep(0.02) end
        local got = table.concat(events, ',')
        if got ~= 'button::press:SPIRAL_HINT_B,button::release:SPIRAL_HINT_B' then
            failures[#failures + 1] = layout.name .. '-overhang-input'
        end
        local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        if dir then
            local f = assert(io.open(dir .. '/' .. layout.name .. '-overhang-input.txt', 'w'))
            f:write(got, '\n'); f:close()
        end
    end
    a:kill(); b:kill(); os.remove(report); os.remove(other_report)
    assert(#failures == 0, 'native percent allocation differs: ' .. table.concat(failures, ', '))
    runner.done()
end)
