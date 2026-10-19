-- Explicitly positioned popups size themselves from content before fading.
-- timeout: 30
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local shape = require('gears.shape')
local capture = require('_widget_capture')

local function frame(s)
    local dump = awesome._clay_tree(s)
    assert(not dump:find('[tree!=scene]', 1, true), dump)
    return dump:match('\n(  WIBOX [^\n]+)'), dump
end

runner.run_async(function()
    local s = screen[1]
    mouse.coords {x = 20, y = 20}
    for _, animated in ipairs({true, false}) do
        for _, border in ipairs({0, 2}) do
            for _, bounded in ipairs({true, false}) do
                local text = wibox.widget.textbox('Popup sizing')
                if not bounded then text.forced_width, text.forced_height = 380, 90 end
                local popup = awful.popup {
                    screen = s, x = 100, y = 100, visible = false,
                    shadow = not bounded and border == 0,
                    shape = not bounded and border == 2 and shape.rounded_rect or nil,
                    border_width = border, border_color = '#87afff',
                    bg = '#202020',
                    minimum_width = bounded and 380 or nil, maximum_width = bounded and 500 or nil,
                    minimum_height = bounded and 90 or nil, maximum_height = bounded and 200 or nil,
                    animation = animated and {visible = {duration = 1, enter = 'fade', exit = 'fade'}} or nil,
                    widget = text,
                }
                local function check_size(width, height)
                    local line, dump = frame(s)
                    assert(popup.x == 100 and popup.y == 100, 'popup moved:\n' .. dump)
                    assert(popup.width == width and popup.height == height,
                        string.format('animated=%s border=%d bounded=%s: got %dx%d, expected %dx%d\n%s',
                            tostring(animated), border, tostring(bounded), popup.width, popup.height, width, height, dump))
                    if animated or border > 0 then
                        assert(line and line:find(string.format('box %d,%d %dx%d',
                            100 - border, 100 - border, width + 2 * border, height + 2 * border), 1, true), dump)
                    end
                end
                local function resize(width, height)
                    if bounded then popup.minimum_width, popup.minimum_height = width, height
                    else text.forced_width, text.forced_height = width, height end
                    async.sleep(.1)
                    check_size(width, height)
                end
                popup.visible = true
                async.sleep(.2)
                check_size(380, 90)
                if animated then
                    local line = assert(frame(s))
                    local alpha = tonumber(line:match('fade_alpha ([%d.]+)'))
                    assert(alpha and alpha > 0 and alpha < 1, 'entrance did not fade: ' .. line)
                end
                resize(460, 110)
                resize(220, 70)
                if animated then async.sleep(.8) end
                check_size(220, 70)
                local r, g, b = capture.read(s.content, 310, 160)
                assert(r == 32 and g == 32 and b == 32, 'popup did not paint its full content area')
                if border > 0 then
                    r, g, b = capture.read(s.content, 320, 160)
                    assert(r == 135 and g == 175 and b == 255, 'popup border did not follow its content')
                end
                if animated and border == 2 and not bounded then
                    popup.visible = false
                    async.sleep(.2)
                    local dump = awesome._clay_tree(s)
                    assert(dump:match('fade_alpha [^\n]+box 98,98 224x74'), 'exit lost its size:\n' .. dump)
                    async.sleep(.9)
                    assert(not awesome._clay_tree(s):find('fade_alpha ', 1, true), 'exit did not finish')
                end
                popup.animation = false
                popup.visible = false
                async.sleep(.05)
            end
        end
    end
    runner.done()
end)
