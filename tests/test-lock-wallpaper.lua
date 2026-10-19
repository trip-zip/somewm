-- Lock images use the desktop's aspect fit, with a full-box dimming layer.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local gears = require('gears')
local beautiful = require('beautiful')
local capture = require('_widget_capture')
local lock = require('_lock_helper')
local awful = require('awful')

local headless = os.getenv('WLR_BACKENDS') == 'headless'

local function image_line(dump)
    return dump:match('[^\n]* IMAGE [^\n]*widget image[^\n]*')
end

local function image_box(dump)
    local line = assert(image_line(dump), dump)
    local x, y, w, h = line:match('box ([%d.-]+),([%d.-]+) ([%d.-]+)x([%d.-]+)')
    return {tonumber(x), tonumber(y), tonumber(w), tonumber(h)}, line
end

local function wait_dump(s, ready, what)
    local first, dump = true
    assert(async.wait_for_condition(function()
        dump = awesome._clay_tree(s)
        -- The immediate read describes the frame before the state change.
        if first then first = false; return false end
        return ready(dump)
    end), what .. ' did not reach the dump\n' .. tostring(dump))
    return dump
end

local function save(name, text)
    local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
    if not dir then return end
    local f = assert(io.open(dir .. '/' .. name .. '.dump', 'w'))
    f:write(text); f:close()
end

local function grim(output, path)
    local finished, status
    awful.spawn.easy_async({'grim', '-o', output, path}, function(_, stderr, _, code)
        status = code
        finished = true
        if code ~= 0 then io.stderr:write(stderr) end
    end)
    assert(async.wait_for_condition(function() return finished end, 5), 'grim timed out')
    assert(status == 0, 'grim failed')
end

local function pixel(shot, x, y, want)
    local r, g, b = capture.read(shot, x, y)
    local got = string.format('#%02x%02x%02x', r, g, b)
    assert(got == want, string.format('pixel %d,%d: %s, expected %s', x, y, got, want))
end

