-- A declared sidebar enters and exits through Clay's transitions: the tiled
-- client gives way as it enters, and keeps its place as it leaves.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function line(dump, role)
    local found
    for text in dump:gmatch('[^\n]+') do
        if text:match('^%s*' .. role .. ' ') then
            assert(not found, 'two ' .. role .. ' lines: ' .. dump)
            found = text
        end
    end
    return found
end

local function box(dump, role)
    local text = assert(line(dump, role), role .. ' is not in the dump: ' .. dump)
    local x, y, w, h = text:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    assert(x, 'no box: ' .. text)
    return {tonumber(x), tonumber(y), tonumber(w), tonumber(h)}, text
end

local function expect(dump, role, wanted)
    local actual, text = box(dump, role)
    assert(table.concat(actual, ',') == table.concat(wanted, ','),
        text .. ' expected ' .. table.concat(wanted, ','))
end

-- The exiting sidebar is no longer declared: Clay holds it, so the dump
-- prints it as an element of its own with no role.
local function exiting(dump)
    for text in dump:gmatch('[^\n]+') do
        local w = text:match('^%s+%- w=fixed%((%d+)%) h=fixed%(720%)')
        if w then return tonumber(w), text end
    end
end

local function frames(dump)
    return tonumber((assert(dump:match('band desktop [^\n]* frames (%d+)'), dump)))
end

runner.run_async(function()
    local report = os.tmpname()
    awful.spawn {binary, 'SIDEBAR_CLIENT', report, '0', 'ff0000cc', '0'}
    local c
    for _ = 1, 100 do
        c = utils.find_client_by_class('SIDEBAR_CLIENT')
        if c then break end
        async.sleep(.02)
    end
    assert(c, 'client did not map')
    c.floating, c.shadow = false, false
    -- The frame starts at the theme's width while the property still reads
    -- zero, so the width has to change before it can be set to zero.
    c._border_width = 2
    c._border_width = 0

    local showing, duration = false, 1
    local fixture = {name = 'sidebar-fixture', arrange = function() end,
        _clay = function()
            local children = {}
            if showing then
                children[1] = {role = 'SIDEBAR', w = {fixed = 240}, h = 'grow',
                    transition = {duration = duration, properties = 'width',
                        enter = 'collapse', exit = 'collapse', exit_order = 'natural'}}
            end
            children[#children + 1] = {client = c}
            return {role = 'WORKAREA', direction = 'row', children = children}
        end}
    s.selected_tag.layout = fixture

    local function dump()
        local text = awesome._clay_tree(s)
        assert(not text:find('[tree!=scene]', 1, true), text)
        return text
    end

    local function configured()
        local f = assert(io.open(report))
        local size = f:read('*a'):match('(%d+%s+%d+)')
        f:close()
        return size
    end

    awful.layout.arrange(s)
    async.sleep(.3)
    expect(dump(), 'CLIENT', {0, 0, 1280, 720})

    -- Entering: the sidebar widens from nothing and the client gives way.
    showing = true
    awful.layout.arrange(s)
    async.sleep(.3)
    local entering = dump()
    local width = box(entering, 'SIDEBAR')[3]
    io.stderr:write('[TEST] entering ' .. assert(line(entering, 'SIDEBAR')) .. '\n')
    assert(width > 0 and width < 240, 'sidebar width mid-enter: ' .. width)
    expect(entering, 'CLIENT', {width, 0, 1280 - width, 720})
    async.sleep(1)
    local entered = dump()
    expect(entered, 'SIDEBAR', {0, 0, 240, 720})
    expect(entered, 'CLIENT', {240, 0, 1040, 720})
    assert(configured() == '1040 720', 'configure after enter: ' .. configured())

    -- Exiting: the sidebar shrinks where it stands, holding no space.
    showing = false
    awful.layout.arrange(s)
    async.sleep(.3)
    local leaving = dump()
    local remains, text = exiting(leaving)
    io.stderr:write('[TEST] exiting ' .. assert(text, leaving) .. '\n')
    assert(remains > 0 and remains < 240, 'sidebar width mid-exit: ' .. remains)
    expect(leaving, 'CLIENT', {0, 0, 1280, 720})
    async.sleep(1)
    local left = dump()
    assert(not exiting(left), 'the sidebar outlived its exit: ' .. left)
    expect(left, 'CLIENT', {0, 0, 1280, 720})
    assert(configured() == '1280 720', 'configure after exit: ' .. configured())

    -- Settled transitions leave the output alone.
    async.sleep(.5)
    local idle = frames(dump())
    async.sleep(.5)
    assert(frames(dump()) == idle, 'the band kept framing while idle')

    -- A shorter duration is done well inside the same wait.
    duration, showing = .2, true
    awful.layout.arrange(s)
    async.sleep(.5)
    local short = dump()
    expect(short, 'SIDEBAR', {0, 0, 240, 720})
    expect(short, 'CLIENT', {240, 0, 1040, 720})

    s.selected_tag.layout = awful.layout.suit.tile
    c:kill()
    os.remove(report)
    io.stderr:write('[PASS] clay sidebar transition: enter, exit, idleness and duration\n')
    runner.done()
end)
