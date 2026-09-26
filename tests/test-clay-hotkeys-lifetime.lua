-- Hidden help objects must not remain owned by screen signal handlers.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local help = require('awful.hotkeys_popup.widget')

local function handler_count(s)
    -- Native object signal callbacks are strong references in the userdata
    -- environment; count the functions stored there without retaining them.
    local refs = debug.getuservalue and debug.getuservalue(s) or debug.getfenv(s)
    local count = 0
    for _, value in pairs(refs) do
        if type(value) == 'function' then count = count + 1 end
    end
    return count
end

runner.run_async(function()
    local s = screen.primary
    local bar = awful.wibar {screen=s, position='top', height=40,
        widget=wibox.widget.textbox('reserved')}
    async.sleep(.1)
    local before = handler_count(s)
    local dropped = setmetatable({}, {__mode='k'})
    for _=1,3 do
        local instance = help.new {width=300, height=160, bg='#204080', fg='#ffffff'}
        instance:_load_widget_settings()
        instance:add_hotkeys {commands={{modifiers={},keys={a='A command'}}}}
        local box = instance:_create_wibox(s, {'commands'}, false)
        box:show()
        box:hide()
        dropped[box] = true
        box, instance = nil, nil
    end
    async.sleep(.1)
    -- A LuaJIT trace specialized on a per-instance closure keeps that instance alive until the traces are flushed.
    if jit then jit.flush() end
    collectgarbage('collect')
    collectgarbage('collect')
    bar.height = 80
    async.sleep(.1)
    local after = handler_count(s)
    assert(after == before, 'hidden help grew the screen handler count')
    -- Finalizable drawins can survive a collection until their callbacks drain.
    if jit then jit.flush() end
    collectgarbage('collect')
    collectgarbage('collect')
    io.stderr:write(string.format('[HOTKEYS LIFETIME] screen handlers %d -> %d; retained help %s\n',
        before, after, tostring(next(dropped) ~= nil)))
    assert(next(dropped) == nil, 'hidden help object was not collected')
    bar:remove()
    runner.done()
end)
