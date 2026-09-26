-- Hotkeys help is a floating element of the workarea, centered in it.
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
        local wa = s.workarea
        assert(popup.x==wa.x+math.floor((wa.width-popup.width)/2+0.5))
        assert(popup.y==wa.y+math.floor((wa.height-popup.height)/2+0.5))
        example.pixel(popup.x+popup.width-2, popup.y+popup.height-2, '#204080')
        assert(#popup:find_widgets(10,10)>0)
    end
    check()
    bar.height=100
    async.sleep(0.3)
    check()
    example.save('hotkeys-workarea-attachment', awesome._clay_tree(s))
    box:hide()
    bar:remove()
    async.sleep(.1)
    runner.assert_no_errors()
    runner.done()
end)
