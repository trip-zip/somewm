local awful = require('awful')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local M = {}

function M.pixel(x, y)
    local r, g, b = capture.read(surface(screen[1].content), x, y)
    return string.format('#%02x%02x%02x', r, g, b)
end

function M.wait(fn)
    return function(n)
        local ok, err = pcall(fn)
        if ok then return true end
        assert(n < 15, err)
    end
end

-- screen.content uses logical pixels; grim captures device pixels.
function M.check_steps(steps, points)
    local done, ppm, failure
    steps[#steps + 1] = M.wait(function()
        for _, p in ipairs(points()) do
            assert(M.pixel(p[1], p[2]) == p[3], string.format(
                'screen.content %d,%d: %s, want %s', p[1], p[2], M.pixel(p[1], p[2]), p[3]))
        end
        done, ppm, failure = false, nil, nil
        if not utils.is_headless() then done = true; return end
        local path = os.tmpname()
        awful.spawn.easy_async({'grim', '-o', screen[1].output.name, '-t', 'ppm', path}, function(_, err, _, code)
            if code ~= 0 then failure = err else
                local f = assert(io.open(path, 'rb')); ppm = f:read('*a'); f:close()
            end
            os.remove(path)
            done = true
        end)
    end)
    steps[#steps + 1] = function(n)
        if not done then assert(n < 40, 'grim did not finish'); return end
        assert(not failure, failure)
        if ppm then
            local width, _, header = ppm:match('^P6%s+(%d+)%s+(%d+)%s+255%s()')
            assert(width, 'not a P6 capture')
            for _, p in ipairs(points()) do
                local scale = screen[1].scale
                local x, y = math.floor((p[1]+.5)*scale), math.floor((p[2]+.5)*scale)
                local at = header + (y*tonumber(width)+x)*3
                local color = string.format('#%02x%02x%02x', ppm:byte(at, at+2))
                assert(color == p[3], string.format('grim %d,%d: %s, want %s', x,y,color,p[3]))
            end
        end
        return true
    end
end
return M
