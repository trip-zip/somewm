---------------------------------------------------------------------------
-- Test: a tag switch creates and destroys no scene node
--
-- A taglist item's background declares a rectangle only while it has a
-- colour. Its scene node stays, disabled, while the element is in the tree,
-- so after one cycle through the tags every switch reads created 0 swept 0
-- in the dump header, and the red background still follows the selection.
---------------------------------------------------------------------------

local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local gears = require('gears')
local wibox = require('wibox')
local capture = require('_widget_capture')
local gsurface = require('gears.surface')
local example = require('_clay_example')

local RED = '#ff0000'

local function red(r, g, b)
    return math.abs(r - 255) <= 12 and g <= 12 and b <= 12
end

runner.run_async(function()
    local s = screen[1]
    local old = s.tags
    local tags = awful.tag({'1', '2', '3', '4', '5'}, s, awful.layout.layouts[1])
    tags[1]:view_only()
    for _, t in ipairs(old) do t:delete() end
    assert(#s.tags == 5, 'expected five tags, got ' .. #s.tags)

    beautiful.taglist_bg_focus = RED
    local wb = wibox {
        x = 0, y = 0, width = 1280, height = 32, screen = s,
        bg = '#202020', visible = true,
        widget = awful.widget.taglist {
            screen = s,
            filter = awful.widget.taglist.filter.all,
        },
    }
    async.sleep(0.15)
    local settled = false
    for i = 1, 5 do
        if awesome._test_redeclare() == 0 then
            settled = true
            break
        end
        if i < 5 then async.sleep(0.05) end
    end
    assert(settled, 'the wibox did not settle')

    -- The red run along the bar's top row, above any glyph.
    local function red_run()
        local surf = gsurface(root.content())
        local x0, x1
        for x = wb.x, wb.x + wb.width - 1 do
            if red(capture.read(surf, x, wb.y + 1)) then
                if x1 and x > x1 + 1 then error('two red runs on the bar') end
                x0 = x0 or x
                x1 = x
            end
        end
        assert(x0, 'no red background on the bar')
        return x0, x1
    end

    local runs = {}
    local index = 1
    runs[index] = {red_run()}
    local dump
    for switch = 1, 10 do
        awful.tag.viewnext(s)
        gears.timer.run_delayed_calls_now()
        awesome._test_redeclare()
        dump = awesome._clay_tree(s)
        local line = dump:match('commands %d+ mutations %d+[^\n]*')
        local created = tonumber(line:match('created (%d+)'))
        local swept = tonumber(line:match('swept (%d+)'))
        local mutations = tonumber(line:match('mutations (%d+)'))
        assert(created and swept, 'the header has no created/swept: ' .. line)
        io.stderr:write(string.format('switch %d: created %d swept %d mutations %d\n',
            switch, created, swept, mutations))
        assert(awesome._test_redeclare() == 0,
            'switch ' .. switch .. ': the next frame mutated the scene')

        local previous = runs[index]
        index = index % 5 + 1
        assert(s.selected_tag == tags[index], 'switch ' .. switch .. ': wrong tag selected')
        local x0, x1 = red_run()
        if runs[index] then
            assert(runs[index][1] == x0 and runs[index][2] == x1, string.format(
                'switch %d: tag %d red at %d-%d, was %d-%d', switch, index,
                x0, x1, runs[index][1], runs[index][2]))
        elseif index > 1 then
            assert(x0 > previous[2], string.format(
                'switch %d: tag %d red at %d-%d, not right of tag %d at %d-%d',
                switch, index, x0, x1, index - 1, previous[1], previous[2]))
        end
        runs[index] = {x0, x1}
        local mid = math.floor((previous[1] + previous[2]) / 2)
        assert(not red(capture.read(gsurface(root.content()), mid, wb.y + 1)),
            'switch ' .. switch .. ': the previous item is still red')

        if switch > 5 then
            assert(created == 0 and swept == 0, string.format(
                'switch %d: created %d swept %d, expected 0 and 0', switch, created, swept))
        end
    end
    example.save('taglist-retained-rect', dump)

    wb.visible = false
    runner.done()
end)
