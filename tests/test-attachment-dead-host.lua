-- A drawin attached to the titlebar of a client that is gone must not crash.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))

runner.run_async(function()
    awful.spawn {binary, 'DEAD_HOST', os.tmpname(), '0', 'ff203040', '0'}
    local c = assert(async.wait_for_client('DEAD_HOST', 2))
    awful.titlebar(c, {size = 20}).widget = wibox.widget.textbox('title')
    async.sleep(.1)
    local host = c:titlebar_top()
    c:kill()
    assert(async.wait_for_no_clients(2))
    local w = wibox {screen = screen[1], width = 50, height = 20, visible = true}
    w.drawin.attachment = {kind = 1, host = host}
    async.sleep(.1)
    w.visible = false
    io.stderr:write('[PASS] attachment to a dead titlebar host\n')
    runner.done()
end)
