-- Native declaration targets for the remaining stock-client layout families.
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local checks = example.batch()
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]
local clients, reports, steps, previous = {}, {}, {}, nil
local colors = {'ffff0000','ff00ff00','ff0000ff','ffffff00'}

-- minimum: client A's protocol minimum as {width, height}.
local function count_clients(count, minimum)
    steps[#steps + 1] = function()
        for i = count + 1, #clients do clients[i]:kill() end
        for i = #clients + 1, count do
            reports[i] = os.tmpname()
            local min = i == 1 and minimum or {'0', '0'}
            awful.spawn{binary, string.char(64+i), reports[i], min[1], colors[i], min[2]}
        end
        return true
    end
    steps[#steps + 1] = function(n)
        if #client.get() ~= count then assert(n<30, 'client count did not change'); return end
        clients = {}
        for i = 1, count do
            local c = assert(utils.find_client_by_class(string.char(64+i)))
            c.floating, c.shadow, c.border_width = false, false, 1
            c.size_hints_honor = i == 1 and minimum ~= nil
            clients[i] = c
        end
        for i, wanted in ipairs(clients) do
            local current = awful.client.tiled(s)[i]
            if current ~= wanted then current:swap(wanted) end
        end
        for i = count, 1, -1 do clients[i]:raise() end
        return true
    end
end
local function layout(name, policy, fraction)
    steps[#steps + 1] = function()
        s.selected_tag.layout = policy
        s.selected_tag.master_width_factor = fraction or 0.5
        client.focus = clients[1]
        previous = nil
        return true
    end
    steps[#steps + 1] = function(n)
        local dump = awesome._clay_tree(s)
        if n < 3 or dump ~= previous then
            previous = dump
            assert(n<30, name .. ' did not settle')
            return
        end
        checks.check(name, dump)
        local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        if dir then
            local f = assert(io.open(dir .. '/' .. name .. '.configures', 'w'))
            for i, c in ipairs(clients) do
                local report = assert(io.open(reports[i]))
                f:write(c.class, ': ', report:read('*a'))
                report:close()
            end
            f:close()
        end
        return true
    end
end
steps[#steps + 1] = function()
    s.selected_tag.layout = awful.layout.suit.tile
    s.selected_tag.gap = 0
    s.selected_tag.master_count, s.selected_tag.column_count = 1, 1
    return true
end
count_clients(4)
layout('tidy-fair-four', awful.layout.suit.fair)
count_clients(3)
layout('tidy-spiral-three', awful.layout.suit.spiral)
layout('tidy-corner-nw-three', awful.layout.suit.corner.nw)
count_clients(2)
layout('tidy-max-two', awful.layout.suit.max)
count_clients(2)
steps[#steps + 1] = function()
    clients[2].ontop = true
    return true
end
layout('tidy-tile-ontop-two', awful.layout.suit.tile)
steps[#steps + 1] = function()
    -- The ontop frame fills its cell.
    local dump = awesome._clay_tree(s)
    local cell = assert(dump:match('\n%s*CELL B [^\n]- box ([^\n]+)'), dump)
    local frame = assert(dump:match('\n%s*CLIENT B [^\n]- box ([^\n]+)'), dump)
    assert(cell == frame, cell .. ' ~= ' .. frame)
    clients[2].ontop = false
    return true
end
count_clients(3)
layout('tidy-magnifier-three', awful.layout.suit.magnifier, 0.25)
steps[#steps + 1] = function()
    for _, c in ipairs(clients) do c:kill() end
    for _, report in ipairs(reports) do os.remove(report) end
    clients = {}
    return true
end
steps[#steps + 1] = function(n)
    if #client.get() > 0 then assert(n<30, 'clients did not close'); return end
    return true
end
count_clients(4, {'1600', '500'})
layout('tidy-fair-four-min1600', awful.layout.suit.fair)
steps[#steps + 1] = function()
    for _, c in ipairs(clients) do c:kill() end
    for _, report in ipairs(reports) do os.remove(report) end
    return true
end
steps[#steps + 1] = checks.finish
require('_runner').run_steps(steps)
