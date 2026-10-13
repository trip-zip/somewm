-- Content-sized square art refuses an indefinite offer until a size is forced.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local debug = require('gears.debug')

runner.run_async(function()
    local warnings = {}
    local print_warning = debug.print_warning
    debug.print_warning = function(message)
        warnings[#warnings + 1] = message
    end

    local arcchart = wibox.container.arcchart(wibox.widget.textbox('content'))
    local checkbox = wibox.widget.checkbox(true)
    local popup = awful.popup {
        screen = screen[1],
        visible = true,
        widget = wibox.layout.fixed.horizontal(arcchart, checkbox),
    }
    async.sleep(.15)

    for _, class in ipairs {'checkbox', 'arcchart'} do
        local count = 0
        for _, warning in ipairs(warnings) do
            if warning:find(class, 1, true) then
                count = count + 1
                assert(warning:find('no definite axis', 1, true), warning)
                assert(warning:find('force a size or put it in a sized host', 1, true), warning)
                assert(warning:find('and is left out of the tree', 1, true), warning)
            end
        end
        assert(count == 1, class .. ': expected one no definite axis warning, got ' .. count)
    end
    for class, widget in pairs {checkbox = checkbox, arcchart = arcchart} do
        local entry = assert(popup._drawable._clay_wired[widget], class .. ' is not wired')[1]
        assert(entry.element == nil, class .. ' has an element without a definite axis')
    end

    for _, widget in ipairs {checkbox, arcchart} do
        widget.forced_width, widget.forced_height = 40, 40
    end
    async.sleep(.15)

    for _, widget in ipairs {checkbox, arcchart} do
        local entry = assert(popup._drawable._clay_wired[widget])[1]
        local box = assert(assert(entry.element).box)
        assert(box.width == 40 and box.height == 40,
            string.format('forced square box %gx%g expected 40x40', box.width, box.height))
    end
    debug.print_warning = print_warning
    popup.visible = false
    io.stderr:write('[PASS] indefinite square art warns once per class, refuses nodes and accepts forced sizes\n')
    runner.done()
end)
