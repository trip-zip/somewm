-- An awful.popup of rounded backgrounds and a rounded border, with no text
-- or image, rasters nothing: after each of ten resizes the dump's header
-- reads buffers 0 and raster_bytes equal to the pointer image's raster, the
-- one line on the output that carries one, so the popup carries none.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local gshape = require('gears.shape')
local gtimer = require('gears.timer')
local capture = require('_widget_capture')

runner.run_async(function()
    -- Leave the runner's own delayed call before frame() runs the queue.
    async.sleep(0.01)
    local s = screen[1]
    local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
    local lines = {}
    local inner = wibox.widget {
        capture.leaf_widget(60, 30, '#00ff00'),
        bg = '#ff0000', shape = gshape.rounded_rect, border_width = 2,
        border_color = '#0000ff', widget = wibox.container.background,
    }
    local box = wibox.widget {
        inner, margins = 8, widget = wibox.container.margin,
        forced_width = 100, forced_height = 60,
    }
    local popup = awful.popup {
        screen = s, x = s.geometry.x + 50, y = s.geometry.y + 50,
        bg = '#204080', shape = gshape.rounded_rect, visible = true,
        widget = wibox.widget {
            box, bg = '#ffff00', shape = gshape.rounded_rect,
            widget = wibox.container.background,
        },
    }
    local function frame()
        gtimer.run_delayed_calls_now()
        awesome._test_redeclare()
        return awesome._clay_tree(s)
    end
    local function check(dump, what, width, height)
        local header = dump:match('\n( +commands [^\n]*)')
        assert(header, what .. ': no header:\n' .. dump)
        local bytes, buffers = header:match('raster_bytes (%d+) buffers (%d+)')
        -- The pointer image is an IMAGE raster on the output; nothing else is.
        local cursor = 0
        for line in dump:gmatch('[^\n]+') do
            local raster = line:match(' raster=(%d+)')
            if raster then
                assert(line:find(' IMAGE ') and line:find(' cursor '),
                    what .. ': a realized line carries a raster:\n' .. dump)
                cursor = cursor + tonumber(raster)
            end
        end
        assert(tonumber(bytes) == cursor and buffers == '0',
            string.format('%s: %s\n%s', what, header, dump))
        -- The popup's rounded background and the inner border, realized at
        -- the size the resize asked for.
        assert(dump:find(' RECTANGLE%s+z=%-?%d+%s+box %-?%d+,%-?%d+ ' .. width .. 'x' .. height),
            what .. ': no rounded rectangle at that size:\n' .. dump)
        assert(dump:find(' BORDER%s+z=%-%s+box %-?%d+,%-?%d+ ' .. (width - 16) .. 'x' .. (height - 16)),
            what .. ': no rounded border inside it:\n' .. dump)
        lines[#lines + 1] = what .. ':' .. header
        io.stderr:write('[PASS] ' .. what .. ':' .. header .. '\n')
    end
    -- The first frame on a fresh output rasters the pointer image; the
    -- frames under test start after it.
    frame()
    check(frame(), 'initial', 100, 60)
    for i = 1, 10 do
        box.forced_width = 100 + i * 20
        box.forced_height = 60 + i * 10
        check(frame(), 'resize ' .. i, 100 + i * 20, 60 + i * 10)
    end
    if evidence then
        local out = assert(io.open(evidence .. '/rounded-popup-resize.txt', 'w'))
        out:write(table.concat(lines, '\n'), '\n')
        out:close()
    end
    popup.visible = false
    runner.done()
end)
