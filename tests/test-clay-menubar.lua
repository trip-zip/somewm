-- The menubar lists its items as FIT children of a horizontal overflow; selection scrolls it.
local runner = require('_runner')
local async = require('_async')
local menubar = require('menubar')
local example = require('_clay_example')

local entries = {}
for i = 1, 40 do
    entries[i] = { name = string.format('ITEM%02d', i), cmdline = 'true' }
end

local function box(line)
    local x, w = line:match(' box (%-?%d+),%-?%d+ (%d+)x%d+')
    return tonumber(x), tonumber(w)
end

-- The dump, the menubar's block of it, its items in order and the viewport line.
local function state()
    local dump = awesome._clay_tree(screen[1])
    local lines = dump:match('\n(  LAUNCHER .-)\n  %S')
    local viewport = lines and lines:match('[^\n]* scroll=x scrolled=[^\n]*')
    if not viewport then return end
    local items = {}
    for name, x, w in lines:gmatch('text "([^"]*)" font=%d+ box (%-?%d+),%-?%d+ (%d+)x%d+') do
        if name:find('^ITEM') or name:find('^Exec') then
            items[#items+1] = { name = name, x = tonumber(x), w = tonumber(w) }
        end
    end
    return dump, lines, items, viewport
end

local function key(name)
    _keygrabber.inject(name, true); _keygrabber.inject(name, false)
    async.sleep(.05)
end

-- The menubar settles within a few frames; every check waits for its dump.
local function until_dump(check, message)
    assert(async.wait_for_condition(function()
        local dump, lines, items, viewport = state()
        return dump and check(dump, lines, items, viewport)
    end, 1, .01), message)
    return state()
end

local function inside(item, viewport)
    local vx, vw = box(viewport)
    return item.x >= vx and item.x + item.w <= vx + vw
end

runner.run_async(function()
    menubar.show_categories = false
    menubar.menu_gen.generate = function(callback) callback(entries) end
    menubar.geometry = { width = 600 }
    menubar.show(screen[1])

    local dump, lines, items, viewport = until_dump(function(_, l)
        return l:find('"▶▶"', 1, true) end, 'the right label never showed')
    assert(#items == 41 and items[41].name == 'Exec: ', 'every item is declared: ' .. #items)
    assert(viewport:find('scrolled=0 ', 1, true) and not lines:find('"◀◀"', 1, true))
    local _, fit = lines:gsub('background_role w=fit h=grow ', '')
    assert(fit == 41, 'items are FIT: ' .. fit)
    assert(not lines:find('derived', 1, true) and not lines:find('w=fit>=', 1, true))
    example.save('menubar-start', dump)

    local selected = 1
    repeat
        key('Right')
        selected = selected + 1
        dump, lines, items, viewport = until_dump(function(_, _, i, v)
            return inside(i[selected], v) end, 'the selected item lies outside the viewport: ' .. selected)
    until not viewport:find('scrolled=0 ', 1, true)
    assert(selected > 2, 'the first items fit without scrolling')
    dump = until_dump(function(_, l) return l:find('"◀◀"', 1, true) end, 'no left label after scrolling')
    example.save('menubar-scrolled', dump)

    -- A query that still lists the selected item keeps it selected and in view.
    local name = items[selected].name
    key('i')
    dump = until_dump(function(_, l, i, v)
        return l:find('"Exec: i"', 1, true) and i[selected].name == name and inside(i[selected], v)
    end, 'the query lost or hid the selected item ' .. name)
    example.save('menubar-query', dump)

    key('End')
    dump = until_dump(function(_, l, i, v)
        return inside(i[#i], v) and not l:find('"▶▶"', 1, true) and l:find('"◀◀"', 1, true)
    end, 'the end shows the last item and only the left label')
    example.save('menubar-end', dump)

    key('Home')
    until_dump(function(_, l, _, v)
        return v:find('scrolled=0 ', 1, true) and l:find('"▶▶"', 1, true) and not l:find('"◀◀"', 1, true)
    end, 'Home returns to the start')
    key('Escape')
    runner.done()
end)
