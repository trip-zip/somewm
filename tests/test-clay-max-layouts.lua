-- Native max/fullscreen layout attachments retain stacking, input and sizing.
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
    local colors = {'ffcc0000', 'ff00cc00', 'ff0000cc'}
    local top = awful.wibar {screen=s, position='top', height=32, bg='#777777'}
    top.widget = wibox.container.background()
    local left = awful.wibar {screen=s, position='left', width=24, bg='#777777'}
    left.widget = wibox.container.background()
    s.selected_tag.layout = awful.layout.suit.max
    for count = 0, 3 do
        if count > 0 then
            reports[count] = os.tmpname()
            awful.spawn {binary, 'MAX_' .. count, reports[count], count == 1 and '1400' or '0', colors[count]}
            for _ = 1, 30 do
                clients[count] = utils.find_client_by_class('MAX_' .. count)
                if clients[count] then break end
                async.sleep(0.02)
            end
            local c = assert(clients[count], 'client did not map')
            c.floating, c.shadow, c.border_width = false, false, 1
            c.size_hints_honor = false
            awful.titlebar(c, {size=24}).widget = wibox.container.background(nil, '#cc6600')
        end
        for _, kind in ipairs {'max', 'fullscreen'} do
            s.selected_tag.layout = kind == 'max' and awful.layout.suit.max or awful.layout.suit.max.fullscreen
            for _, gap in ipairs {0, 8} do
                s.selected_tag.gap = gap
                s.selected_tag.gap_single_client = true
                for _, height in ipairs {32, 48} do
                    top.height = height
                    async.sleep(0.12)
                    local area = kind == 'max' and s.workarea or s.geometry
                    local name = string.format('%s-%d-gap%d-bar%d', kind, count, gap, height)
                    local dump = awesome._clay_tree(s)
                    if not dump:find('derived 0', 1, true) then failures[#failures+1] = name end
                    local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
                    local report = dir and assert(io.open(dir .. '/' .. name .. '.geometry', 'w'))
                    for i, c in ipairs(clients) do
                        local g = c:geometry()
                        assert(g.x == area.x + gap and g.y == area.y + gap and g.width + 2 + 2*gap == area.width and g.height + 2 + 2*gap == area.height,
                            name .. ': client frame differs from attachment area')
                        local f = assert(io.open(reports[i]))
                        local w,h = f:read('*a'):match('(%d+)%s+(%d+)'); f:close()
                        local sw,sh = dump:match('SURFACE ' .. c.class .. ' [^\n]-box %-?%d+,%-?%d+ (%d+)x(%d+)')
                        assert(w == sw and h == sh, name .. ': configure differs from solved surface')
                        if report then report:write(string.format('%s %d %d %d %d configure %s %s\n', c.class, g.x,g.y,g.width,g.height,w,h)) end
                    end
                    if report then report:close() end
                    example.save(name,dump)
                end
            end
            for i, c in ipairs(clients) do
                client.focus = c
                c:raise()
                async.sleep(0.08)
                local g = c:geometry()
                local x,y = g.x + 100, g.y + 100
                example.pixel(x,y,'#' .. colors[i]:sub(3))
                local events = {}
                local function press(original,lx,ly,button)
                    assert(original == c and lx == 100 and ly == 100 and button == 1)
                    events[#events+1] = 'press'
                end
                local function release(original,lx,ly,button)
                    assert(original == c and lx == 100 and ly == 100 and button == 1)
                    events[#events+1] = 'release'
                end
                c:connect_signal('button::press',press)
                c:connect_signal('button::release',release)
                awful.spawn {pointer,'click',tostring(x),tostring(y),'1280','720','left'}
                for _ = 1,30 do if #events == 2 then break end; async.sleep(0.02) end
                assert(table.concat(events,',') == 'press,release',kind .. ': raised original client did not receive input')
                c:disconnect_signal('button::press',press)
                c:disconnect_signal('button::release',release)
                example.save(kind .. '-' .. count .. '-raise' .. i,awesome._clay_tree(s))
            end
        end
    end
    for _, kind in ipairs {'max', 'fullscreen'} do
        s.selected_tag.layout = kind == 'max' and awful.layout.suit.max or awful.layout.suit.max.fullscreen
        s.selected_tag.gap = 8
        s.selected_tag.gap_single_client = false
        async.sleep(0.12)
        local area = kind == 'max' and s.workarea or s.geometry
        for _, c in ipairs(clients) do
            local g = c:geometry()
            assert(g.x == area.x and g.y == area.y and g.width + 2 == area.width and g.height + 2 == area.height,
                'skip_gap must suppress max/fullscreen gaps when gap_single_client is false')
        end
        example.save(kind .. '-skip-gap', awesome._clay_tree(s))
    end
    clients[1].size_hints_honor = true
    clients[1]:raise()
    for _, kind in ipairs {'max', 'fullscreen'} do
        s.selected_tag.layout = kind == 'max' and awful.layout.suit.max or awful.layout.suit.max.fullscreen
        for _, gap in ipairs {0, 8} do
            s.selected_tag.gap, s.selected_tag.gap_single_client = gap, true
            async.sleep(0.12)
            local dump = awesome._clay_tree(s)
            local line = assert(dump:match('SURFACE MAX_1 [^\n]+'))
            local width = tonumber(line:match('box %-?%d+,%-?%d+ (%d+)x'))
            local f = assert(io.open(reports[1]))
            local configured = tonumber(f:read('*a'):match('(%d+)')); f:close()
            assert(width == 1400 and configured == width and line:find('w=grow>=1400',1,true),
                'native surface protocol floor/configure changed')
            example.pixel(1100,100,'#cc0000')
            example.save(kind .. '-gap' .. gap .. '-protocol-minimum',dump)
        end
    end
    s.inspector = true
    async.sleep(0.15)
    example.save('max-layout-inspector',awesome._clay_tree(s))
    s.inspector = false
    for _,c in ipairs(clients) do c:kill() end
    for _,report in ipairs(reports) do os.remove(report) end
    top.visible,left.visible = false,false
    io.stderr:write('[PASS] max/fullscreen 0..3 clients, gaps, moving bars, titlebars, configures, raise paint and original real input\n')
    assert(#failures == 0,'non-native max declarations: ' .. table.concat(failures,', '))
    runner.done()
end)
