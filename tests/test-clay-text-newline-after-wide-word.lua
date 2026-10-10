-- A word wider than its box, then a space, then a newline: Clay wraps that
-- into a line of length -1 (clay.h:2614-2615). It draws as an empty line and
-- the two real lines still draw.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local naughty = require('naughty')
local example = require('_clay_example')

local text = string.rep('x', 60) .. ' \nb'

-- The realized TEXT runs of one drawin, in draw order.
local function runs(dump, d)
    local tag = string.format('drawin screen %d %dx%d+%d+%d', screen[1].index,
        d.width, d.height, d.x, d.y)
    local out = {}
    for line in dump:gmatch('[^\n]+') do
        local w, rw = line:match('^  %x+ TEXT +z=%- +box %-?%d+,%-?%d+ (%-?%d+)x%d+ '
            .. 'rbox %-?%d+,%-?%d+ (%d+)x%d+ ')
        if w and line:find(tag, 1, true) then
            out[#out + 1] = {width = tonumber(w), shown = tonumber(rw),
                raster = line:find(' raster=', 1, true) ~= nil}
        end
    end
    return out
end

-- Two drawn runs around one empty line: no raster, nothing shown.
local function check(dump, d, drawn)
    assert(dump:find('text "' .. text .. '"', 1, true), 'text missing from the dump')
    local all, rastered, empty = runs(dump, d), 0, 0
    for _, run in ipairs(all) do
        if run.raster then
            rastered = rastered + 1
        elseif run.width < 0 and run.shown == 0 then
            empty = empty + 1
        end
    end
    assert(rastered == drawn and empty == 1 and #all == drawn + 1,
        string.format('want %d drawn runs and 1 empty, have %d drawn, %d empty of %d',
            drawn, rastered, empty, #all))
end

runner.run_async(function()
    require('beautiful').font = 'monospace 10'
    local s = screen[1]
    -- The constraint puts the word wider than its own box; the drawin's clip
    -- alone would let the text keep the word's width.
    local box = wibox {screen = s, x = 100, y = 100, width = 160, height = 60,
        visible = true, bg = '#000000', fg = '#ffffff',
        widget = wibox.container.constraint(wibox.widget {
            widget = wibox.widget.textbox, wrap = 'word', text = text}, 'max', 160)}
    async.sleep(0.2)
    local dump = awesome._clay_tree(s)
    example.save('text-newline-after-wide-word', dump)
    check(dump, box, 2)

    naughty.connect_signal('request::display', function(n)
        require('naughty.layout.box') {notification = n}
    end)
    local n = naughty.notification {title = 'title', message = text, timeout = 0}
    async.sleep(0.3)
    local nd
    for _, d in ipairs(drawin.get()) do
        local w = d.get_wibox and d.get_wibox().widget
        if w and w.get_notification and w:get_notification() == n then nd = d end
    end
    dump = awesome._clay_tree(s)
    example.save('text-newline-after-wide-word-notification', dump)
    -- The title, the long word and "b".
    check(dump, assert(nd, 'notification box missing'), 3)

    n:destroy()
    box.visible = false
    runner.done()
end)
