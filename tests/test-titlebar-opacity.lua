-- luacheck: globals screen mouse
-- c.opacity applies to the client's titlebars as well as its surface, as
-- in 2.0 and AwesomeWM, where it set the opacity of the whole frame
-- (issue 873). A white titlebar over a black wallpaper reads 255 opaque,
-- 128 at 0.5.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))

runner.run_async(function()
    local s = screen[1]
    local wall = awful.wallpaper {screen = s, bg = '#000000'}
    local report = os.tmpname()
    awful.spawn {binary, 'titlebar_opacity_test', report, '0', 'ff0000ff', '0'}
    local c = assert(async.wait_for_client('titlebar_opacity_test', 3))
    c.floating, c.border_width, c.shadow, c.animation = true, 0, false, false
    c:geometry {x = 40, y = 40, width = 200, height = 200}
    awful.titlebar(c, {size = 20, bg_normal = '#ffffff', bg_focus = '#ffffff'}).widget =
        wibox.widget.textbox()
    mouse.coords {x = 1000, y = 600}

    -- Red of the titlebar, blue of the surface, at the right edge of each.
    local function pixels()
        local image = surface(s.content)
        local g = c:geometry()
        local bar = capture.read(image, g.x + g.width - 10, g.y + 10)
        local _, _, body = capture.read(image, g.x + g.width - 10, g.y + 100)
        return bar, body
    end

    local function settles(opacity)
        local want, bar, body = math.floor(255 * opacity + .5)
        local ok = async.wait_for_condition(function()
            bar, body = pixels()
            return math.abs(bar - want) <= 2 and math.abs(body - want) <= 2
        end, 2, .02)
        assert(ok, string.format('opacity %s: titlebar reads %d, surface %d, expected %d',
            tostring(opacity), bar, body, want))
        io.stderr:write(string.format('[PASS] opacity %s: titlebar %d, surface %d\n',
            tostring(opacity), bar, body))
    end

    settles(1)
    c.opacity = .5
    settles(.5)
    c.opacity = nil
    settles(1)

    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 2, .02))
    os.remove(report)
    wall:detach()
    runner.done()
end)
