-- Exercise native carousel policy through solved tile slots and real wheel input.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local carousel = awful.layout.suit.carousel
local native = carousel._native
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s = screen[1]

runner.run_async(function()
    local clients, reports, columns = {}, {}, {}
    local root, solved = nil, 0
    local inputs = {columns = columns, viewport_extent = 1280, gap = 0, peek = 0}
    local fixture = {name = 'native-carousel-state', arrange = function() end,
        _clay = function()
            root = carousel._build_declarations(inputs)
            root.solved = function(tree)
                assert(tree == root and tree.box and tree.strip.box)
                if #tree.columns > 1 then assert(tree.columns[2].box) end
                solved = solved + 1
            end
            return root
        end}
    s.selected_tag.layout = fixture
    assert(s.geometry.width == 1280 and s.geometry.height == 720)
    assert(s.workarea.width == 1280 and s.workarea.height == 720)
    for i = 1, 3 do
        reports[i] = os.tmpname()
        awful.spawn {binary, 'STATE_' .. i, reports[i], '0', 'ff336699', '0'}
        assert(async.wait_for_condition(function()
            clients[i] = utils.find_client_by_class('STATE_' .. i)
            return clients[i] ~= nil
        end, 2, .02), 'client did not map')
        local c = clients[i]
        c.floating, c.shadow, c.border_width, c.size_hints_honor = false, false, 1, true
        columns[i] = {clients = {c}, width_fraction = .75}
    end

    local function diagnostic(dump)
        local lines = {}
        for line in dump:gmatch('[^\n]+') do
            if line:match('^%s*CLIENT ') then lines[#lines + 1] = line end
        end
        lines[#lines + 1] = 'scroll: ' .. table.concat({awesome._clay_scroll_get(s, root.id)}, ' ')
        return table.concat(lines, '\n')
    end

    local function solve(name, expected, record)
        local before = solved
        awful.layout.arrange(s)
        async.sleep(.15)
        local dump = awesome._clay_tree(s)
        example.save(name, dump)
        assert(solved > before, 'solved callback did not run')
        assert(dump:find('derived 0', 1, true), dump)
        assert(not dump:find('[tree!=scene]', 1, true), dump)
        local actual = {}
        for line in dump:gmatch('[^\n]+') do
            if line:match('^%s*CLIENT ') then
                local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
                actual[#actual + 1] = table.concat({x, y, w, h}, ',')
            end
        end
        if expected then
            assert(#actual == #expected, name .. '\n' .. diagnostic(dump))
            for i, box in ipairs(expected) do
                assert(actual[i] == table.concat(box, ','), name .. '\n' .. diagnostic(dump))
            end
        end
        if record then
            assert(table.concat({awesome._clay_scroll_get(s, root.id)}, ',') ==
                table.concat(record, ','), name .. '\n' .. diagnostic(dump))
            assert(root.scroll.x == record[1] and root.scroll.y == record[2], diagnostic(dump))
        end
        return dump
    end

    local function horizontal(a, b, c)
        return {{a,0,960,720}, {b,0,960,720}, {c,0,960,720}}
    end
    local function follow(i, mode, a, b, c, r)
        native.follow(s, root, i, mode, 0)
        solve(mode .. '-' .. i, horizontal(a,b,c), {r,0,2880,720,1280,720})
    end
    solve('initial', horizontal(0,960,1920), {0,0,2880,720,1280,720})
    assert(root.strip.box.x == 0)
    follow(2, 'on-overflow', -800,160,1120, -800)
    follow(3, 'on-overflow', -1600,-640,320, -1600)
    follow(2, 'on-overflow', -800,160,1120, -800)
    follow(1, 'on-overflow', 0,960,1920, 0)

    awesome._clay_scroll_set(s, root.id, 0, 0)
    solve('never-reset', horizontal(0,960,1920))
    follow(2, 'never', 0,960,1920, 0)
    follow(3, 'never', -1600,-640,320, -1600)
    awesome._clay_scroll_set(s, root.id, 0, 0)
    solve('edge-reset', horizontal(0,960,1920))
    follow(2, 'edge', -640,320,1280, -640)

    inputs.lead, inputs.trail = 160, 160
    awesome._clay_scroll_set(s, root.id, 0, 0)
    solve('always-margins', horizontal(160,1120,2080), {0,0,3200,720,1280,720})
    native.follow(s, root, 3, 'always', 0)
    solve('always-last', horizontal(-1760,-800,160), {-1920,0,3200,720,1280,720})
    native.follow(s, root, 1, 'always', 0)
    solve('always-first', horizontal(160,1120,2080), {0,0,3200,720,1280,720})

    inputs.lead, inputs.trail = 0, 0
    clients[2].hidden, clients[3].hidden = true, true
    inputs.columns = {{clients = {clients[1]}, width_fraction = .5}}
    solve('short-strip', {{320,0,640,720}}, {0,0,640,720,1280,720})
    clients[2].hidden, clients[3].hidden = false, false
    inputs.columns = columns
    awesome._clay_scroll_set(s, root.id, 0, 0)
    solve('pan-reset', horizontal(0,960,1920))
    native.pan(s, root, 300)
    solve('pan-300', horizontal(-300,660,1620), {-300,0,2880,720,1280,720})
    assert(native.nearest(s, root) == 1)
    native.pan(s, root, -1000)
    solve('pan-before-start', horizontal(0,960,1920), {0,0,2880,720,1280,720})
    native.pan(s, root, 5000)
    solve('pan-after-end', horizontal(-1600,-640,320), {-1600,0,2880,720,1280,720})
    assert(native.nearest(s, root) == 3)

    inputs.vertical, inputs.viewport_extent, inputs.gap = true, 720, 8
    awesome._clay_scroll_set(s, root.id, 0, 0)
    solve('wheel-reset', {{8,8,1264,524}, {8,548,1264,524}, {8,1088,1264,524}},
        {0,0,1280,1620,1280,720})
    local function wheel(y)
        local finished = false
        awful.spawn.easy_async({pointer, 'scroll', '640', tostring(y), '1280', '720', 'down'},
            function(_, _, _, code)
                assert(code == 0, 'pointer client failed')
                finished = true
            end)
        assert(async.wait_for_condition(function() return finished end, 2, .02))
        local _, position = awesome._clay_scroll_get(s, root.id)
        io.stderr:write('wheel y=' .. y .. ' record=' .. tostring(position) .. '\n')
    end
    wheel(4)
    solve('wheel-gap', {{8,-22,1264,524}, {8,518,1264,524}, {8,1058,1264,524}},
        {0,-30,1280,1620,1280,720})
    wheel(300)
    solve('wheel-client', {{8,-22,1264,524}, {8,518,1264,524}, {8,1058,1264,524}},
        {0,-30,1280,1620,1280,720})

    local before = awesome._clay_tree(s)
    native.pan(s, root, 0)
    native.follow(s, root, 1, 'never', 0)
    async.sleep(.5)
    local after = awesome._clay_tree(s)
    local function frames(dump)
        return assert(dump:match('output %S+ scale [^\n]* frames (%d+)'), dump)
    end
    assert(frames(before) == frames(after), before .. '\n' .. after)

    s.selected_tag.layout = awful.layout.suit.tile
    for _, c in ipairs(clients) do c:kill() end
    for _, report in ipairs(reports) do os.remove(report) end
    io.stderr:write('[PASS] native carousel state: focus modes, margins, centring, pan, nearest, wheel and idle\n')
    runner.done()
end)
