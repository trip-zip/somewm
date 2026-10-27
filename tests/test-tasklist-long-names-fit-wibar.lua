-- luacheck: globals screen awesome
-- A tasklist in the middle of an align takes only the width the outer
-- widgets leave. Long client names stay on one line inside it, and the
-- widgets after it stay inside the bar.
local runner = require('_runner')
local async = require('_async')
local test_client = require('_client')
local awful = require('awful')
local wibox = require('wibox')

if not test_client.is_available() then
    return runner.skip('no terminal available for test clients')
end

local s = screen[1]
local names = {
    'Window one: a really long title that just keeps going and going',
    'Window two: another long title with lots and lots of words in it',
    'Window three: yet another very long window title to fill up the bar',
}
-- Doubled, the three names are wider together than a 1280 px bar.
for i, name in ipairs(names) do names[i] = name .. ', ' .. name end

-- The textbox is a cut node around its text: x and width are the node's,
-- the extent the text is drawn in; height is the text's own.
local function box(dump, text)
    local cut
    for line in dump:gmatch('[^\n]+') do
        if line:find(' cut=', 1, true) then cut = line end
        if line:find('text "' .. text, 1, true) and cut then
            local x, y, w = cut:match(' box (%-?%d+),(%-?%d+) (%d+)x%d+')
            local h = line:match(' box %-?%d+,%-?%d+ %d+x(%d+)')
            if x and h then return tonumber(x), tonumber(y), tonumber(w), tonumber(h) end
        end
    end
end

runner.run_async(function()
    for i, name in ipairs(names) do
        local class = 'longname_' .. i
        test_client(class)
        local c = async.wait_for_client(class, 5)
        assert(c, class .. ' did not appear')
        -- The terminal retitles itself after it maps; keep the test's name.
        local function hold() if c.valid and c.name ~= name then c.name = name end end
        c:connect_signal('property::name', hold)
        hold()
    end

    local bar = awful.wibar { position = 'top', screen = s }
    bar:setup {
        layout = wibox.layout.align.horizontal,
        wibox.widget.textbox(' LEFT '),
        awful.widget.tasklist { screen = s, filter = awful.widget.tasklist.filter.currenttags },
        { layout = wibox.layout.fixed.horizontal,
            wibox.widget.textbox(' RIGHT '), wibox.widget.textclock('CLOCK') },
    }

    local function cleanup()
        bar:remove()
        test_client.terminate()
        assert(async.wait_for_no_clients(5), 'test clients did not close')
    end

    local dump
    local solved = async.wait_for_condition(function()
        dump = awesome._clay_tree(s)
        if not box(dump, 'CLOCK') then return false end
        for _, name in ipairs(names) do
            if not box(dump, name) then return false end
        end
        return true
    end, 5, .05)
    if not solved then
        for line in dump:gmatch('[^\n]*text "[^\n]*') do io.stderr:write('[TEST] ', line, '\n') end
        cleanup()
        error('the bar never solved with all three names')
    end

    local left = bar.x - s.geometry.x
    local right = left + bar.width
    local rx, _, rw = box(dump, ' RIGHT ')
    local cx, _, cw = box(dump, 'CLOCK')
    -- A label that fits on one line gives the height of one line.
    local _, _, _, line_height = box(dump, ' LEFT ')
    io.stderr:write(string.format('[TEST] bar %d..%d height %d, RIGHT %d+%d, CLOCK %d+%d\n',
        left, right, bar.height, rx, rw, cx, cw))
    for _, name in ipairs(names) do
        local x, _, w, h = box(dump, name)
        io.stderr:write(string.format('[TEST] %q %d+%d height %d\n', name:sub(1, 12), x, w, h))
    end

    local failures = {}
    if cx + cw > right then
        failures[#failures + 1] = string.format('CLOCK ends at %d, past the bar edge %d', cx + cw, right)
    end
    for _, name in ipairs(names) do
        local x, _, w, h = box(dump, name)
        if x + w > rx then
            failures[#failures + 1] = string.format('%q ends at %d, over RIGHT at %d', name, x + w, rx)
        end
        if h > line_height then
            failures[#failures + 1] = string.format('%q is %d tall, one line is %d', name, h, line_height)
        end
    end

    cleanup()
    assert(#failures == 0, table.concat(failures, '\n') .. '\n' .. dump)
    runner.done()
end)
