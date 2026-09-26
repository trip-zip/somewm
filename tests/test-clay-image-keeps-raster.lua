local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local cairo = require('lgi').cairo

runner.run_async(function()
    local src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
    local cr = cairo.Context(src)
    cr:set_source_rgb(1, 0, 0)
    cr:paint()
    local text = wibox.widget.textbox('one')
    local bar = awful.wibar {
        position = 'top', screen = screen[1], height = 32,
        widget = wibox.widget {
            wibox.widget.imagebox(src), text,
            layout = wibox.layout.fixed.horizontal,
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
    assert(settled, 'the bar did not settle')
    text.text = 'two'
    local mutations = awesome._test_redeclare()
    io.stderr:write('image beside textbox: mutations=' .. mutations .. '\n')
    assert(mutations == 1, 'an unchanged image re-rastered beside a changed textbox')
    bar:remove()
    runner.done()
end)
