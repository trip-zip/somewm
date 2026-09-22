-- Hotkeys help uses the same OUTPUT attachment as popup centering.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local help = require('awful.hotkeys_popup.widget')
local example = require('_clay_example')

runner.run_async(function()
    local s = screen[1]
    local bar = awful.wibar {screen=s, position='top', height=60,
        widget=wibox.widget.textbox('reserved')}
    local instance = help.new {width=400, height=240, bg='#204080',
        border_width=0, shape=require('gears.shape').rectangle}
    instance:_load_widget_settings()
    instance:add_hotkeys {commands={{modifiers={}, keys={a='A command'}}}}
    local box = instance:_create_wibox(s, {'commands'}, false)
    box:show()
    async.sleep(0.3)
    local function check()
        local popup, output = box.popup, s.geometry
        local a = popup.drawin.attachment
        assert(a.kind==3 and a.parent==4 and a.own==4)
        assert(popup.width==400 and popup.height==240)
        assert(popup.x==output.x+math.floor((output.width-popup.width)/2+0.5))
        assert(popup.y==output.y+math.floor((output.height-popup.height)/2+0.5))
        example.pixel(popup.x+popup.width-2, popup.y+popup.height-2, '#204080')
        assert(#popup:find_widgets(10,10)>0)
    end
    check()
    bar.height=100
    async.sleep(0.3)
    check()
    example.save('hotkeys-output-attachment', awesome._clay_tree(s))
    box:hide()
    bar:remove()
    runner.done()
end)
