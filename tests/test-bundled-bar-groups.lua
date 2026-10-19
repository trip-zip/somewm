-- The bundled bar is three groups in one align, the clock between them.
-- The widget table matches somewmrc.lua; clock, tags and tasks are fixed.
-- Each group has an equal half, so the clock stays centered however wide
-- the groups are: tasks shrink to share it and anything wider is clipped.
local awful = require('awful')
local wibox = require('wibox')
local gears = require('gears')
local beautiful = require('beautiful')
local cairo = require('lgi').cairo
local s = screen[1]
local function hide_foreign()
    local changed = false
    for _, item in ipairs(systray_item.get_items()) do
        if item.status ~= 'Passive' then
            item.status = 'Passive'
            changed = true
        end
    end
    if changed then awesome.emit_signal('systray::update') end
    return changed
end
local function image(size)
    local surface = cairo.ImageSurface.create(cairo.Format.ARGB32, size, size)
    local cr = cairo.Context(surface)
    cr:set_source_rgb(1, 0, 0); cr:paint()
    return surface
end
local function task(title)
    local entry = wibox.widget {
        {
            {
                {image = image(16), widget = wibox.widget.imagebox},
                left = 6, right = 2, top = 4, bottom = 4,
                widget = wibox.container.margin,
            },
            {
                {
                    {
                        {text = title, widget = wibox.widget.textbox},
                        id = 'title_role',
                        widget = wibox.container.scroll.horizontal,
                    },
                    halign = 'left',
                    widget = wibox.container.place,
                },
                right = 6,
                widget = wibox.container.margin,
            },
            layout = wibox.layout.fixed.horizontal,
        },
        bg = '#3c3836',
        widget = wibox.container.background,
    }
    entry:get_children_by_id('title_role')[1]:pause()
    return entry
