-- Evidence for doc-2 examples. Goldens remain handwritten; captures are optional.
local golden = require('_clay_golden')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local example = { shape = golden.shape }

function example.save(name, dump)
    local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
    if not dir then return end
    local f = assert(io.open(dir .. '/' .. name .. '.dump', 'w'))
    f:write(dump); f:close()
    f = assert(io.open(dir .. '/' .. name .. '.shape', 'w'))
    f:write(golden.shape(dump:gsub('HEADLESS%-1', 'WL-1'))); f:close()
    surface(root.content()):write_to_png(dir .. '/' .. name .. '.png')
end

function example.check(name, dump)
    -- The backend's output name is the only difference in headless sandboxes.
    local normalized = dump:gsub('HEADLESS%-1', 'WL-1')
    example.save(name, dump)
    golden.check(name, normalized)
end

-- Collect independent shape failures while retaining a failing test result.
-- Call finish after cleanup, so every case can leave review evidence.
function example.batch()
    assert(os.getenv('SOMEWM_GOLDEN') ~= 'record', 'reviewed expectations must not be recorded')
    local failures, checked = {}, {}
    return {
        check = function(name, dump)
            assert(not checked[name], 'duplicate golden case: ' .. name)
            checked[name] = true
            local ok, err = pcall(example.check, name, dump)
            if ok then return true end
            failures[#failures + 1] = name
            local message = tostring(err)
            io.stderr:write('[GOLDEN DIFFERENCE] ', name, '\n', message, '\n')
            local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
            if dir then
                local f = assert(io.open(dir .. '/' .. name .. '.difference', 'w'))
                f:write(message, '\n'); f:close()
            end
            return false
        end,
        finish = function()
            assert(next(checked), 'no golden cases checked')
            assert(#failures == 0, 'golden differences: ' .. table.concat(failures, ', '))
            return true
        end,
    }
end

function example.pixel(x, y, want)
    local r, g, b = capture.read(surface(root.content()), x, y)
    local got = string.format('#%02x%02x%02x', r, g, b)
    assert(got == want, string.format('pixel (%d,%d): want %s, have %s', x, y, want, got))
end

return example
