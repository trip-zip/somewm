-- A titlebar button's mouse::enter can drain after its client closed. The
-- tooltip then attaches to a titlebar whose node is gone: the host must match
-- nothing instead of crashing the compositor.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))

runner.run_async(function()
    awful.spawn {binary, 'tooltip_closed_titlebar'}
    local c = assert(async.wait_for_client('tooltip_closed_titlebar', 3))
    local button = wibox.widget.textbox('x')
    local bar = awful.titlebar(c, {size = 20})
    bar.widget = button
    local tooltip = awful.tooltip {text = 'Close'}

    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 2, .02))
    tooltip.show(button, {widget = button, drawable = bar, occurrence = 1})
    assert(tooltip.wibox.drawin.attachment.host ~= 0,
        'a closed titlebar host must not search every host')

    tooltip.hide()
    runner.done()
end)
