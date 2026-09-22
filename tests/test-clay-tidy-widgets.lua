-- Handwritten fold/retain boundaries, purposeful space and native overlap.
local wibox = require('wibox')
local awful = require('awful')
local beautiful = require('beautiful')
local tidy = require('_clay_tidy')
local cases = {}

local function add(name, create)
    cases[#cases + 1] = {name='tidy-' .. name, create=function()
        local widget, cleanup = create()
        return {popup=tidy.popup(widget), widget=widget, cleanup=cleanup}
    end}
end
local function text(value) return wibox.widget.textbox(value) end
local function padded(widget, vertical)
    return wibox.container.margin(widget, 8, 8, vertical or 0, vertical or 0)
end
add('background-padding', function()
    return wibox.container.background(padded(text('12:34')), '#0000ff')
end)
add('padding-background', function()
    return padded(wibox.container.background(text('12:34'), '#0000ff'))
end)
add('nested-backgrounds', function()
    return wibox.container.background(padded(
        wibox.container.background(text('Inside'), '#ff0000'), 8), '#0000ff')
end)
add('shared-click-box', function()
    local label = text('Click')
    local background = wibox.container.background(label, '#0000ff')
    -- Register both objects. Folding must preserve both matching listeners.
    local events = {}
    for _, widget in ipairs{background, label} do
        widget:buttons {awful.button({}, 1, function()
            events[#events + 1] = widget
        end)}
    end
    return background
end)
add('empty-and-spacer', function()
    local spacer = tidy.leaf(0, 0, '#204080')
    spacer.forced_width, spacer.forced_height = 20, 16
    local layout = wibox.layout.fixed.horizontal()
    layout.spacing = 4
    layout:add(wibox.widget.imagebox(), text(''), text('A'), spacer, text('B'))
    return layout
end)
for _, count in ipairs{0,2} do
    add(count == 0 and 'systray-empty' or 'systray-two', function()
        beautiful.systray_paddings = 2
        beautiful.systray_icon_spacing = count == 0 and 0 or 4
        local items = {}
        for _, item in ipairs(systray_item.get_items()) do item.status = 'Passive' end
        for i = 1, count do
            local item = systray_item.register()
            local pixel = i == 1 and string.char(255,255,0,0) or string.char(255,0,255,0)
            item:set_icon_pixmap(16, 16, pixel:rep(16 * 16))
            items[#items + 1] = item
        end
        local tray = wibox.widget.systray()
        tray:set_base_size(24)
        tray:_update_icon_sizes()
        tray:_sync_items()
        return tray, function()
            for _, item in ipairs(items) do item.status = 'Passive' end
            tray:_sync_items()
        end
    end)
end
add('clay-overlap', function()
    local a, b = tidy.leaf(0, 0, '#ff0000'), tidy.leaf(0, 0, '#00ff00')
    a.forced_width, a.forced_height = 100, 20
    b.forced_width, b.forced_height = 40, 60
    local stack = wibox.layout.stack(a, b)
    stack.forced_width, stack.forced_height = 120, 80
    return stack
end)

assert(#cases == 8)
tidy.run(cases)
