-- A layout leaf that is both placed and sized is left out with one warning.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local test_client = require('_client')
local s = screen[1]

if not test_client.is_available() then
    io.stderr:write('Test finished successfully.\n')
    awesome.quit()
    return
end

local function wait_client(class)
    for _ = 1, 250 do
        local c = utils.find_client_by_class(class)
        if c then return c end
        async.sleep(.02)
    end
    error('client did not map: ' .. class)
end

local function solve()
    awful.layout.arrange(s)
    async.sleep(.15)
    return awesome._clay_tree(s)
end

runner.run_async(function()
    test_client('slot_mixed')
    test_client('slot_sized')
    local mixed, sized = wait_client('slot_mixed'), wait_client('slot_sized')
    s.selected_tag.layout = {name = 'slot-refusal-fixture', arrange = function() end,
        _clay = function()
            return {name = 'WORKAREA', dir = 'x', w = 'grow', h = 'grow', children = {
                {client = mixed, float = true, x = 10, y = 10, w = 'grow', h = 'grow'},
                {client = sized, w = 'grow', h = 'grow'},
            }}
        end}

    local dump = solve()
    assert(not dump:find('slot_mixed', 1, true), dump)
    assert(dump:match('\n%s*CLIENT slot_sized w=grow h=grow '), dump)
    assert(dump:find('derived 0 legacy 0', 1, true), dump)

    solve()
    io.stderr:flush()
    local f = assert(io.open(assert(os.getenv('SOMEWM_TEST_LOG'))))
    local _, warnings = f:read('*a'):gsub('awful%.layout: client slot_mixed is placed', '')
    f:close()
    assert(warnings == 1, 'expected one slot warning, got ' .. warnings)

    s.selected_tag.layout = awful.layout.suit.tile
    dump = solve()
    assert(dump:match('\n%s*CLIENT slot_mixed '), dump)
    runner.done()
end)
