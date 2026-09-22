-- Closed clients may still occur in a layout's last published declaration.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local utils = require('_utils')
local example = require('_clay_example')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]
local carousel = awful.layout.suit.carousel

local function check(dump, clients, expected, killed)
    assert(not dump:find(killed, 1, true), 'closed client remains in the dump: ' .. killed)
    local count = 0
    for line in dump:gmatch('[^\n]+') do
        if line:match('^%s*CLIENT ') then
            count = count + 1
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            assert(table.concat({x, y, w, h}, ',') == table.concat(expected[count] or {}, ','), line)
            assert(line:find(clients[count].class, 1, true), line)
        end
    end
    assert(count == 2, 'expected two declared clients, got ' .. count)
    for i, c in ipairs(clients) do
        local g = c:geometry()
        local box = expected[i]
        local inner = {box[1], box[2], box[3] - 2, box[4] - 2}
        assert(table.concat({g.x, g.y, g.width, g.height}, ',') == table.concat(inner, ','),
            'remaining client geometry differs: ' .. c.class .. ' ' .. table.concat({g.x,g.y,g.width,g.height}, ',') .. ' border=' .. c.border_width)
    end
end

runner.run_async(function()
    assert(s.geometry.width == 1280 and s.geometry.height == 720, 'expected 1280x720 output')
    beautiful.carousel_default_column_width = .5
    beautiful.carousel_peek_width = 0
    beautiful.carousel_dynamic_peek_width = -1
    beautiful.carousel_center_mode = 'never'
    s.selected_tag.gap = 0
    s.selected_tag.master_count, s.selected_tag.column_count = 1, 1
    s.selected_tag.master_width_factor = .5
    for _, case in ipairs({
        {name = 'tile', layout = awful.layout.suit.tile, boxes = {{0,0,640,720}, {640,0,640,720}}},
        {name = 'carousel', layout = carousel, boxes = {{0,0,640,720}, {640,0,640,720}}},
    }) do
        s.selected_tag.layout = awful.layout.suit.tile
        local clients, reports = {}, {}
        for i = 1, 3 do
            local class = 'CLOSED_' .. case.name .. '_' .. i
            reports[i] = os.tmpname()
            awful.spawn {binary, class, reports[i], '0', 'ff336699', '0'}
            assert(async.wait_for_condition(function()
                clients[i] = utils.find_client_by_class(class)
                return clients[i] ~= nil
            end, 2, .01), 'client did not map: ' .. class)
            local c = clients[i]
            c.floating, c.shadow, c.border_width, c.size_hints_honor = false, false, 1, false
            c.carousel_column_width = .5
        end
        for i, wanted in ipairs(clients) do
            local current = awful.client.tiled(s)[i]
            if current ~= wanted then current:swap(wanted) end
        end
        s.selected_tag.layout = case.layout
        client.focus = clients[1]
        awful.layout.arrange(s)
        async.sleep(.3)
        awesome._test_redeclare()
        awesome._test_redeclare()
        local describe = case.layout._clay
        local held = describe(s)
        -- Hold the stock slots until the close is observed, without allowing
        -- a new membership query to discard the handle before C reads it.
        case.layout._clay = function() return held end
        local killed = clients[3].class
        clients[3]:kill()
        local dump
        assert(async.wait_for_condition(function()
            if clients[3].valid then return false end
            -- Declare in the poll itself, before the async helper queues the
            -- coroutine's resume alongside other delayed calls.
            awesome._test_redeclare()
            dump = awesome._clay_tree(s)
            case.layout._clay = describe
            return true
        end, 2, .001),
            'client did not close: ' .. killed)
        example.save('tile-closed-client-' .. case.name, dump)
        check(dump, {clients[1], clients[2]}, case.boxes, killed)
        io.stderr:write('[CLOSED] ' .. case.name .. ' two live clients; no ' .. killed .. '\n')
        for i = 1, 2 do clients[i]:kill() end
        assert(async.wait_for_condition(function() return #client.get() == 0 end, 2, .01),
            'remaining clients did not close')
        for _, path in ipairs(reports) do os.remove(path) end
    end
    runner.done()
end)
