-- Check clipped surface pixels, configure sizes, input, and popup overhang.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local capture = require('_widget_capture')
local surface = require('gears.surface')
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
    local report = os.tmpname()
    local events = {}
    local inputs = {columns = {}, gap = 8,
        trail = 600, vertical = false}
    local inset = 40
    local tree
    local fixture = {name = 'private-strip-fixture', arrange = function() end,
        _clay = function()
            tree = carousel._build_declarations(inputs)
            tree.role = 'CAROUSEL_VIEWPORT'
            return {role = 'WORKAREA', direction = 'row', padding = inset, children = {tree}}
        end}
    s.selected_tag.layout = fixture

    local function solve(name)
        awful.layout.arrange(s)
        async.sleep(.15)
        local dump = awesome._clay_tree(s)
        example.save(name, dump)
        assert(tonumber(dump:match('\n  roots flow %d+ floating %d+ derived (%d+)\n'))
            == 0, dump)
        assert(not dump:find('[tree!=scene]', 1, true), dump)
        return dump
    end

    local function configure(width, height)
        local f = assert(io.open(report))
        local w, h = f:read('*a'):match('(%d+)%s+(%d+)')
        f:close()
        assert(tonumber(w) == width and tonumber(h) == height,
            'configure: ' .. tostring(w) .. ' ' .. tostring(h))
    end

    local function attach(class)
        local c
        assert(async.wait_for_condition(function()
            c = utils.find_client_by_class(class)
            return c ~= nil
        end, 2, .02), 'client did not map: ' .. class)
        c.floating, c.shadow, c.border_width, c.size_hints_honor = false, false, 1, true
        inputs.columns = {{clients = {c}, width_fraction = 1}}
        return c
    end

    local function pixels()
        example.pixel(100,300,'#cc0000')
        local r, g, b = capture.read(surface(root.content()), 20, 300)
        local got = string.format('#%02x%02x%02x', r, g, b)
        assert(got ~= '#cc0000', 'pixel (20,300): cropped surface is still visible: ' .. got)
    end

    local function realized(dump, box)
        local line = dump:match('[^\n]*CUSTOM [^\n]*rbox [^\n]*client CLIP_1[^\n]*')
        assert(line and line:find(box, 1, true), dump)
        assert(line:find('[solved!=realized]', 1, true), line)
        assert(not dump:find('no-node', 1, true), dump)
    end

    local function click(x, y)
        local finished = false
        awful.spawn.easy_async({pointer, 'click', tostring(x), tostring(y), '1280', '720', 'left'},
            function(_, _, _, code)
                assert(code == 0, 'pointer client failed')
                finished = true
            end)
        assert(async.wait_for_condition(function() return finished end, 2, .02))
    end

    awful.spawn {binary, 'CLIP_1', report, '0', 'ffcc0000', '0'}
    local c = attach('CLIP_1')
    c:connect_signal('button::press', function(original)
        events[#events + 1] = original
    end)
    solve('surface-clip-scale1-before-scroll')
    awesome._clay_scroll_set(s, tree.id, -600, 0)
    local a = solve('surface-clip-scale1')
    local surface_boxes = boxes(a, 'SURFACE')
    if #surface_boxes ~= 1 or table.concat(surface_boxes[1], ',') ~= '-551,49,1182,622' then
        local lines = {}
        for line in a:gmatch('[^\n]+') do
            if line:match('CAROUSEL_STRIP ') or line:match('CAROUSEL_COLUMN ')
                or line:match('CLIENT ') or line:match('SURFACE ') then
                lines[#lines + 1] = line
            end
        end
        error('unexpected phase A surface box\n' .. table.concat(lines, '\n'))
    end
    expect(a, 'CAROUSEL_MARGIN', {{640,40,600,640}})
    expect(a, 'CAROUSEL_COLUMN', {{-560,40,1200,640}})
    expect(a, 'CLIENT', {{-552,48,1184,624}})
    expect(a, 'SURFACE', {{-551,49,1182,622}})
    configure(1182, 622)
    pixels()
    realized(a, 'box -551,49 1182x622 rbox 40,49 591x622')
    click(100, 300)
    assert(#events == 1 and events[1] == c, 'visible surface lost input')
    click(20, 300)
    assert(#events == 1, 'cropped surface received input')

    s.scale = 1.25
    async.sleep(.3)
    inputs.trail = 472
    solve('surface-clip-scale125-before-scroll')
    awesome._clay_scroll_set(s, tree.id, -472, 0)
    local b = solve('surface-clip-scale125')
    expect(b, 'CAROUSEL_COLUMN', {{-432,40,944,496}})
    expect(b, 'SURFACE', {{-423,49,926,478}})
    configure(926, 478)
    pixels()
    realized(b, 'box -423,49 926x478 rbox 40,49 463x478')
    s.scale = 1
    async.sleep(.3)

    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 2, .02))
    inputs.trail = 600
    local pid = awful.spawn {'./build-test/test-popup-client'}
    local parent = attach('popup_test')
    solve('surface-clip-popup-before-scroll')
    awesome._clay_scroll_set(s, tree.id, -600, 0)
    solve('surface-clip-popup-parent')
    assert(async.wait_for_condition(function()
        local dump = awesome._clay_tree(s)
        return dump:match('SURFACE popup_test [^\n]-box %-551,49 1182x622')
    end, 2, .02), 'popup parent did not reach its solved size')
    async.sleep(.2)
    awesome.kill(pid, 10)
    local popup_dump, line
    assert(async.wait_for_condition(function()
        popup_dump = awesome._clay_tree(s)
        line = popup_dump:match('[^\n]* popup [^\n]+')
        return line ~= nil
    end, 2, .02), 'popup did not map')
    example.save('surface-clip-popup', popup_dump)
    assert(line:find('box 631,671 120x120', 1, true), line)
    assert(not line:find('[solved!=realized]', 1, true), line)
    assert(not popup_dump:find('[tree!=scene]', 1, true), popup_dump)
    example.pixel(640,700,'#4080c0')

    s.selected_tag.layout = awful.layout.suit.tile
    parent:kill()
    os.remove(report)
    io.stderr:write('[PASS] surfaces obey rectangular clips at integer and fractional scale, retain configure sizes and visible input, and leave popups uncropped\n')
    runner.done()
end)
