local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local color = require('gears.color')
local shot = require('_shape_mask_capture')
local M = {}

function M.new(class, border_width)
    local f = {steps = {}, failures = {}, class = class, border_width = border_width,
        radius = 24, bar = 32, wallpaper = '#202020', bar_color = '#808080',
        ink = '#204060', border = '#ff0000'}
    f.steps[#f.steps + 1] = function()
        root.wallpaper(color(f.wallpaper))
        screen[1].selected_tag.layout = awful.layout.suit.floating
        mouse.coords{x = 640, y = 360}
        f.report = os.tmpname()
        awful.spawn{'./build-test/test-transient-client', class, f.report, '0', 'ff204060'}
        return true
    end
    f.steps[#f.steps + 1] = function(n)
        f.client = utils.find_client_by_class(class)
        if not f.client then assert(n < 30, 'client did not map'); return end
        local c = f.client
        c.floating, c.shadow = true, false
        assert(c.animation == nil, "fixture must leave animation unset")
        assert(require("somewm.animation").word(c, "layout") == nil, "fixture must not author a transition")
        c.shape, c.border_width, c.border_color = f.radius, border_width, f.border
        awful.titlebar(c, {size = f.bar, bg_normal = f.bar_color, bg_focus = f.bar_color})
        c:geometry{x = 100, y = 100, width = 300, height = 220}
        return true
    end
    return setmetatable(f, {__index = M})
end

-- Check both readers and every stage before failing, so a bad screen.content
-- pixel does not prevent the corresponding device-pixel capture through grim.
function M:stage(label, scale, setup, radii, check, inner)
    local done, ppm, failure, box
    local function inspect(read, pixel_scale, reader)
        local name = string.format('%s scale=%g %s', label, scale, reader)
        local ok, err = pcall(check, read, pixel_scale, box)
        if not ok then self.failures[#self.failures + 1] = name .. ': ' .. tostring(err) end
        io.stderr:write((ok and '[PASS] ' or '[FAIL] ') .. name .. (ok and '' or ': ' .. tostring(err)) .. '\n')
    end
    self.steps[#self.steps + 1] = function()
        screen[1].scale = scale
        setup(self.client)
        return true
    end
    self.steps[#self.steps + 1] = shot.wait(function()
        local c = self.client
        assert(not c._committed_size, 'client resize pending')
        local dump = awesome._clay_tree(screen[1])
        local frame = assert(dump:match('\n( *CLIENT ' .. self.class .. ' [^\n]*)'))
        local pixels = assert(dump:match('\n( *SURFACE ' .. self.class .. ' [^\n]*)'))
        assert(frame:find(' clip ', 1, true), frame)
        assert(pixels:match(' radii (%S+)') == radii, pixels)
        local x, y, w, h = frame:match(' box (%S+),(%S+) (%S+)x(%S+)')
        box = {x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h)}
        if c.floating then assert(shot.pixel(20, 20) == self.wallpaper, 'wallpaper pending') end
        assert(shot.pixel(box.x + 64, box.y + 12) == self.bar_color, 'titlebar pending')
        local ink = shot.pixel(box.x + 64, box.y + 96)
        assert(ink == self.ink, 'surface pending: ' .. ink)
        if inner then
            assert(shot.pixel(box.x + self.border_width + 2,
                box.y + self.border_width + self.bar + 2) == inner, 'inner fill pending')
        end
        local image = surface(screen[1].content)
        inspect(function(px, py) return capture.read(image, px, py) end, 1, 'screen.content')
        done, ppm, failure = false, nil, nil
        if not utils.is_headless() then done = true; return end
        local path = os.tmpname()
        awful.spawn.easy_async({'grim', '-o', screen[1].output.name, '-t', 'ppm', path}, function(_, err, _, code)
            if code ~= 0 then failure = err else
                local file = assert(io.open(path, 'rb'))
                ppm = file:read('*a'); file:close()
            end
            os.remove(path)
            done = true
        end)
    end)
    self.steps[#self.steps + 1] = function(n)
        if not done then assert(n < 40, 'grim did not finish'); return end
        assert(not failure, failure)
        if ppm then
            local width, _, header = ppm:match('^P6%s+(%d+)%s+(%d+)%s+255%s()')
            assert(width, 'not a P6 capture')
            inspect(function(px, py)
                local at = header + (py * tonumber(width) + px) * 3
                return ppm:byte(at, at + 2)
            end, scale, 'grim')
        end
        return true
    end
end

function M:run()
    self.steps[#self.steps + 1] = function()
        self.client:kill()
        os.remove(self.report)
        screen[1].scale = 1
        assert(#self.failures == 0, table.concat(self.failures, '\n'))
        return true
    end
    runner.run_steps(self.steps, {kill_clients = false})
end

return M
