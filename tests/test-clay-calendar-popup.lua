-- awful.widget.calendar_popup is an awful.popup placed by its position.
local runner = require('_runner')
local async = require('_async')
local gears = require('gears')
local awful = require('awful')
local example = require('_clay_example')

runner.run_async(function()
    -- Leave the runner's own delayed call, which starts this coroutine, before frame() runs the queue.
    async.sleep(0.01)
    local s = screen[1]
    local wa = s.workarea
    -- Pin today to 2026-01-16 12:00; every other call passes through.
    local real_date = os.date
    os.date = function(format, time)
        if format == '*t' and time == nil then
            return {year=2026, month=1, day=16, hour=12, min=0, sec=0,
                wday=6, yday=16, isdst=false}
        end
        return real_date(format, time)
    end

    local function frame()
        gears.timer.run_delayed_calls_now()
        awesome._test_redeclare()
        return awesome._clay_tree(s)
    end
    local function root(dump, role)
        local line = dump:match('\n(  ' .. role .. ' [^\n]*)')
        assert(line, role .. ' root missing:\n' .. dump)
        local x, y, w, h = line:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
        return line, tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    end
    local function clean(dump)
        assert(dump:match('roots flow %d+ floating %d+ derived 0 legacy 0'), dump)
        assert(not dump:find('[tree!=scene]', 1, true), dump)
    end
    -- The cell lines of every grid: rows are its children, cells theirs.
    local function cells(dump)
        local lines, out = {}, {}
        for line in example.shape(dump):gmatch('[^\n]+') do lines[#lines + 1] = line end
        for i, line in ipairs(lines) do
            local depth = #line:match('^ *')
            if line:find('wibox.layout.grid', 1, true) then
                for j = i + 1, #lines do
                    local d = #lines[j]:match('^ *')
                    if d <= depth then break end
                    if d == depth + 4 then out[#out + 1] = lines[j] end
                end
            end
        end
        assert(#out > 0, 'no grid cells:\n' .. dump)
        return out
    end
    local function calendar_line(dump)
        return assert(dump:match('\n( +%x+ +wibox%.widget%.calendar [^\n]*)'), 'calendar line missing')
    end

    -- Month at the top right.
    local month = awful.widget.calendar_popup.month {position = 'tr', margin = 10,
        width = 400, screen = s, font = 'monospace 10', week_numbers = true}
    assert(month:toggle() == true)
    assert(month.visible == true)
    local dump = frame()
    local line, x, y, w = root(dump, 'POPUP')
    assert(line:find('band 80', 1, true), line)
    assert(x + w == wa.x + wa.width - 10, line)
    assert(y == wa.y + 10, line)
    assert(calendar_line(dump):find('w=fixed(400) user', 1, true), calendar_line(dump))
    local shares = 0
    for _, cell in ipairs(cells(dump)) do
        if cell:find('percent(0.125)', 1, true) then
            shares = shares + 1
        else
            assert(cell:find('percent(1)', 1, true), cell)
        end
    end
    assert(shares == 48, 'day cells with percent(0.125): ' .. shares)
    clean(dump)
    assert(dump:find('January 2026', 1, true))
    io.stderr:write('[CALENDAR] month root: ', line, '\n')
    io.stderr:write('[CALENDAR] month calendar: ', calendar_line(dump), '\n')
    example.check('calendar-popup-month', dump)

    month:call_calendar(1)
    assert(frame():find('February 2026', 1, true))
    assert(month:toggle() == false)
    dump = frame()
    assert(not dump:find('  POPUP ', 1, true) and not dump:find('2026"', 1, true), dump)
    assert(month:toggle() == true)
    example.check('calendar-popup-month', frame())
    month:toggle()

    -- Under a top wibar the popup keeps to the workarea.
    local bar = awful.wibar {position = 'top', height = 32, screen = s}
    frame()
    assert(month:toggle() == true)
    dump = frame()
    local bg = bar:geometry()
    assert(bg.y == wa.y and bg.height == 32, 'wibar at ' .. bg.y .. ' height ' .. bg.height)
    line, x, y, w = root(dump, 'POPUP')
    assert(y == bg.y + bg.height + 10, line)
    assert(x + w == wa.x + wa.width - 10, line)
    io.stderr:write('[CALENDAR] under wibar: ', line, '\n')
    month:toggle()
    bar.visible = false
    frame()

    -- Month at the default position, centred.
    local centered = awful.widget.calendar_popup.month {width = 400, screen = s,
        font = 'monospace 10', week_numbers = true}
    centered:toggle()
    dump = frame()
    local h
    line, x, y, w, h = root(dump, 'POPUP')
    assert(w == 400, line)
    assert(math.abs((x - wa.x) - (wa.x + wa.width - x - w)) <= 1, line)
    assert(math.abs((y - wa.y) - (wa.y + wa.height - y - h)) <= 1, line)
    example.save('calendar-popup-centered', dump)
    io.stderr:write('[CALENDAR] centered root: ', line, '\n')
    centered:toggle()

    -- Year at the bottom left.
    local year = awful.widget.calendar_popup.year {position = 'bl', margin = 10,
        width = 900, screen = s, font = 'monospace 10', week_numbers = true}
    year:toggle()
    dump = frame()
    line, x, y, w, h = root(dump, 'POPUP')
    assert(x == wa.x + 10, line)
    assert(y + h == wa.y + wa.height - 10, line)
    assert(calendar_line(dump):find('w=fixed(900) user', 1, true), calendar_line(dump))
    for _, cell in ipairs(cells(dump)) do
        assert(cell:find('percent(', 1, true), cell)
    end
    assert(dump:find('"2026"', 1, true), dump)
    clean(dump)
    example.save('calendar-popup-year', dump)
    year:toggle()
    dump = frame()
    assert(not dump:find('  POPUP ', 1, true) and not dump:find('"2026"', 1, true), dump)

    -- Without a width.
    local plain = awful.widget.calendar_popup.month {screen = s, font = 'monospace 10'}
    plain:toggle()
    dump = frame()
    root(dump, 'POPUP')
    clean(dump)
    plain:toggle()

    os.date = real_date
    runner.done()
end)
