-- Exercise the private strip through the production client declaration bridge.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local carousel = awful.layout.suit.carousel
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s = screen[1]

local function boxes(dump, role)
    local result = {}
    for line in dump:gmatch('[^\n]+') do
        if line:match('^%s*' .. role .. ' ') then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            result[#result + 1] = {tonumber(x), tonumber(y), tonumber(w), tonumber(h)}
        end
    end
    return result
end

local function expect(dump, role, wanted)
    local actual = boxes(dump, role)
    assert(#actual == #wanted, role .. ' count: ' .. #actual)
    for i, box in ipairs(wanted) do
        assert(table.concat(actual[i], ',') == table.concat(box, ','),
            role .. ' ' .. i .. ': ' .. table.concat(actual[i], ',') ..
            ' expected ' .. table.concat(box, ','))
    end
end

runner.run_async(function()
    local clients, reports = {}, {}
    local events = {}
    local colors = {'ffcc0000', 'ff00cc00', 'ff0000cc'}
    local inputs = setmetatable({columns = {}, viewport_extent = 1280}, {
        __index = function(_, key)
            assert(key ~= 'col_positions' and key ~= 'workarea' and key ~= 'scroll_offset',
                'builder read legacy layout state: ' .. key)
        end,
    })
    local inset = 0
    local root
    local fixture = {name = 'private-strip-fixture', arrange = function() end,
        _clay = function()
            local tree = carousel._build_declarations(inputs)
            root = tree
            if inset == 0 then return tree end
            tree.role = 'CAROUSEL_VIEWPORT'
            return {role = 'WORKAREA', direction = 'row', padding = inset, children = {tree}}
        end}
    s.selected_tag.layout = fixture
    assert(type(carousel._clay) == 'function' and type(carousel.vertical._clay) == 'function',
        'both public carousel orientations must declare native trees')

    local function solve(name)
        awful.layout.arrange(s)
        async.sleep(.15)
        local dump = awesome._clay_tree(s)
        example.save(name, dump)
        assert(dump:find('derived 0', 1, true), dump)
        assert(not dump:find('[tree!=scene]', 1, true), dump)
        for i, c in ipairs(clients) do
            local w, h = dump:match('SURFACE ' .. c.class .. ' [^\n]-box %-?%d+,%-?%d+ (%d+)x(%d+)')
            local f = assert(io.open(reports[i]))
            local cw, ch = f:read('*a'):match('(%d+)%s+(%d+)')
            f:close()
            assert(cw == w and ch == h, 'configure differs from solved surface: ' .. c.class)
        end
        return dump
    end

    local empty = solve('empty-strip')
    expect(empty, 'CAROUSEL_STRIP', {{640, 0, 0, 720}})
    expect(empty, 'CAROUSEL_COLUMN', {})
    for i = 1, 3 do
        reports[i] = os.tmpname()
        awful.spawn {binary, 'STRIP_' .. i, reports[i], i == 1 and '800' or '0',
            colors[i], i == 1 and '500' or '0'}
        for _ = 1, 50 do
            clients[i] = utils.find_client_by_class('STRIP_' .. i)
            if clients[i] then break end
            async.sleep(.02)
        end
        local c = assert(clients[i], 'client did not map')
        c.floating, c.shadow, c.border_width, c.size_hints_honor = false, false, 1, true
        c:connect_signal('button::press', function(original)
            events[#events + 1] = original
        end)
    end
    local grouped = {
        {clients = {clients[1], clients[2]}, width_fraction = .5},
        {clients = {clients[3]}, width_fraction = 1},
    }
    inputs.columns = grouped
    local expected = {
        horizontal = {
            [0] = {{0,0,640,360}, {0,360,640,360}, {640,0,1280,720}},
            [8] = {{8,8,624,344}, {8,368,624,344}, {648,8,1264,704}},
        },
        vertical = {
            [0] = {{0,0,640,360}, {640,0,640,360}, {0,360,1280,720}},
            [8] = {{8,8,624,344}, {648,8,624,344}, {8,368,1264,704}},
        },
    }
    for _, vertical in ipairs {false, true} do
        inputs.vertical, inputs.viewport_extent = vertical, vertical and 720 or 1280
        local orientation = vertical and 'vertical' or 'horizontal'
        for _, gap in ipairs {0, 8} do
            inputs.gap = gap
            local dump = solve(orientation .. '-gap' .. gap)
            expect(dump, 'CLIENT', expected[orientation][gap])
            expect(dump, 'CAROUSEL_STRIP', vertical and {{0,0,1280,1080}} or {{0,0,1920,720}})
            expect(dump, 'CAROUSEL_COLUMN', vertical and
                {{0,0,1280,360},{0,360,1280,720}} or {{0,0,640,720},{640,0,1280,720}})
            local surfaces = boxes(dump, 'SURFACE')
            assert(surfaces[1][3] == 800 and surfaces[1][4] == 500,
                'protocol minimum must overhang its allocated slot')
            assert(dump:find('w=grow>=800 h=grow>=500 protocol', 1, true))
            example.pixel(20,20,'#cc0000')
            example.pixel(vertical and 700 or 20, vertical and 20 or 400, '#00cc00')
            example.pixel(1000,600,'#0000cc')
        end
    end

    -- Fraction inputs determine extents independently; Clay accumulates positions.
    inputs.columns = {
        {clients = {clients[1]}, width_fraction = 1/3},
        {clients = {clients[2]}, width_fraction = 2/3},
        {clients = {clients[3]}, width_fraction = .5},
    }
    inputs.gap, inputs.peek = 5, 20
    for _, vertical in ipairs {false, true} do
        inputs.vertical, inputs.viewport_extent = vertical, vertical and 720 or 1280
        solve('fractions-before-scroll')
        awesome._clay_scroll_set(s, root.id, vertical and 0 or -100, vertical and -100 or 0)
        local dump = solve(vertical and 'vertical-fractions' or 'horizontal-fractions')
        expect(dump, 'CAROUSEL_COLUMN', vertical and
            {{0,-80,1280,226},{0,146,1280,453},{0,599,1280,340}} or
            {{-80,0,413,720},{333,0,826,720},{1159,0,620,720}})
        expect(dump, 'CAROUSEL_STRIP', vertical and {{0,-100,1280,1059}} or {{-100,0,1899,720}})
    end

    -- A smaller viewport exposes its native scissor independently of output
    -- bounds.
    inset = 40
    inputs.columns, inputs.gap, inputs.peek = grouped, 8, 0
    for _, vertical in ipairs {false, true} do
        inputs.vertical, inputs.viewport_extent = vertical, vertical and 640 or 1200
        solve('clipped-before-scroll')
        awesome._clay_scroll_set(s, root.id, vertical and 0 or -100, vertical and -100 or 0)
        local dump = solve(vertical and 'vertical-clipped' or 'horizontal-clipped')
        expect(dump, 'CAROUSEL_VIEWPORT', {{40,40,1200,640}})
        expect(dump, 'CAROUSEL_STRIP', vertical and {{40,-60,1200,960}} or {{-60,40,1800,640}})
        assert(dump:find('SCISSOR_START z=-    box 40,40 1200x640', 1, true), dump)
        assert(dump:find('SCISSOR_END', 1, true), dump)
        example.pixel(50,50,'#cc0000')
        events = {}
        local finished = false
        awful.spawn.easy_async({pointer, 'click', '50', '50', '1280', '720', 'left'},
            function(_, _, _, code)
                assert(code == 0, 'pointer client failed')
                finished = true
            end)
        assert(async.wait_for_condition(function() return finished end, 2, .02))
        assert(#events == 1 and events[1] == clients[1], 'visible surface lost input')
    end

    -- Rebuilding preserves client geometry and the supplied membership.
    local before = clients[1]:geometry()
    local tree = carousel._build_declarations(inputs)
    local after = clients[1]:geometry()
    for key, value in pairs(before) do assert(after[key] == value) end
    assert(inputs.columns == grouped and grouped[1].clients[1] == clients[1])
    assert(tree.children[1].children[2].children[1].client == clients[1])
    awesome._clay_scroll_set(s, root.id, 0, 200)
    local clamped = solve('vertical-scroll-past-start-clamps-to-zero')
    expect(clamped, 'CAROUSEL_STRIP', {{40,40,1200,960}})
    inputs.columns = {{clients = {clients[3], clients[1], clients[2]}, width_fraction = 1}}
    awesome._clay_scroll_set(s, root.id, 0, 0)
    local regrouped = solve('regrouped')
    expect(regrouped, 'CAROUSEL_COLUMN', {{40,40,1200,640}})
    local order = {}
    for name in regrouped:gmatch('\n%s+CLIENT (STRIP_%d+) ') do order[#order + 1] = name end
    assert(table.concat(order, ',') == 'STRIP_3,STRIP_1,STRIP_2')

    s.selected_tag.layout = awful.layout.suit.tile
    for _, c in ipairs(clients) do c:kill() end
    for _, report in ipairs(reports) do os.remove(report) end
    io.stderr:write('[PASS] native carousel declarations: orientations, groups, fractions, gaps, protocol minima, clips, explicit offsets and configure equality\n')
    runner.done()
end)
