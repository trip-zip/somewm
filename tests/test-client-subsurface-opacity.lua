local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))

runner.run_async(function()
    local s = screen[1]
    local wall = awful.wallpaper {screen = s, bg = '#000000'}
    local report = os.tmpname()
    local pid = awful.spawn {binary, '--subsurfaces', 'opacity_subsurface_test',
        report, '0', 'ff0000ff', '0'}
    local c = assert(async.wait_for_client('opacity_subsurface_test', 3))
    c.floating, c.border_width, c.shadow = true, 0, false
    c.animation = false
    c:geometry {x = 40, y = 40, width = 200, height = 200}
    mouse.coords {x = 1000, y = 600}
    async.sleep(.15)

    local sequence = 0
    local function child(signal)
        sequence = sequence + 1
        awesome.kill(pid, signal)
        assert(async.wait_for_condition(function()
            local f = io.open(report .. '.subsurface')
            if not f then return false end
            local value = tonumber(f:read('*a'))
            f:close()
            return value == sequence
        end, 2, .01), 'subsurface action did not complete')
        async.sleep(.08)
    end

    local function pixels(opacity, has_child)
        local image = surface(s.content)
        local g = c:geometry()
        local function expect(x, y, wanted)
            local actual = {capture.read(image, g.x + x, g.y + y)}
            for i = 1, 3 do
                assert(math.abs(actual[i] - wanted[i]) <= 2,
                    string.format('pixel %d,%d channel %d: got %d, expected %.1f',
                        x, y, i, actual[i], wanted[i]))
            end
        end
        expect(20, 20, {0, 0, 255 * opacity})
        if has_child then
            expect(80, 80, {255 * opacity, 255 * opacity,
                255 * (opacity + opacity * (1 - opacity))})
        else
            expect(80, 80, {0, 0, 255 * opacity})
        end
    end

    c.opacity = .5
    async.sleep(.12)
    pixels(.5, false)
    child(10) -- Create a subsurface after opacity was declared.
    pixels(.5, true)
    child(10) -- Repaint only the desynchronized subsurface.
    pixels(.5, true)
    assert(c.opacity == .5)

    client.focus = c
    async.sleep(.12)
    pixels(.5, true)
    for _, opacity in ipairs {.25, 0, 1, .5} do
        c.opacity = opacity
        async.sleep(.12)
        child(10)
        pixels(opacity, true)
    end
    c.opacity = nil
    async.sleep(.12)
    child(10)
    pixels(1, true)

    c.opacity = .5
    async.sleep(.12)
    child(12) -- Destroy the child while its parent stays mapped.
    pixels(.5, false)
    child(10)
    child(10)
    pixels(.5, true)
    c:geometry {width = 240, height = 220}
    async.sleep(.15)
    child(10)
    pixels(.5, true)

    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 2, .02))
    os.remove(report)
    os.remove(report .. '.subsurface')
    wall:detach()
    runner.done()
end)
