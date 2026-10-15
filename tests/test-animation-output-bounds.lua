-- Slide transitions stay on their declaring output, including paint, shadows
-- and input. Settled drawins retain ordinary cross-output overhang.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local gears = require('gears')
local capture = require('_widget_capture')

runner.run_async(function()
    local count = screen.count()
    assert(awesome._test_add_output(800, 600))
    assert(async.wait_for_condition(function() return screen.count() > count end, 2, .02))
    local left, right
    for s in screen do
        if not left or s.geometry.x < left.geometry.x then left = s end
        if not right or s.geometry.x > right.geometry.x then right = s end
    end
    local lg, rg = left.geometry, right.geometry
    assert(lg.x + lg.width == rg.x, 'outputs must be adjacent')
    awful.wallpaper {screen = left, bg = '#182838'}
    mouse.coords {x = lg.x + 10, y = lg.y + lg.height - 10}
    async.sleep(.1)
    local region = capture.new(left, lg.width - 240, 50, 240, math.min(lg.height, rg.height) - 100)
    local baseline = region:shot()

    local popup
    local function clear_neighbor(what)
        local before = awesome._clay_tree(right)
        local shot = region:shot()
        if shot ~= baseline then
            for y = 0, region.height - 1 do
                for x = 0, region.width - 1 do
                    local r, g, b = region:pixel(shot, x, y)
                    local br, bg, bb = region:pixel(baseline, x, y)
                    if r ~= br or g ~= bg or b ~= bb then
                        error(string.format('%s neighbor pixel %d,%d got #%02x%02x%02x expected #%02x%02x%02x\n%s',
                            what, x + region.x, y + region.y, r, g, b, br, bg, bb, before .. '\nLEFT:\n' .. awesome._clay_tree(left)))
                    end
                end
            end
        end
        mouse.coords {x = rg.x - 10, y = popup.y + popup.height / 2}
        local object = mouse.object_under_pointer()
        assert(not object or object ~= popup.drawin, what .. ' received input on the neighboring output')
        mouse.coords {x = lg.x + 10, y = lg.y + lg.height - 10}
    end

    for _, kind in ipairs({'popup', 'wibox'}) do
        local args = {
            screen = right, x = rg.x + 60, y = rg.y + 100,
            width = 200, height = 100, visible = false, ontop = true,
            border_width = 5, border_color = '#00ff00',
            bg = '#ff0000', shadow = {radius = 24, color = '#ffffff', opacity = 1},
            animation = {visible = {duration = .8, enter = 'slide_left', exit = 'slide_left'}},
            widget = capture.leaf_widget(200, 100, '#ff0000'),
        }
        if kind == 'popup' then
            args.placement, args.shape = awful.placement.centered, gears.shape.hexagon
        end
        popup = kind == 'popup' and awful.popup(args) or wibox(args)
        popup.visible = true
        for _ = 1, 8 do
            async.sleep(.07)
            clear_neighbor(kind .. ' entrance')
        end
        async.sleep(.35)
        assert(popup.x >= rg.x and popup.x < rg.x + rg.width, 'popup outside target: ' .. popup.x .. ',' .. popup.y .. ' screen ' .. popup.screen.index .. '\n' .. awesome._clay_tree(right))
        local r, g, b = capture.read(right.content, popup.x - rg.x + popup.width / 2,
            popup.y - rg.y + popup.height / 2)
        assert(r > 200 and g < 50 and b < 50, kind .. ' did not become visible on its own output')
        mouse.coords {x = popup.x - 12, y = popup.y + popup.height / 2}
        assert(mouse.object_under_pointer() ~= popup.drawin, 'shadow took popup input')
        mouse.coords {x = lg.x + 10, y = lg.y + lg.height - 10}
        popup.visible = false
        for _ = 1, 8 do
            async.sleep(.07)
            clear_neighbor(kind .. ' exit')
        end
        async.sleep(.35)
    end

    local overhang = wibox {
        screen = left, x = rg.x - 40, y = 100, width = 120, height = 80,
        visible = false, ontop = true, bg = '#00ff00', shadow = false,
        animation = {visible = {duration = .2, enter = 'slide_right'}},
        widget = capture.leaf_widget(120, 80, '#00ff00'),
    }
    overhang.visible = true
    async.sleep(.35)
    local dump = awesome._clay_tree(left)
    local box = string.format('rbox %d,100 120x80', rg.x - lg.x - 40)
    assert(dump:find(box, 1, true), 'settled animated drawin is still clipped: ' .. dump)
    mouse.coords {x = rg.x + 20, y = 120}
    assert(mouse.object_under_pointer() == overhang.drawin, 'settled overhang lost input')
    overhang.visible = false
    runner.done()
end)
