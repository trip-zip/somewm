-- A tiled client that commits whole cells, as a terminal does, draws less
-- than its cell. Its cell must still be its share of the column: were the
-- cell its drawn size, the next configure would follow the drawing, and a
-- full column bounced two clients between two sizes on every frame.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')

local cell = 100
local reports, solved, baseline = {}, 0, nil

-- Each CLIENT line of the tile stack, by class, with its box.
local function stack(dump)
    local found = {}
    for l in dump:gmatch('[^\n]+') do
        local class, h = l:match('^%s*CLIENT (%S+) w=grow h=grow .* box %-?%d+,%-?%d+ %d+x(%d+)$')
        if class then found[class] = tonumber(h) end
    end
    return found
end

local function spawn(class, cells)
    reports[class] = os.tmpname()
    awful.spawn{'./build-test/test-transient-client', class, reports[class], '0', 'ff204060',
        '0', '0', '0', tostring(cells)}
end

-- One client at a time: a new client takes the master, so the last one
-- spawned is the master and the others stack.
local function mapped(class, cells)
    local spawned = false
    return function(n)
        if not spawned then spawn(class, cells); spawned = true end
        if utils.find_client_by_class(class) then return true end
        assert(n < 50, class .. ' did not map')
    end
end

runner.run_steps({
    function()
        screen[1].selected_tag.layout = awful.layout.suit.tile
        return true
    end,
    mapped('stack_cells', cell),
    mapped('stack_plain', 0),
    mapped('master_plain', 0),
    -- Once the layout settles: two dumps in a row agree.
    function(n)
        local dump = awesome._clay_tree(screen[1])
        local tree = dump:match('\n(  roots .-)\n  realized:')
        local heights = stack(dump)
        local settled = tree == baseline
        baseline = tree
        if not (settled and heights.stack_cells and heights.stack_plain
                and dump:find('CONFIGURE stack_cells', 1, true)
                and dump:find('CLIENT master_plain w=percent', 1, true)) then
            assert(n < 50, 'the stack never settled with the cell client beside its probe: ' .. dump)
            return
        end
        assert(math.abs(heights.stack_cells - heights.stack_plain) <= 1, string.format(
            'the cell client takes %d of the stack and the plain one %d, not equal shares:\n%s',
            heights.stack_cells, heights.stack_plain, tree))
        io.stderr:write(string.format('[PASS] equal stack cells %d and %d\n',
            heights.stack_cells, heights.stack_plain))
        screen[1]:connect_signal('clay::solved', function() solved = solved + 1 end)
        return true
    end,
    -- Ten further frames, each declaring the screen again, change nothing.
    function(n)
        if solved < 10 then
            awful.layout.arrange(screen[1])
            assert(n < 100, 'ten frames did not solve')
            return
        end
        local tree = awesome._clay_tree(screen[1]):match('\n(  roots .-)\n  realized:')
        assert(tree == baseline, 'the tree changed while nothing did:\n' .. tree)
        io.stderr:write('[PASS] after ' .. solved .. ' frames the tree is unchanged\n')
        for _, path in pairs(reports) do os.remove(path) end
        return true
    end,
})
