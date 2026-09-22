-- Attachment border paint follows the solved host, including size/style changes.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local example = require('_clay_example')
local capture = require('_widget_capture')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    require('gears.wallpaper').set('#ffffff')
    local leaf = wibox.widget.base.make_widget(nil, nil, {enable_properties = true})
    clay.describe_widget(leaf, function()
        return {w = leaf.forced_width, h = 40, bg = {1, 0, 0, 1}}
    end, 'attachment-border-content')
    leaf.forced_width = 80
    local popup = awful.popup {screen = screen[1], visible = true, ontop = true,
        bg = '#ff0000', border_width = 3, border_color = '#0000ff', shadow = false,
        placement = function(d) awful.placement.top_left(d, {offset = {x = 100, y = 100}}) end,
        widget = leaf}
    local presses, releases = 0, 0
    leaf:connect_signal('button::press', function(original, x, y, button, mods, area)
        assert(original == leaf and area.widget == leaf and x == 2 and y == 2)
        assert(button == 1 and #mods == 0)
        presses = presses + 1
    end)
    leaf:connect_signal('button::release', function(original, x, y, button)
        assert(original == leaf and x == 2 and y == 2 and button == 1)
        releases = releases + 1
    end)
    local structural = {}
    local id
    local function check(name, width, bw, color)
        local g = popup:geometry()
        assert(g.width == width and g.height == 40, 'attachment content allocation changed')
        local found
        for _, hit in ipairs(popup:find_widgets(2, 2)) do
            if hit.widget == leaf then found = hit end
        end
        capture.assert_box(found, {x = 0, y = 0, width = width, height = 40}, 'original content')
        example.pixel(g.x + 2, g.y + 2, '#ff0000')
        if bw > 0 then
            example.pixel(g.x - 1, g.y + 10, color)
            example.pixel(g.x + width, g.y + 10, color)
            example.pixel(g.x + 10, g.y - 1, color)
            example.pixel(g.x + 10, g.y + 40, color)
        end
        example.pixel(g.x - bw - 1, g.y + 10, '#ffffff')
        local dump = awesome._clay_tree(screen[1])
        example.save(name, dump)
        local next_id = assert(popup._drawable._clay_wired[leaf][1].id)
        assert(not id or id == next_id, 'decoration changed original occurrence ID')
        id = next_id
        local head = assert(dump:match('POPUP [^\n]+'))
        if head:find(' image ', 1, true) then structural[#structural + 1] = name end
    end
    for _, width in ipairs {80, 160, 40} do
        leaf.forced_width = width
        async.sleep(0.15)
        check('attachment-border-' .. width, width, 3, '#0000ff')
    end
    popup.border_width, popup.border_color = 7, '#00ff00'
    async.sleep(0.15)
    check('attachment-border-style', 40, 7, '#00ff00')
    local g = popup:geometry()
    awful.spawn {pointer, 'click', tostring(g.x + 2), tostring(g.y + 2), '1280', '720', 'left'}
    for _ = 1, 30 do if releases == 1 then break end; async.sleep(0.02) end
    assert(presses == 1 and releases == 1, 'original content lost real input')
    popup.border_width = 0
    async.sleep(0.15)
    check('attachment-border-none', 40, 0)
    popup.border_width = 3
    async.sleep(0.15)
    check('attachment-border-restored', 40, 3, '#00ff00')
    popup.shadow = {radius = 6, offset_x = 6, offset_y = 6, spread = 0,
        corner_radius = 0, opacity = 1, color = '#000000'}
    async.sleep(0.15)
    g = popup:geometry()
    example.pixel(g.x - 1, g.y + 10, '#00ff00')
    local r, green, b = capture.read(require('gears.surface')(root.content()),
        g.x + g.width + 5, g.y + 20)
    assert(r < 220 and green < 220 and b < 220, 'shadow transition lost decoration')
    example.save('attachment-border-shadow', awesome._clay_tree(screen[1]))
    popup.shadow = false
    async.sleep(0.15)
    check('attachment-border-shadow-removed', 40, 3, '#00ff00')
    popup.shape = function(cr, w, h) require('gears.shape').rounded_rect(cr, w, h, 10) end
    async.sleep(0.15)
    g = popup:geometry()
    example.pixel(g.x - 3, g.y - 3, '#ffffff')
    example.pixel(g.x - 1, g.y + 20, '#00ff00')
    example.save('attachment-border-shaped', awesome._clay_tree(screen[1]))
    popup.shape = nil
    async.sleep(0.15)
    check('attachment-border-shape-removed', 40, 3, '#00ff00')
    popup.visible = false
    io.stderr:write('[PASS] attachment border resize/style pixels, original areas, IDs and real input\n')
    assert(#structural == 0, 'attachment still uses a previous-size decoration image: ' .. table.concat(structural, ', '))
    runner.done()
end)