runner.run_async(function()
    if screen.count() < 2 then
        assert(awesome._test_add_output(1100, 500))
        assert(async.wait_for_condition(function() return screen.count() == 2 end))
    end
    assert(screen.count() == 2, 'requires the two-output lane')
    local retired_drawins = {}
    local letterboxed = {}
    for _, case in ipairs({'portrait', 'landscape', 'overlay', 'false', 'default'}) do
        local orientation = case == 'landscape' and 'landscape' or 'portrait'
        local path = 'tests/fixtures/lock-wallpaper-' .. orientation .. '.png'
        local iw, ih = 500, 1100
        if case == 'landscape' then iw, ih = 1100, 500 end
        local opts = {bg_color = '#336699', clock_format = '12:00',
            date_format = 'Monday', lock_screen = screen[2]}
        beautiful.lockscreen_wallpaper = path
        beautiful.lockscreen_wallpaper_overlay = '#000000aa'
        if case == 'portrait' then
            opts.wallpaper = path
            beautiful.lockscreen_wallpaper = '/does/not/exist'
            beautiful.lockscreen_wallpaper_overlay = nil
        elseif case == 'overlay' then
            opts.wallpaper = path
            opts.wallpaper_overlay = '#000000aa'
            beautiful.lockscreen_wallpaper = '/does/not/exist'
            beautiful.lockscreen_wallpaper_overlay = '#ff0000'
        elseif case == 'false' then
            opts.wallpaper = false
            opts.lock_screen = false
        elseif case == 'default' then
            beautiful.lockscreen_wallpaper = nil
            beautiful.lockscreen_wallpaper_overlay = nil
            opts.lock_screen = nil
        end
        package.loaded.lockscreen = nil
        require('lockscreen').init(opts)
        local has_image = case ~= 'false' and case ~= 'default'
        local locked_boxes = {}
        awesome.lock()
        -- Fresh module instances retain signal handlers for their old surfaces.
        for _, d in ipairs(retired_drawins) do d.visible = false end
        for s in screen do
            local dump = wait_dump(s, function(tree)
                if not tree:find('LOCK ', 1, true) then return false end
                if has_image then
                    return image_line(tree) ~= nil
                        and tree:find(string.format('image image %dx%d', iw, ih), 1, true) ~= nil
                end
                return image_line(tree) == nil
            end, 'lock background')
            save(case .. '-lock-' .. s.index, dump)
            assert(dump:find('LOCK ', 1, true), dump)
            local interactive = s == ((case == 'false' or case == 'default') and screen.primary or screen[2])
            if has_image then
                local box, image = image_box(dump)
                locked_boxes[s] = box
                local g = s.geometry
                local scale = math.min(g.width / iw, g.height / ih)
                local ew, eh = math.ceil(iw * scale), math.ceil(ih * scale)
                assert(box[3] == ew and box[4] == eh, image)
                assert(math.abs(box[1] - (g.width - ew) / 2) <= 1
                    and math.abs(box[2] - (g.height - eh) / 2) <= 1, image)
                if headless then
                    local shot_path = os.tmpname() .. '.png'
                    grim(s.output.name, shot_path)
                    local shot = gears.surface.load(shot_path)
                    local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
                    if dir then shot:write_to_png(dir .. '/' .. case .. '-lock-' .. s.index .. '.png') end
                    pixel(shot, math.floor(box[1] + box[3] / 2),
                        math.floor(box[2] + math.min(3, box[4] / 2)), '#442211')
                    -- Sample a margin only when the solved image leaves one.
                    local lx, ly
                    if box[1] >= 1 then
                        lx, ly = math.floor(box[1] / 2), 0
                    elseif box[2] >= 1 then
                        lx, ly = 0, math.floor(box[2] / 2)
                    elseif g.width - box[1] - box[3] >= 1 then
                        lx, ly = math.floor((box[1] + box[3] + g.width) / 2), 0
                    elseif g.height - box[2] - box[4] >= 1 then
                        lx, ly = 0, math.floor((box[2] + box[4] + g.height) / 2)
                    end
                    if lx then
                        pixel(shot, lx, ly, '#112233')
                        letterboxed[s] = true
                    end
                    os.remove(shot_path)
                end
                local overlay
                for line in dump:gmatch('[^\n]+') do
                    if line:find(' RECTANGLE ', 1, true)
                        and line:find('widget wibox.container.background', 1, true)
                        and line:find(string.format('box 0,0 %dx%d', g.width, g.height), 1, true) then
                        overlay = line
                    end
                end
                assert(overlay, 'missing full-box overlay on ' .. case .. ' screen ' .. s.index)
                local realized = assert(dump:match('  realized:\n(.*)'))
                if overlay then
                    assert(realized:find(image, 1, true) < realized:find(overlay, 1, true), 'overlay must follow image')
                    if interactive then
                        assert(realized:find(overlay, 1, true) < assert(realized:find(' TEXT ', 1, true)), 'UI must follow overlay')
                    end
                end
            else
                assert(not dump:find('widget image', 1, true), 'image present while disabled')
                if headless then
                    local shot_path = os.tmpname() .. '.png'
                    grim(s.output.name, shot_path)
                    pixel(gears.surface.load(shot_path), 3, 3, '#336699')
                    os.remove(shot_path)
                end
            end
            assert((dump:find('Enter password to unlock', 1, true) ~= nil) == interactive,
                'password UI must appear only on interactive screen')
        end
        for _, d in ipairs(drawin.get()) do retired_drawins[#retired_drawins + 1] = d end
        lock.teardown()
        for s in screen do
            wait_dump(s, function(tree) return not tree:find('LOCK ', 1, true) end, 'unlock')
        end
        if has_image then
            local wallpapers = {}
            for s in screen do
                wallpapers[#wallpapers + 1] = awful.wallpaper {screen = s, widget = {
                    {image = path, upscale = true, downscale = true, widget = wibox.widget.imagebox},
                    valign = 'center', halign = 'center', widget = wibox.container.place,
                }}
            end
            for s in screen do
                local dump = wait_dump(s, function(tree)
                    return not tree:find('LOCK ', 1, true) and image_line(tree) ~= nil
                        and tree:find(string.format('image image %dx%d', iw, ih), 1, true) ~= nil
                end, 'desktop wallpaper')
                save(case .. '-wallpaper-' .. s.index, dump)
                local box = image_box(dump)
                local expected = locked_boxes[s]
                for i = 1, 4 do assert(box[i] == expected[i], 'desktop and lock aspect fit differ') end
            end
            for _, wp in ipairs(wallpapers) do wp:detach() end
            for s in screen do
                wait_dump(s, function(tree) return image_line(tree) == nil end, 'wallpaper removal')
            end
        end
    end
    if headless then
        -- Different fixture aspects must exercise a letterbox on each output.
        for s in screen do assert(letterboxed[s], 'no letterbox pixel checked on screen ' .. s.index) end
    end
    runner.done()
end)
