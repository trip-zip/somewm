local runner = require('_runner')
local wibox = require('wibox')
local s = screen.primary
local host

local function host_declared()
    local prefix = string.format('drawin screen %d 200x100+100+100 ', s.index)
    for line in awesome._clay_tree(s):gmatch('[^\n]+') do
        if line:find(prefix, 1, true) and not line:find(' nothing:', 1, true) then
            return true
        end
    end
end

runner.run_steps({
    function()
        host = wibox {screen=s, x=100, y=100, width=200, height=100,
            border_width=0, shadow=false, visible=true,
            widget=wibox.widget.textbox('lookup')}
        return true
    end,
    function()
        return host_declared()
    end,
    function()
        local n = #host:find_widgets(10, 10)
        assert(n == 1, 'the inside point found ' .. n .. ' widgets, expected 1')
        return true
    end,
    function()
        host.visible = false
        return true
    end,
    function()
        local n = #host:find_widgets(10, 10)
        assert(n == 0, 'the hidden host found ' .. n .. ' widgets, expected 0')
        return true
    end,
    function()
        host.visible = true
        return true
    end,
    function()
        return host_declared()
    end,
    function()
        local n = #host:find_widgets(250, 150)
        assert(n == 0, 'the outside point found ' .. n .. ' widgets, expected 0')
        return true
    end,
    function()
        local n = #host:find_widgets(10, 10)
        assert(n == 1, 'the inside point found ' .. n .. ' widgets, expected 1')
        return true
    end,
    function()
        host.visible = false
        return true
    end,
}, {kill_clients=false})