end
-- Short titles leave two tasks at their full width inside the left half.
local function tasks(count, title)
    local row = {id = 'tasks', spacing = 4, layout = wibox.layout.fixed.horizontal}
    for i = 1, count do row[#row + 1] = task((title or 'Terminal number ') .. i) end
    return wibox.widget(row)
end
local long_title = 'jimmy@jimmy: ~/tools/some/a/long/working/directory number '
-- One word cannot wrap or shrink: wider than its half for a reason other than tasks.
local wide_word = string.rep('Wide', 60)

-- The dump's widget nodes as {line, name, x, y, w, h, parent, in_bar}.
-- An id line's indent after the id is its depth.
local function parse(dump)
    local nodes, stack, bar, desc, in_bar = {}, {}, nil, nil, false
    for line in dump:gmatch('[^\n]+') do
        if line:match('^  realized:') then break end
        if line:match('^%s+WIBAR ') then
            in_bar = true
            desc = assert(line:match('WIBAR (screen %d+ %d+x%d+%+%d+%+%d+)'))
            local x, w = line:match('box (%-?%d+),%-?%d+ (%d+)x%d+')
            bar = {x = tonumber(x), w = tonumber(w)}
        elseif line:match('^%s+WORKAREA ') then
            in_bar = false
        end
        local pad, rest = line:match('^%s+%x+( +)(%S.*)$')
        if pad then
            local x, y, w, h = rest:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            local node = {line = rest, name = rest:match('^(%S+)'), depth = #pad,
                x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
                in_bar = in_bar}
            while #stack > 0 and stack[#stack].depth >= node.depth do stack[#stack] = nil end
            node.parent = stack[#stack]
            stack[#stack + 1] = node
            nodes[#nodes + 1] = node
        end
    end
    assert(bar, 'no WIBAR in the dump')
    bar.id = assert(dump:match('\n  (%x+) %u[%u_]* [^\n]* drawin '
        .. desc:gsub('%+', '%%+') .. '\n'), 'no realized drawin for ' .. desc)
    return nodes, bar
end

local function find(nodes, pattern)
    for _, n in ipairs(nodes) do
        if n.line:match(pattern) then return n end
    end
    error('no node matching ' .. pattern)
end

local function ancestor(node, name)
    local n = node.parent
    while n and n.name ~= name do n = n.parent end
    return assert(n, 'no ' .. name .. ' above ' .. node.line)
end

-- Every failing assertion of every case is reported before the test fails.
local failures = {}
local function expect(case, ok, message)
    if not ok then failures[#failures + 1] = case .. ': ' .. message end
end

-- The realized TEXT command drawn for a text node, by its solved box.
local function realized(dump, node)
    local box = string.format('box %d,%d %dx%d rbox ', node.x, node.y, node.w, node.h)
    for line in dump:gmatch('\n  %x+ TEXT [^\n]*') do
        if line:find(box, 1, true) then
            local x, y, w, h = line:match('rbox (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return {x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h)}
        end
    end
    error('no realized TEXT at ' .. box)
end

local function check(case, dump, opts)
    local nodes, bar = parse(dump)
    expect(case, dump:match('roots flow %d+ floating %d+ derived 0 legacy 0'), 'derived or legacy sizes in the dump')
    for _, n in ipairs(nodes) do
        if n.in_bar then
            expect(case, not n.line:find(' attach ', 1, true), 'float in the bar: ' .. n.line)
            expect(case, not n.line:find('stack', 1, true), 'stack in the bar: ' .. n.line)
        end
        expect(case, not n.line:find('target ' .. bar.id, 1, true), 'float on the bar: ' .. n.line)
    end
    local clock_text = find(nodes, '^text "Fri Sep 12')
    local clock = ancestor(clock_text, 'wibox.container.background')
    local right = find(nodes, '^wibox%.widget%.systray ').parent
    local half = find(nodes, '^%- spacer clip ')
    print(string.format('%s: bar %d+%d half %d+%d clock %d+%d right %d+%d', case,
        bar.x, bar.w, half.x, half.w, clock.x, clock.w, right.x, right.w))
    expect(case, clock.in_bar, 'the clock is outside the bar subtree')
    local off = math.abs((clock.x + clock.w / 2) - (bar.x + bar.w / 2))
    expect(case, off <= 1, string.format('clock centre is %.1f px off the bar centre', off))
    expect(case, half.x + half.w <= clock.x and clock.x + clock.w <= right.x,
        'groups out of order: left, clock, right')
    if opts.tasks then
        local list = find(nodes, '^tasks ')
        expect(case, list.x + list.w <= clock.x, string.format(
            'tasks end at %d, past the clock at %d', list.x + list.w, clock.x))
        local widths = {}
        for _, n in ipairs(nodes) do
            if n.parent == list then widths[#widths + 1] = n.w end
            if n.name == 'text' and n.line:find('^text "' .. (opts.title or 'Terminal')) then
                local drawn = realized(dump, n)
                expect(case, n.h == clock_text.h, string.format('title on %d lines: %s',
                    math.floor(n.h / clock_text.h), n.line))
                if opts.shrunk then
                    expect(case, drawn.w > 0 and drawn.w < n.w and drawn.x + drawn.w <= clock.x,
                        'title not cut to its task: ' .. n.line)
                else
                    expect(case, drawn.w == n.w, 'title cut inside its half: ' .. n.line)
                end
            end
        end
        expect(case, #widths == opts.tasks, #widths .. ' tasks, expected ' .. opts.tasks)
        table.sort(widths)
        expect(case, widths[#widths] - widths[1] <= 1, string.format(
            'tasks are %d to %d px wide', widths[1], widths[#widths]))
    end
    if opts.wide then
        local word = find(nodes, '^text "WideWide')
        local drawn = realized(dump, word)
        expect(case, word.x + word.w > half.x + half.w, 'the wide word fits its half')
        expect(case, drawn.x + drawn.w <= half.x + half.w, string.format(
            'the wide word is drawn to %d, past its half at %d', drawn.x + drawn.w, half.x + half.w))
    end
end

local bar, left, previous
local function settled(name, opts)
    return function(n)
        if hide_foreign() then return end
        local dump = awesome._clay_tree(s)
        if n < 3 or previous ~= dump then
            previous = dump
            assert(n < 30, name .. ' did not settle')
            return
        end
        check(name, dump, opts)
        return true
    end
end

require('_runner').run_steps {
    function()
        beautiful.font = 'sans 10'
        beautiful.wibar_height = 32
        beautiful.bg_normal, beautiful.bg_focus = '#282828', '#3c3836'
        beautiful.fg_normal, beautiful.fg_focus = '#ffffff', '#ffffff'
        beautiful.systray_paddings, beautiful.systray_icon_spacing = 0, 0
        beautiful.awesome_icon = image(24)
        beautiful.layout_tile = image(24)
        s.selected_tag.name = 'dev'
        s.selected_tag.layout = awful.layout.suit.tile
        for _, name in ipairs{'web', 'chat', 'files', 'media'} do
            awful.tag.add(name, {screen = s, layout = awful.layout.suit.tile})
        end
        hide_foreign()
        local clock = wibox.widget {
            {
                {format = 'Fri Sep 12  09:14', widget = wibox.widget.textclock},
                left = 8, right = 8,
                widget = wibox.container.margin,
            },
            bg = beautiful.bg_focus,
            shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 4) end,
            widget = wibox.container.background,
        }
        left = wibox.widget {
            layout = wibox.layout.fixed.horizontal,
            awful.widget.launcher {image = beautiful.awesome_icon,
                menu = awful.menu {items = {}}},
            awful.widget.taglist {screen = s, filter = awful.widget.taglist.filter.all},
            awful.widget.prompt(),
            tasks(2),
        }
        local right = {
            layout = wibox.layout.fixed.horizontal,
            wibox.widget.systray(),
            awful.widget.layoutbox(s),
        }
        bar = awful.wibar {position = 'top', screen = s, widget = {
            layout = wibox.layout.align.horizontal,
            expand = 'none',
            left,
            {clock, top = 6, bottom = 6, widget = wibox.container.margin},
            right,
        }}
        return true
    end,
    settled('bar with tasks inside its half', {tasks = 2}),
    function()
        -- Long titles: the tasks share what the half leaves them, each title cut.
        left:set(4, tasks(6, long_title))
        previous = nil
        return true
    end,
    settled('bar with many long-titled tasks', {tasks = 6, title = 'jimmy@', shrunk = true}),
    function()
        -- Wider than the half for another reason: clipped at the half.
        left:set(4, wibox.widget {id = 'tasks', text = wide_word, widget = wibox.widget.textbox})
        previous = nil
        return true
    end,
    settled('bar with a group wider than its half', {wide = true}),
    function()
        bar:remove()
        for _, f in ipairs(failures) do io.stderr:write(f, '\n') end
        assert(#failures == 0, #failures .. ' bar assertions failed')
        return true
    end,
}
