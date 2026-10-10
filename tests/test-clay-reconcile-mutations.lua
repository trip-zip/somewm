---------------------------------------------------------------------------
-- Test: a frame mutates only the scene nodes its change reaches
--
-- Six textboxes in a row. The counts are read from the dump header's
-- `mutations`, which render_reconcile returns:
--   same-width markup on the third: 1, its buffer swap. Nothing moves.
--   wider markup on the third: 4, its buffer swap plus the three text
--     nodes after it moving right. A move alone writes no clip.
--   a background appears behind the second: 2, the new rect and one
--     restack placing it under the text. Every other node keeps its order.
--   that background goes: 1, the rect disabled. Its element is still in
--     the tree, so the node is kept for the colour's return, and a node
--     kept dark never reorders the rest.
---------------------------------------------------------------------------

local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')

local function header(s)
    local line = awesome._clay_tree(s):match('commands %d+ mutations %d+[^\n]*')
    return line, tonumber(line:match('mutations (%d+)'))
end

local function expect(s, what, want)
    awesome._test_redeclare()
    local line, got = header(s)
    assert(got == want, string.format('%s: mutations %s, expected %d', what, tostring(got), want))
    assert(awesome._test_redeclare() == 0, what .. ': the next frame mutated the scene')
    io.stderr:write(string.format('[PASS] %s: %s\n', what, line))
end

runner.run_async(function()
    local s = screen[1]
    local boxes = {}
    for i = 1, 6 do
        boxes[i] = wibox.widget { markup = '0000', font = 'Monospace 10',
            widget = wibox.widget.textbox }
    end
    local bg = wibox.container.background(boxes[2])
    local wb = wibox {
        x = 0, y = 0, width = 1280, height = 32, screen = s,
        bg = '#202020', visible = true,
        widget = wibox.widget {
            boxes[1], bg, boxes[3], boxes[4], boxes[5], boxes[6],
            layout = wibox.layout.fixed.horizontal,
        },
    }
    async.sleep(0.15)
    local settled = false
    for i = 1, 5 do
        if awesome._test_redeclare() == 0 then
            settled = true
            break
        end
        if i < 5 then async.sleep(0.05) end
    end
    assert(settled, 'the wibox did not settle')

    boxes[3].markup = '1111'
    expect(s, 'same-width markup', 1)
    boxes[3].markup = '11111111'
    expect(s, 'wider markup', 4)
    bg.bg = '#ff0000'
    expect(s, 'background appears', 2)
    bg.bg = nil
    expect(s, 'background goes', 1)

    wb.visible = false
    runner.done()
end)
