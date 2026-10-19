-- Carousel navigation keeps an overflowing strip inside its own output.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local surface = require('gears.surface')

if screen.count() < 2 then
    return runner.skip('requires the two-output lane with WLR_HEADLESS_OUTPUTS=2')
end

local binary = utils.binary_or_skip('./build-test/test-transient-client')
if not binary then return end
local carousel = awful.layout.suit.carousel
local left, right = screen[1], screen[2]
local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')

runner.run_async(function()
    left.output.position = {x = 0, y = 0}
    right.output.position = {x = left.geometry.width, y = 0}
    left.selected_tag.layout = carousel
    awful.screen.focus(left)
    mouse.coords {x = 10, y = 10}
    local wall = awful.wallpaper {screen = right, bg = '#123456'}
    async.sleep(.15)
    local function pixels()
        local image = surface(right.content)
        local rows = {}
        for y = 0, right.geometry.height - 1 do
            rows[#rows + 1] = awesome._surface_pixels(image._native, 0, y, right.geometry.width, 1)
        end
        assert(image:get_width() == right.geometry.width)
        return table.concat(rows)
    end
    local baseline = pixels()
    local clients = {}
    for i = 1, 5 do
        local class = 'carousel_clip_' .. i
        awful.spawn {binary, class, '/dev/null', '0', 'ffcc0000', '0'}
        local c = assert(async.wait_for_client(class, 2), class .. ' did not map')
        c:move_to_screen(left)
        c:tags {left.selected_tag}
        c.floating, c.shadow, c.border_width = false, false, 0
        clients[i] = c
        async.sleep(.1)
    end
    carousel.focus_first_column()
    async.sleep(.15)
    local previous
    local function check(name)
        async.sleep(.15)
        local info = carousel.get()
        assert(info.width > info.viewport.width, 'strip does not overflow')
        local first = awesome._clay_tree(left)
        local second = awesome._clay_tree(right)
        assert(first:find('CAROUSEL_VIEWPORT ', 1, true), first)
        assert(first:find('SCISSOR_START', 1, true), first)
        assert(first:find('carousel_clip_', 1, true), 'strip clients are absent')
        assert(not second:find('carousel_clip_', 1, true), second)
        assert(not second:find('CAROUSEL_', 1, true), second)
        local actual = pixels()
        if evidence then
            for index, dump in ipairs {first, second} do
                local f = assert(io.open(evidence .. '/' .. name .. '-output' .. index .. '.dump', 'w'))
                f:write(dump); f:close()
            end
            surface(right.content):write_to_png(evidence .. '/' .. name .. '-output2.png')
        end
        assert(actual == baseline, name .. ': strip changed output 2 pixels')
        if previous then
            assert(info.position ~= previous, name .. ': navigation did not scroll')
        end
        previous = info.position
        io.stderr:write('[PASS] ' .. name .. ' output 2 commands and pixels unchanged\n')
    end
    check('initial')
    for i = 1, 4 do
        awful.client.focus.byidx(1, client.focus)
        check('next-' .. i)
    end
    for i = 1, 4 do
        awful.client.focus.byidx(-1, client.focus)
        check('prev-' .. i)
    end
    for _, c in ipairs(clients) do c:kill() end
    wall:detach()
    runner.done()
end)
