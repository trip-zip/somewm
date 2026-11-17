-- Every realized box rounds both edges, so configures match geometry and
-- adjacent boxes share an edge instead of leaving a background seam.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local beautiful = require('beautiful')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local utils = require('_utils')

local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]
local colors = {'cc0000', '00cc00', '0000cc', 'cccc00', 'cc00cc', '00cccc',
    '663300', '336600'}

-- screen.content is the composited output at the screen's logical size, so a
-- sample is a logical pixel at every scale. At 1.25 that pixel is a resample
-- of 1.25 device columns, which is what makes a one-pixel seam show up as a
-- colour that is not any child's.
local function pixel(im, lx, ly)
    local r, g, b = capture.read(im, lx, ly)
    return string.format('%02x%02x%02x', r, g, b)
end

local function report(path)
    local f = assert(io.open(path))
    local w, h = f:read('*a'):match('(%d+)%s+(%d+)')
    f:close()
    return tonumber(w), tonumber(h)
end

-- Polls check until it returns no error, up to five seconds, then asserts on
-- its last answer. The solve, the configures, the clients' buffers and the
-- frame showing them arrive over several frames after a change.
local function eventually(check)
    local err
    async.wait_for_condition(function()
        err = check()
        return not err
    end, 5, 0.05)
    assert(not err, err)
end

local function is_client_color(got)
    for _, c in ipairs(colors) do
        if c == got then return true end
    end
    return false
end

runner.run_async(function()
    local clients, reports = {}, {}
    -- No borders: the client boxes are the slots, so a seam pixel is either a
    -- client or the background, with nothing painted in between.
    beautiful.border_width = 0
    s.selected_tag.layout = awful.layout.suit.tile
    s.selected_tag.gap, s.selected_tag.gap_single_client = 0, true
    s.selected_tag.master_width_factor = 0.5
    s.selected_tag.master_count = 1
    -- One master and seven slaves: the slave column's height never divides by
    -- seven, so every slave edge but the first and last is fractional.
    for i = 1, 8 do
        reports[i] = os.tmpname()
        awful.spawn {binary, 'ROUND_' .. i, reports[i], '0', 'ff' .. colors[i]}
        local c = assert(async.wait_for_client('ROUND_' .. i, 5), 'client did not map')
        clients[i] = c
        c.floating, c.shadow, c.border_width = false, false, 0
    end

    for _, scale in ipairs {1, 1.25} do
        s.scale = scale
        utils.wait_for_solve(s)
        local label = 'scale ' .. scale
        eventually(function()
            local im = surface(s.content)

            -- Every client learns the size its geometry reports.
            for i, c in ipairs(clients) do
                local g = c:geometry()
                local w, h = report(reports[i])
                if w ~= g.width or h ~= g.height then
                    return string.format('%s: %s configured %sx%s but geometry is %dx%d',
                        label, c.class, tostring(w), tostring(h), g.width, g.height)
                end
            end

            -- The slave column: the boxes tile it, and both sides of every seam
            -- are client pixels.
            -- The master is whichever client the layout put in the left column.
            local slaves = {}
            for _, c in ipairs(clients) do
                if c:geometry().x > s.workarea.x then slaves[#slaves + 1] = c end
            end
            if #slaves ~= 7 then return label .. ': ' .. #slaves .. ' slaves, want 7' end
            table.sort(slaves, function(a, b) return a:geometry().y < b:geometry().y end)
            local column = slaves[1]:geometry()
            local middle = column.x + math.floor(column.width / 2)
            local cursor = column.y
            for i, c in ipairs(slaves) do
                local g = c:geometry()
                if g.x ~= column.x or g.width ~= column.width then
                    return label .. ': slave ' .. i .. ' left the column'
                end
                if g.y ~= cursor then
                    return string.format('%s: slave %d starts at %d, previous ended at %d',
                        label, i, g.y, cursor)
                end
                cursor = g.y + g.height
                if i > 1 then
                    local above, below = pixel(im, middle, g.y - 1), pixel(im, middle, g.y)
                    if not (is_client_color(above) and is_client_color(below)) then
                        return string.format('%s: seam at y=%d shows %s above and %s below',
                            label, g.y, above, below)
                    end
                end
            end
            if cursor ~= column.y + s.workarea.height then
                return string.format('%s: slave column ends at %d, workarea at %d', label, cursor,
                    column.y + s.workarea.height)
            end
        end)
    end

    for _, c in ipairs(clients) do c:kill() end
    for _, r in ipairs(reports) do os.remove(r) end
    assert(async.wait_for_no_clients(5), 'clients stayed managed')

    -- A flex of three GROW children across the full width: 1280 in thirds is
    -- 426.667, so two of the three edges are fractional.
    local parts = {'aa2200', '22aa00', '0022aa'}
    local bar = awful.wibar {screen = s, position = 'top', height = 24,
        bg = '#111111', widget = {layout = wibox.layout.flex.horizontal,
            {widget = wibox.container.background, bg = '#' .. parts[1]},
            {widget = wibox.container.background, bg = '#' .. parts[2]},
            {widget = wibox.container.background, bg = '#' .. parts[3]}}}

    for _, scale in ipairs {1, 1.25} do
        s.scale = scale
        utils.wait_for_solve(s)
        local label = 'flex at scale ' .. scale
        eventually(function()
            local im = surface(s.content)
            local geo = bar:geometry()
            local row = geo.y + math.floor(geo.height / 2)
            local seen, starts, ends = {}, {}, {}
            for x = geo.x, geo.x + geo.width - 1 do
                local got = pixel(im, x, row)
                if got == '111111' then
                    return string.format('%s: wibox background at x=%d', label, x)
                end
                if seen[#seen] ~= got then
                    seen[#seen + 1] = got
                    starts[#seen] = x
                end
                ends[#seen] = x
            end
            local runs = {}
            for i, got in ipairs(seen) do
                runs[i] = string.format('%s[%d..%d]', got, starts[i], ends[i])
            end
            if #seen ~= 3 then return label .. ': runs ' .. table.concat(runs, ' ') end
            for i, got in ipairs(seen) do
                if got ~= parts[i] then
                    return string.format('%s: run %d is %s, want %s', label, i, got, parts[i])
                end
            end
        end)
    end

    s.scale = 1
    bar:remove()
    io.stderr:write('[PASS] configures equal geometry, tile seams and flex seams hold at scale 1 and 1.25\n')
    runner.done()
end)
