local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local fixture = {}

local function node_for(s, d)
    for _, n in ipairs(s.tree.children) do
        if n.object == d then return n end
    end
    error('drawin node is missing')
end

function fixture.create(s)
    local a = wibox {screen = s, x = s.geometry.x + 100, y = s.geometry.y + 100,
        width = 120, height = 100, visible = true, bg = '#ff0000',
        border_width = 0, shadow = false, widget = wibox.widget.textbox('')}
    local b = wibox {screen = s, x = s.geometry.x + 120, y = s.geometry.y + 120,
        width = 140, height = 100, visible = true, bg = '#0000ff',
        border_width = 0, shadow = false, widget = wibox.widget.textbox('')}
    a.animation, b.animation = false, false
    return {screen = s, a = a, b = b}
end

function fixture.raise_first(pair)
    node_for(pair.screen, pair.a.drawin):move_after(node_for(pair.screen, pair.b.drawin))
end

function fixture.lines(pair)
    local lines = {}
    for line in awesome._clay_tree(pair.screen):gmatch('[^\n]+') do
        if line:match('^  WIBOX screen %d+ 120x100%+')
            or line:match('^  WIBOX screen %d+ 140x100%+') then
            lines[#lines + 1] = line
        end
    end
    return lines
end

function fixture.matches(pair, first_on_top)
    local r, g, b = capture.read(surface(pair.screen.content), 150, 150)
    local lines = fixture.lines(pair)
    if #lines ~= 2 then return false end
    local last_width = first_on_top and '120x100' or '140x100'
    local pixels = first_on_top and r > 240 and g < 5 and b < 5
        or not first_on_top and b > 240 and r < 5 and g < 5
    return pixels and lines[2]:find(last_width, 1, true) ~= nil
end

return fixture
