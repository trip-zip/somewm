local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local build = (os.getenv('SOMEWM') or './build-test/somewm'):match('^(.*)/somewm$')
local binary = utils.binary_or_skip(build .. '/test-fullscreen-client')
if not binary then return end

local function box(line)
    local x, y, w, h = line:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)$')
    assert(x, line)
    return {x = tonumber(x), y = tonumber(y), width = tonumber(w), height = tonumber(h)}
end

local function contains(outer, inner)
    return inner.width > 0 and inner.height > 0
        and inner.x >= outer.x and inner.y >= outer.y
        and inner.x + inner.width <= outer.x + outer.width
        and inner.y + inner.height <= outer.y + outer.height
end

runner.run_async(function()
    local physical = screen[1]
    local g = physical.geometry
    local third = math.floor(g.width / 3)
    physical:fake_resize(g.x, g.y, third, g.height)
    local middle = screen.fake_add(g.x + third, g.y, third, g.height)
    local right = screen.fake_add(g.x + 2 * third, g.y, g.width - 2 * third, g.height)
    local screens = {physical, middle, right}
    for _, s in ipairs(screens) do
        s.selected_tag.layout = awful.layout.suit.tile
        s.selected_tag.gap = 0
    end
    mouse.coords {x = g.x, y = g.y}

    local clients = {}
    for _, s in ipairs {middle, right} do
        local pid = awful.spawn {binary}
        local c
        assert(async.wait_for_condition(function()
            for _, candidate in ipairs(client.get()) do
                if candidate.pid == pid then c = candidate; return true end
            end
        end, 3), 'client did not map')
        c.animation, c.shadow, c.border_width = false, false, 0
        c.floating = false
        c:move_to_tag(s.selected_tag)
        clients[#clients + 1] = c
    end

    local function check()
        for _, c in ipairs(clients) do
            assert(c.screen.valid, 'client still belongs to the removed screen')
        end
        local dump = awesome._clay_tree(physical)
        local screen_lines, surfaces, frames, line_number = {}, {}, {}, 0
        local current_screen
        for line in dump:gmatch('[^\n]+') do
            line_number = line_number + 1
            if line:match('^  %S') then current_screen = nil end
            local index = line:match('^%s*SCREEN (%d+) ')
            if index then
                current_screen = tonumber(index)
                screen_lines[current_screen] = {line = line, number = line_number}
            elseif line:match('^%s*CLIENT fullscreen_test ') then
                assert(current_screen, 'tiled CLIENT must be inside a SCREEN subtree')
                frames[#frames + 1] = {screen = current_screen, box = box(line)}
            elseif line:match('^%s*SURFACE fullscreen_test ') then
                surfaces[#surfaces + 1] = {box = box(line), number = line_number}
            end
        end
        assert(#frames == #clients, 'each client must declare one frame under its SCREEN')
        assert(#surfaces == #clients, 'each client must declare one SURFACE')
        assert(select(2, dump:gsub('\n%s*SCREEN %d+ ', '')) == #screens)
        for _, s in ipairs(screens) do
            local entry = assert(screen_lines[s.index], 'missing SCREEN')
            local geometry = s.geometry
            assert(entry.line:find(string.format('w=fixed(%d) user h=fixed(%d) user',
                geometry.width, geometry.height), 1, true), entry.line)
            assert(entry.line:find(' attach OUTPUT ', 1, true), entry.line)
            assert(entry.line:match('^%s*SCREEN %d+ w=fixed%(%d+%) user h=fixed%(%d+%) user '),
                'SCREEN must declare sizing before its solved box: ' .. entry.line)
            local solved = box(entry.line)
            utils.assert_geometry(solved, {x = geometry.x - g.x, y = geometry.y - g.y,
                width = geometry.width, height = geometry.height})
        end
        for _, c in ipairs(clients) do
            local s = c.screen
            assert(s.valid and c.parent == s.tree, 'client must belong to its surviving SCREEN')
            assert(c:isvisible() and not c.floating, 'client must remain visible and tiled')
            local geometry = c:geometry()
            local found
            for _, entry in ipairs(surfaces) do
                local b = entry.box
                if b.x == geometry.x - g.x and b.y == geometry.y - g.y
                    and b.width == geometry.width and b.height == geometry.height then
                    found = entry
                end
            end
            assert(found, 'client geometry must match its SURFACE')
            local frame
            for _, entry in ipairs(frames) do
                if entry.screen == s.index and entry.box.x == found.box.x
                    and entry.box.y == found.box.y then frame = entry.box end
            end
            utils.assert_geometry(assert(frame, 'SURFACE has no frame under its SCREEN'), found.box)
            assert(found.number > screen_lines[s.index].number, 'SURFACE must follow its SCREEN')
            assert(contains(box(screen_lines[s.index].line), found.box), 'SURFACE is outside its SCREEN')
            local r, green, b = capture.read(surface(s.content),
                math.floor(geometry.x - s.geometry.x + geometry.width / 2),
                math.floor(geometry.y - s.geometry.y + geometry.height / 2))
            assert(r == 0x33 and green == 0x66 and b == 0x99,
                string.format('client pixel on screen %d: %d,%d,%d', s.index, r, green, b))
        end
        return dump
    end

    local function settles(label)
        local failure, dump
        assert(async.wait_for_condition(function()
            local ok, result = pcall(check)
            if ok then dump = result else failure = result end
            return ok
        end, 3, .02), tostring(failure))
        io.stderr:write('[PASS] ', label, '\n', dump, '\n')
    end
    settles('clients on screens 2 and 3 have declared boxes and pixels')
    right:fake_remove()
    screens = {physical, middle}
    assert(not right.valid)
    settles('removed-screen client moved and draws on its surviving screen')
    for _, c in ipairs(clients) do c:kill() end
    assert(async.wait_for_no_clients(3))
    middle:fake_remove()
    physical:fake_resize(g.x, g.y, g.width, g.height)
    runner.done()
end)
