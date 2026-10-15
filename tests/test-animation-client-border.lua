-- A client committing whole cells may remain larger than its animated frame.
-- Its border must wrap the visible chrome throughout a shrinking allocation.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local capture = require('_widget_capture')
local utils = require('_utils')
local wibox = require('wibox')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function frame(class)
    local dump = awesome._clay_tree(s)
    assert(not dump:find('[tree!=scene]', 1, true), dump)
    for line in dump:gmatch('[^\n]+') do
        if line:find('CLIENT ' .. (class or 'BORDER_FRAME') .. ' ', 1, true) then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
        end
    end
    error('no border client frame: ' .. dump)
end

runner.run_async(function()
    local t = s.selected_tag
    t.layout, t.master_width_factor, t.gap = awful.layout.suit.tile, .5, 0
    beautiful.border_focus, beautiful.border_normal = '#ff00ff', '#ff00ff'
    beautiful.animation_layout_duration = 1.5
    beautiful.animation_tag_duration = .3
    ruled.client.append_rule {rule = {class = 'BORDER_FRAME'},
        properties = {floating = false, border_width = 6, border_color = '#ff00ff',
            titlebars_enabled = false, shadow = false}}
    local report = os.tmpname()
    awful.spawn {binary, 'BORDER_FRAME', report, '0', 'ff203040', '0', '0', '0', '1000'}
    local c = assert(async.wait_for_client('BORDER_FRAME', 2))
    async.sleep(.2)
    local other_report = os.tmpname()
    awful.spawn {binary, 'BORDER_OTHER', other_report, '0', 'ff203040', '0'}
    local other = assert(async.wait_for_client('BORDER_OTHER', 2))
    other.border_width, other.shadow = 0, false
    local checked = 0
    for _ = 1, 18 do
        async.sleep(.06)
        local x, y, width, height = frame()
        if width < 990 and width > s.workarea.width / 2 + 10 then
            local image = s.content
            for _, point in ipairs({{x + width - 2, y + height / 2},
                    {x + width / 2, y + height - 2}}) do
                local r, g, b = capture.read(image, math.floor(point[1]), math.floor(point[2]))
                assert(r > 240 and g < 15 and b > 240,
                    string.format('animated border missing at %d,%d: #%02x%02x%02x, frame %dx%d',
                        math.floor(point[1]), math.floor(point[2]), r, g, b, width, height))
            end
            checked = checked + 1
        end
    end
    assert(checked >= 2, 'did not sample the shrinking border')
    c:kill()
    other:kill()
    async.sleep(.2)
    t.master_width_factor = .68
    ruled.client.append_rule {rule = {class = 'BORDER_MOVING'},
        properties = {floating = false, border_width = 6, border_color = '#ff00ff',
            titlebars_enabled = false, shadow = false}}
    -- A minimum-sized floating surface can exceed its shrinking allocation
    -- even when it commits exactly the size requested by the compositor.
    awful.spawn {binary, 'BORDER_MOVING', report, '900', 'ff203040', '0'}
    c = assert(async.wait_for_client('BORDER_MOVING', 2))
    awful.titlebar(c, {size = 46}).widget = wibox.widget.textbox('Moving window')
    awful.spawn {binary, 'BORDER_OTHER', other_report, '0', 'ff203040', '0'}
    other = assert(async.wait_for_client('BORDER_OTHER', 2))
    other.border_width, other.shadow = 6, false
    other.border_color = '#ff00ff'
    async.sleep(1.8)
    c:swap(other)
    checked = 0
    for _ = 1, 18 do
        async.sleep(.06)
        local x, y, width, height = frame('BORDER_MOVING')
        local ox, _, ow = frame('BORDER_OTHER')
        if x > 10 and x + width > ox + ow + 8 and width < 900 then
            local image = s.content
            local px, py = math.floor(x + width - 2), math.floor(y + height / 2)
            local r, g, b = capture.read(image, px, py)
            assert(r > 240 and g < 15 and b > 240,
                string.format('moving surface covered border at %d,%d: #%02x%02x%02x', px, py, r, g, b))
            checked = checked + 1
        end
    end
    assert(checked >= 2, 'did not sample the moving border')
    c:kill()
    other:kill()
    os.remove(report)
    os.remove(other_report)
    runner.done()
end)
