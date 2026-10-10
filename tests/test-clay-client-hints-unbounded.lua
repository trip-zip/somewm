-- A max size hint past the solver's range leaves its axis unbounded and warns
-- once per field; a layout tree the screen refuses warns once until accepted.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function warnings(text)
    local path = assert(os.getenv('SOMEWM_TEST_LOG'), 'SOMEWM_TEST_LOG is not set')
    local log = assert(io.open(path, 'r'))
    local count = 0
    for line in log:lines() do if line:find(text, 1, true) then count = count + 1 end end
    log:close()
    return count
end

local function line_of(dump, role, class)
    return dump:match('\n%s*' .. role .. ' ' .. class .. ' [^\n]+')
end

local function box(line)
    local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
end

-- Both clients at their tile cells: master left at half the workarea, stack right.
local function tiled(dump)
    local wa = s.workarea
    local a, b = line_of(dump, 'CLIENT', 'hint_unbounded'), line_of(dump, 'CLIENT', 'hint_bounded')
    if not a or not b then return false end
    local ax, ay, aw, ah = box(a)
    local bx, by, bw, bh = box(b)
    return ax == wa.x and ay == wa.y and ah == wa.height
        and (aw == math.floor(wa.width / 2) or aw == math.ceil(wa.width / 2))
        and bx == ax + aw and by == wa.y and bw == wa.width - aw and bh == wa.height
end

local function frame()
    awful.layout.arrange(s)
    async.sleep(.15)
    return awesome._clay_tree(s)
end

runner.run_async(function()
    local t = s.selected_tag
    t.layout = awful.layout.suit.tile
    t.master_width_factor = 0.5
    t.gap = 0
    local unbounded_pid = awful.spawn {binary, 'hint_unbounded', '/dev/null', '0', 'FF404040', '0',
        '2147483647', '2147483647'}
    local bounded_pid = awful.spawn {binary, 'hint_bounded', '/dev/null', '0', 'FF404040', '0',
        '900', '900'}
    assert(type(unbounded_pid) == 'number' and type(bounded_pid) == 'number', 'spawn failed')
    local a, b
    async.wait_for_condition(function()
        a = utils.find_client_by_class('hint_unbounded')
        b = utils.find_client_by_class('hint_bounded')
        return a and b and a.size_hints.max_width == 2147483647 and b.size_hints.max_width == 900
    end, 10)
    assert(a and b, 'clients did not map with their hints')
    for _, c in ipairs {a, b} do
        c.floating = false; c.border_width = 1; c.shadow = false
    end
    if awful.client.tiled(s)[1] ~= a then a:swap(b) end

    local dump
    for _ = 1, 60 do dump = frame(); if tiled(dump) then break end end
    example.save('hint-unbounded', dump)
    assert(tiled(dump), 'clients are not at their tile cells\n' .. dump)
    local leaf = assert(line_of(dump, 'SURFACE', 'hint_unbounded'), dump)
    assert(not leaf:find('<=', 1, true) and not leaf:find('protocol', 1, true), leaf)
    leaf = assert(line_of(dump, 'SURFACE', 'hint_bounded'), dump)
    assert(leaf:find('w=grow<=900 protocol h=grow<=900 protocol', 1, true), leaf)
    assert(dump:find('derived 0 legacy 0', 1, true), dump)

    assert(warnings('client hint_unbounded max_width 2147483647 is past the solver') == 1,
        'max_width must warn exactly once')
    assert(warnings('client hint_unbounded max_height 2147483647 is past the solver') == 1,
        'max_height must warn exactly once')
    assert(warnings('client hint_bounded') == 0, 'an in-range hint must not warn')

    local refused = 'awful.layout: screen 1 layout tree refused (malformed)'
    t.layout = {name = 'refused', arrange = function() end,
        _clay = function() return {name = 'WORKAREA', w = -1, h = 'grow', children = {}} end}
    dump = frame()
    dump = frame()
    local indent, after = dump:match('\n(%s*)WORKAREA [^\n]*\n(%s*)')
    example.save('hint-unbounded-refused', dump)
    assert(not indent or #after <= #indent, 'the refused tree still has children\n' .. dump)
    assert(not line_of(dump, 'CLIENT', 'hint_unbounded'), dump)
    assert(warnings(refused) == 1, 'a refused tree must warn exactly once')

    t.layout = awful.layout.suit.tile
    for _ = 1, 60 do dump = frame(); if tiled(dump) then break end end
    example.save('hint-unbounded-restored', dump)
    assert(tiled(dump), 'clients did not return to their tile cells\n' .. dump)
    assert(dump:find('derived 0 legacy 0', 1, true), dump)
    assert(warnings(refused) == 1, 'an accepted tree must not warn again')

    awesome.kill(unbounded_pid, 9)
    awesome.kill(bounded_pid, 9)
    async.wait_for_condition(function() return not a.valid and not b.valid end, 10)
    io.stderr:write('[PASS] unbounded max hint left off, refused tree warned once\n')
    runner.done()
end, {kill_clients = false})
