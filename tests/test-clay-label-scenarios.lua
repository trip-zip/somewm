local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local awful = require('awful')
local capture = require('_widget_capture')

local function textbox(text)
    local tb = wibox.widget.textbox(text)
    tb.font = 'DejaVu Sans 10'
    return tb
end

local function settle()
    awesome._test_redeclare()
    async.sleep(.15)
end

local function box(host, widget)
    return assert(host._drawable._clay_wired[widget][1].element.box)
end

runner.run_async(function()
    local s = screen[1]
    local row = wibox.layout.fixed.horizontal()
    row.spacing = 5
    local labels = {}
    for _, text in ipairs{'dev', '  ', '  media ', '日本語', '  left', 'right  ', 'a   b', '   '} do
        local tb = textbox(text)
        labels[#labels + 1] = tb
        row:add(tb)
    end
    local title = textbox('A long window title beside mixed tag labels')
    row:add(title)
    local bar = wibox{screen = s, x = 10, y = 20, width = 800, height = 32,
        visible = true, bg = '#101010', fg = '#ffffff', widget = row}
    local cap = capture.new(s, 10, 20, 800, 32)
    local initial
    for _, scale in ipairs{1, 1.5, .8, 1} do
        s.scale = scale
        settle()
        local right = 0
        for _, tb in ipairs(labels) do
            local b = box(bar, tb)
            local preferred = tb:get_preferred_size(s)
            assert(math.abs(b.width - preferred) <= 1, 'label width differs: ' .. tb.text)
            assert(b.x >= right, 'labels overlap: ' .. tb.text)
            right = b.x + b.width
        end
        local wide = cap:shot()
        local blank = box(bar, labels[#labels])
        assert(blank.width > 0, 'spaces-only label lost its advance')
        for y = 0, cap.height - 1 do
            for x = blank.x, blank.x + blank.width - 1 do
                cap:assert_pixel(wide, x, y, '#101010', 'spaces-only label')
            end
        end
        if scale == 1 then
            if initial then assert(wide == initial, 'scale round trip changed label pixels') end
            initial = wide
        end
        local title_x = box(bar, title).x
        bar.width = title_x + 70
        settle()
        local crowded = cap:shot()
        assert(box(bar, title).width < title:get_preferred_size(s), 'title was not constrained')
        -- The title may truncate, but the preceding labels keep their pixels.
        for y = 0, cap.height - 1 do
            local offset = y * cap.width * 4 + 1
            assert(crowded:sub(offset, offset + title_x * 4 - 1)
                == wide:sub(offset, offset + title_x * 4 - 1), 'crowding changed tag pixels')
        end
        title.ellipsize = 'none'
        settle()
        assert(cap:shot() ~= crowded, 'constrained title did not ellipsize')
        title.ellipsize = 'end'
        bar.width = 800
        settle()
        assert(cap:shot() == wide, 'expansion retained truncated text')
    end

    assert(awesome._test_add_output(1280, 720))
    async.sleep(.15)
    local other = screen[2]
    other.scale = 1.5
    bar.screen = other
    bar.x, bar.y = other.geometry.x + 10, other.geometry.y + 20
    settle()
    for _, tb in ipairs(labels) do
        assert(math.abs(box(bar, tb).width - tb:get_preferred_size(other)) <= 1,
            'moving outputs kept the old label width: ' .. tb.text)
    end
    local moved = capture.new(other, 10, 20, 800, 32):shot()
    local fresh = wibox{screen = other, x = bar.x, y = bar.y, width = 800, height = 32,
        visible = true, bg = '#101010', fg = '#ffffff', widget = row}
    bar.visible = false
    settle()
    assert(capture.new(other, 10, 20, 800, 32):shot() == moved,
        'moved labels differ from a fresh host on the destination output')
    fresh.visible = false
    bar.screen = s
    bar.x, bar.y, bar.visible = 10, 20, true
    settle()
    assert(cap:shot() == initial, 'moving outputs and back changed label pixels')
    bar.visible = false

    local phrase = 'one two three four five six'
    local label, wrapped = textbox(phrase), textbox(phrase)
    wrapped.ellipsize = 'none'
    local function popup(tb, y)
        return awful.popup{screen = s, x = 10, y = y, minimum_width = 90, maximum_width = 90,
            visible = true, border_width = 0, shadow = false, widget = tb}
    end
    local single = popup(label, 80)
    settle()
    local single_height = single.height
    local multi = popup(wrapped, 180)
    settle()
    local wrapped_height = multi.height
    assert(wrapped_height > single_height, 'word-wrapped textbox stayed on one line')
    assert(single.height == single_height, 'wrapped sibling changed the label height')
    label.ellipsize, wrapped.ellipsize = 'none', 'end'
    settle()
    assert(single.height == wrapped_height and multi.height == single_height,
        'changing wrap modes reused the other mode measurement')
    label.ellipsize, wrapped.ellipsize = 'end', 'none'
    settle()
    assert(single.height == single_height and multi.height == wrapped_height,
        'restoring wrap modes changed line breaks')
    single.visible, multi.visible = false, false
    io.stderr:write('[PASS] mixed labels, whitespace, crowded bar, scale/output changes and wrapping\n')
    runner.done()
end)
