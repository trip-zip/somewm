local runner = require('_runner')
local async = require('_async')
local awful = require('awful')

local function command(args, expected)
    local argv = {'./build-test/somewm-client', 'tag'}
    for _, arg in ipairs(args) do argv[#argv + 1] = arg end
    local done, output, errors, code
    awful.spawn.easy_async(argv, function(stdout, stderr, _, exit)
        output, errors, code, done = stdout, stderr, exit, true
    end)
    for _ = 1, 500 do
        if done then break end
        async.sleep(0.002)
    end
    assert(done, 'IPC command did not finish')
    local reply = output .. errors
    assert(code == 0, reply)
    assert(not reply:lower():find('error', 1, true), reply)
    assert(output:find(expected, 1, true), reply)
end

runner.run_async(function()
    local s = awful.screen.focused()
    local t = assert(s.selected_tag)
    local factor, gap, layout = t.master_width_factor, t.gap, t.layout
    command({'mwfact', t.name, '0.6'}, "Set tag '" .. t.name .. "' master_width_factor to 0.60")
    assert(math.abs(t.master_width_factor - 0.6) < 0.000001)
    command({'gap', t.name, '7'}, "Set tag '" .. t.name .. "' gap to 7")
    assert(t.gap == 7)
    t.layouts = nil
    command({'layout', t.name, 'floating'}, "Set tag '" .. t.name .. "' layout to floating")
    assert(t.layout == awful.layout.suit.floating)
    command({'add', 'ipc-added'}, "Created tag 'ipc-added'")
    local added = assert(awful.tag.find_by_name(s, 'ipc-added'))
    assert(added.layout == (awful.layout.layouts[1] or awful.layout.suit.tile))
    added:delete()
    t.master_width_factor, t.gap, t.layout = factor, gap, layout
    runner.done()
end)
