-- luacheck: globals screen mouse
-- A white titlebar and border over black wallpaper read 255 when opaque
-- and 128 at opacity 0.5, matching the blue channel of the client surface.
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
    c.floating, c.border_width, c.shadow, c.animation = true, 10, false, false
    c.border_color = "#ffffff"
    c:geometry {x = 40, y = 40, width = 200, height = 200}
    awful.titlebar(c, {size = 20, bg_normal = '#ffffff', bg_focus = '#ffffff'}).widget =
        wibox.widget.textbox()
    mouse.coords {x = 1000, y = 600}

    -- The frame includes the border. c:geometry() excludes its width.
    local function pixels()
        local tree = awesome._clay_tree(s)
        local frame = tree:match('CLIENT titlebar_opacity_test [^\n]+')
        if not frame then return end
        local x, y, width, height = frame:match('box ([%d.-]+),([%d.-]+) ([%d.-]+)x([%d.-]+)')
        if not x then return end
        x, y, width, height = tonumber(x), tonumber(y), tonumber(width), tonumber(height)
        local image = surface(s.content)
        local bar = capture.read(image, x + width - 20, y + 20)
        local _, _, body = capture.read(image, x + width - 20, y + 110)
        local border = capture.read(image, x + 5, y + math.floor(height / 2))
        return bar, body, border
    end

    local function settles(opacity)
        local want, bar, body, border = math.floor(255 * opacity + .5)
        local ok = async.wait_for_condition(function()
            bar, body, border = pixels()
            return bar and math.abs(bar - want) <= 2 and math.abs(body - want) <= 2
                and math.abs(border - bar) <= 2
        end, 2, .02)
        assert(ok, string.format('opacity %s: titlebar reads %s, surface %s, border %s, expected %d',
            tostring(opacity), tostring(bar), tostring(body), tostring(border), want))
        io.stderr:write(string.format('[PASS] opacity %s: titlebar %d, surface %d, border %d\n',
            tostring(opacity), bar, body, border))
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
