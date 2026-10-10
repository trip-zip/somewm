-- An image in a column slot of a bar takes the bar's height as a cap.
local runner = require('_runner')
local wibox = require('wibox')
local example = require('_clay_example')
local cairo = require('lgi').cairo

local function box(line)
    local x, y, w, h = line:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
end

runner.run_async(function()
    local text = wibox.widget.textbox('image-in-column')
    text.font = 'monospace 6'
    local bar = wibox {
        x = 0, y = 300, width = 1280, height = 28, screen = screen[1], visible = true,
        widget = wibox.container.margin(wibox.layout.fixed.horizontal(
            wibox.widget {
                layout = wibox.layout.align.vertical, expand = 'none', nil,
                wibox.widget.imagebox(cairo.ImageSurface(cairo.Format.ARGB32, 48, 48), true),
            },
            text), 7, 7, 7, 7),
    }
    _image_in_column_bar = bar

    awesome._test_redeclare()
    local dump = awesome._clay_tree(screen[1])
    example.save('image-in-column', dump)
    assert(dump:match('roots flow %d+ floating %d+ derived 0 legacy 0'), dump)
    assert(not dump:find('[tree!=scene]', 1, true), dump)

    -- The margin folds into the drawin's root element as its padding.
    local lines, inside = {}, false
    for line in dump:gmatch('[^\n]+') do
        if line:find('^  drawin screen 1 1280x28%+0%+300 ') then
            inside = true
            assert(line:find(' pad 7,7,7,7 ', 1, true) and select(4, box(line)) == 28, line)
        elseif inside and line:find('^  %S') then break
        elseif inside then lines[#lines + 1] = line end
    end
    local function find(pattern)
        for i, line in ipairs(lines) do
            if line:find(pattern) then return line, lines[i - 1] end
        end
        error('no line ' .. pattern .. ' in\n' .. table.concat(lines, '\n'))
    end

    local image, imagebox = find(' image image 48x48 ')
    local _, y, w, h = box(image)
    assert(w == 14 and h == 14 and y == 307, image)
    assert(select(4, box(imagebox)) == 14, imagebox)
    assert(select(4, box(find(' wibox%.layout%.fixed '))) == 14, dump)

    local command = assert(dump:match('\n[^\n]* TEXT [^\n]* drawin screen 1 1280x28%+0%+300[^\n]*'), dump)
    local solved, realized = command:match(' box (%S+ %S+) rbox (%S+ %S+) ')
    assert(solved and solved == realized, command)

    assert(awesome._test_redeclare() == 0)
    bar.visible = false
    io.stderr:write('[PASS] an image in a column slot takes the bar height as a cap\n')
    runner.done()
end)
