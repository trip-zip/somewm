local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')

local text = 'Wide willow branches shimmer beneath bright summer moonlight'

local function text_width(s)
    for line in awesome._clay_tree(s):gmatch('[^\n]+') do
        if line:find('text "' .. text .. '"', 1, true) then
            io.stderr:write(line, '\n')
            return assert(tonumber(line:match('box [%d.-]+,[%d.-]+ ([%d.]+)x')),
                'text width missing from Clay dump')
        end
    end
    error('text line missing from Clay dump')
end

runner.run_async(function()
    local s = screen[1]
    s.scale = 1
    async.sleep(0.15)
    local bar = awful.wibar {screen = s, position = 'top', height = 32,
        widget = wibox.widget.textbox(text)}
    async.sleep(0.15)
    awesome._test_redeclare()
    assert(text_width(s) == 326, 'unexpected scale-1 text width')

    s.scale = 2
    async.sleep(0.15)
    awesome._test_redeclare()
    assert(text_width(s) == 330,
        'text width kept its scale-1 measurement after the scale change')

    s.scale = 1
    bar:remove()
    runner.done()
end)
