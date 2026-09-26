local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local gears = require('gears')
local s = screen.primary
local bars = {}
local star, before

local function warnings()
    io.stderr:flush()
    local path = assert(os.getenv('SOMEWM_TEST_LOG'), 'SOMEWM_TEST_LOG is not set')
    local log = assert(io.open(path, 'r'))
    local count = 0
    for line in log:lines() do
        if line:find('shape is not a rounded rectangle', 1, true) then
            count = count + 1
        end
    end
    log:close()
    return count
end

local function rounded(cr, w, h)
    gears.shape.rounded_rect(cr, w, h, 8)
end

local function host_line(kind, host)
    local geo = host:geometry()
    local prefix = string.format('%s screen %d %dx%d+%d+%d ',
        kind, s.index, geo.width, geo.height, geo.x, geo.y)
    for line in awesome._clay_tree(s):gmatch('[^\n]+') do
        if line:find(prefix, 1, true) then return line end
    end
end

runner.run_steps({
    function()
        before = warnings()
        s.scale = 1
        bars[1] = awful.wibar {screen=s, position='top', height=32, border_width=0,
            shape=rounded, widget=wibox.widget.textbox('rounded-1')}
        return true
    end,
    function()
        local line = host_line('WIBAR', bars[1])
        if not line or not line:find('radius 8 ', 1, true) then return end
        local count = warnings() - before
        assert(count == 0, 'the rounded bar at scale 1 warned ' .. count .. ' times')
        return true
    end,
    function()
        s.scale = 1.5
        bars[2] = awful.wibar {screen=s, position='bottom', height=32, border_width=0,
            shape=rounded, widget=wibox.widget.textbox('rounded-1.5')}
        return true
    end,
    function()
        local line = host_line('WIBAR', bars[2])
        if not line or not line:find('radius 8 ', 1, true) then return end
        local count = warnings() - before
        assert(count == 0, 'the rounded bar at scale 1.5 warned ' .. count .. ' times')
        return true
    end,
    function()
        star = wibox {screen=s, x=100, y=100, width=100, height=100,
            border_width=0, shadow=false, shape=gears.shape.star, visible=true,
            widget=wibox.widget.textbox('star')}
        return true
    end,
    function()
        if not host_line('drawin', star) then return end
        local count = warnings() - before
        assert(count == 1, 'the star warned ' .. count .. ' times, expected once')
        return true
    end,
    function()
        bars[1]:remove()
        bars[2]:remove()
        star.visible = false
        s.scale = 1
        return true
    end,
}, {kill_clients=false})
