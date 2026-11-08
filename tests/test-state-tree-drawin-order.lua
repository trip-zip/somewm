local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local fixture = require('_state_tree_drawin_order')
local utils = require('_utils')
local binary = utils.binary_or_skip('./build-test/test-transient-client')
if not binary then return end

runner.run_async(function()
    local s = screen[1]
    mouse.coords {x = s.geometry.x + 900, y = s.geometry.y + 600}
    local pair = fixture.create(s)
    assert(async.wait_for_condition(function() return fixture.matches(pair, false) end, 3),
        'later sibling must draw blue over red and appear later in the dump')
    local before = fixture.lines(pair)
    fixture.raise_first(pair)
    assert(async.wait_for_condition(function() return fixture.matches(pair, true) end, 3),
        'moving red after blue must flip the overlap pixel and WIBOX order')
    local after = fixture.lines(pair)
    assert(before[1] == after[2] and before[2] == after[1], 'only WIBOX line order changed')

    s.selected_tag.layout = awful.layout.suit.tile
    awful.spawn {binary, 'drawin_order_tile'}
    local c = assert(async.wait_for_client('drawin_order_tile', 3))
    c.floating, c.animation, c.shadow = false, false, false
    assert(async.wait_for_condition(function()
        local dump = awesome._clay_tree(s)
        local workarea = dump:match('\n( +)WORKAREA ')
        local frame = dump:match('\n( +)CLIENT drawin_order_tile ')
        local slot = dump:match('\n( +)SLOT drawin_order_tile ')
        local attached = dump:match('\n  SURFACE drawin_order_tile [^\n]*attach PARENT ')
        return workarea and frame and slot and #frame > #workarea and #slot > #frame and attached
    end, 3), 'tiled frame and SLOT remain under WORKAREA with SURFACE attached to its parent')
    pair.a.visible, pair.b.visible = false, false
    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 3))
    runner.done()
end)
