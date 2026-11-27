-- Issue 984: hotkeys help names a "#keycode" key by its symbol and prints
-- merged keys joined by "/".
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local help = require('awful.hotkeys_popup.widget')

local function bind(args)
    args.modifiers, args.group, args.on_press = {'Mod4'}, 'names', function() end
    return awful.key(args)
end

runner.run_async(function()
    local s = screen[1]
    local keysym, printed = awful.keyboard.get_key_name('#10')
    assert(keysym == '1' and printed == '1', 'get_key_name("#10"): '..tostring(keysym))
    assert(awful.keyboard.get_key_name('#9999') == nil)
    assert(awful.keyboard.get_key_name('1') == '1', 'a digit key is named by its symbol')

    bind {keygroup='numrow', description='GROUPED'}
    -- Five merged keys that are in no keygroup.
    for _, k in ipairs {'a', 'b', 'c', 'd', 'e'} do bind {key=k, description='LETTERS'} end

    help.new {width=1200, height=600, bg='#204080', fg='#ffffff', font='Monospace 8',
        description_font='Monospace 8'}:show_help(nil, s)
    async.sleep(.1)
    local dump = awesome._clay_tree(s)
    for _, row in ipairs {'Super+1/2/3/4/5/6/7/8/9/0 GROUPED', 'Super+a/b/c/d/e LETTERS'} do
        assert(dump:find(row, 1, true), 'missing "'..row..'"')
    end
    _keygrabber.inject('Escape', true); _keygrabber.inject('Escape', false)
    async.sleep(.1)
    runner.assert_no_errors()
    runner.done()
end)
