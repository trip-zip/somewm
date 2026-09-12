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
    surface(root.content()):write_to_png(dir .. '/' .. name .. '.png')
end

function example.check(name, dump)
    -- The backend's output name is the only difference in headless sandboxes.
    local normalized = dump:gsub('HEADLESS%-1', 'WL-1')
    golden.check(name, normalized)
    example.save(name, dump)
end

function example.pixel(x, y, want)
    local r, g, b = capture.read(surface(root.content()), x, y)
    local got = string.format('#%02x%02x%02x', r, g, b)
    assert(got == want, string.format('pixel (%d,%d): want %s, have %s', x, y, want, got))
end

return example
