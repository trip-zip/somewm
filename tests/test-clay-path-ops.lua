-- clay.shape_ops reads the path back through awesome._path_ops; it must
-- record what lgi's cairo.Path iteration records.
local runner = require('_runner')
local wclay = require('wibox.clay')
local shape = require('gears.shape')

local function lgi_ops(fn, w, h, dx, dy, ...)
    local path_ops = awesome._path_ops
    awesome._path_ops = nil
    local ok, ops = pcall(wclay.shape_ops, fn, w, h, dx, dy, ...)
    awesome._path_ops = path_ops
    return assert(ok and ops, ops)
end

runner.run_steps {
    function()
        assert(awesome._path_ops, 'awesome._path_ops is registered')
        for name, case in pairs {
            rectangle = { shape.rectangle, 40, 20 },
            rounded_rect = { shape.rounded_rect, 40, 20, 0, 0, 6 },
            circle_offset = { shape.circle, 30, 30, 1.5, 2.5 },
            arc = { shape.arc, 40, 40, 0.5, 0.5, 4, 0, 2 * math.pi },
            subpaths = { function(cr)
                cr:move_to(1, 2)
                cr:line_to(3, 4)
                cr:stroke()
                for i = 1, 25 do cr:rectangle(i * 2, 0, 2, 10) end
                cr:fill_preserve()
                cr:curve_to(1, 2, 3, 4, 5, 6)
                cr:close_path()
            end, 60, 20, 1, 1 },
        } do
            local fast = wclay.shape_ops((table.unpack or unpack)(case))
            local slow = lgi_ops((table.unpack or unpack)(case))
            assert(#fast > 0, name .. ': records a path')
            assert(#fast == #slow, string.format('%s: %d ops, lgi %d', name, #fast, #slow))
            for i = 1, #fast do
                assert(fast[i] == slow[i], string.format('%s: op %d is %s, lgi %s',
                    name, i, fast[i], slow[i]))
            end
        end
        return true
    end,
}
