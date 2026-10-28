-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-base-widget.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local wibox = require("wibox")
local base = wibox.widget.base
local s = screen[1]
local geo = s.geometry
local bar, empty

local function log_contents()
    io.stderr:flush()
    local file = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG")), "r"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function nodes()
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, out = nil, {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if head then
            if not line:match("^    %x+ ") then break end
            out[#out + 1] = line
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    assert(head and head:find("converted:", 1, true), "the bar has no converted tree")
    return table.concat(out, "\n")
end

local function box(line)
    assert(line, "the dump has no matching node")
    local x, y, width, height = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    assert(x, "the node has no box: " .. line)
    return tonumber(x), tonumber(y), tonumber(width), tonumber(height)
end

runner.run_steps {
    function(count)
        if count == 1 then
            empty = base.make_widget()
            bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 120, height = 20,
                screen = s, visible = true, bg = "#000000", widget = {
                    { empty, forced_height = 2, bg = "#ff0000",
                        widget = wibox.container.background },
                    layout = wibox.layout.fixed.vertical,
                } }
            return nil
        end
        local dump = nodes()
        local present = false
        -- An empty child can share its background's element and still retain its binding.
        for _, hit in ipairs(bar:find_widgets(1, 1)) do
            if hit.widget == empty then present = true end
        end
        io.stderr:write("empty background child present: " .. tostring(present) .. "\n" .. dump .. "\n")
        assert(not log_contents():find("has no describer", 1, true),
            "compositor log contains 'has no describer'")
        assert(present, "the background's empty child has no element binding")
        local x, y, width, height = box(dump:match("[^\n]*wibox.container.background[^\n]*"))
        assert(x + geo.x == bar.x and y + geo.y == bar.y and width == 120 and height == 2,
            "the red background is not 120x2: " .. dump)
        local r, g, b = capture.read(gsurface(root.content()), bar.x + 60, bar.y + 1)
        assert(r >= 243 and g <= 12 and b <= 12, "the background has no red pixels")
        io.stderr:write("[PASS] a bare widget retains the red 2px background without warnings\n")
        return true
    end,
    function(count)
        if count == 1 then
            empty = base.make_widget(nil, "bare-flex-child")
            bar.widget = wibox.layout.flex.horizontal(
                wibox.widget { forced_width = 40, forced_height = 10,
                    bg = "#ff0000", widget = wibox.container.background },
                empty, wibox.widget.imagebox())
            return nil
        end
        local dump = nodes()
        local bare = dump:match("[^\n]*bare%-flex%-child[^\n]*")
        local image = dump:match("[^\n]*wibox.widget.imagebox[^\n]*")
        assert((bare == nil) == (image == nil), "empty widgets differ in presence: " .. dump)
        if bare then
            local _, _, bw, bh = box(bare)
            local _, _, iw, ih = box(image)
            assert(bw == iw and bh == ih, "empty widgets have different box sizes: " .. dump)
        end
        assert(not log_contents():find("has no describer", 1, true),
            "compositor log contains 'has no describer'")
        io.stderr:write("[PASS] bare and imageless widgets agree in the flex dump\n" .. dump .. "\n")
        return true
    end,
    function(count)
        if count == 1 then
            local painter = base.make_widget(nil, "bare-painter")
            painter.draw = function() end
            bar.widget = painter
            return nil
        end
        assert(not nodes():find("bare-painter", 1, true), "the painter was declared")
        assert(log_contents():find("bare-painter defines :draw at", 1, true),
            "the self-drawing refusal warning is missing")
        io.stderr:write("[PASS] a base widget with :draw is still refused\n")
        return true
    end,
    function(count)
        if count == 1 then
            local child = wibox.widget { forced_width = 40, forced_height = 10,
                bg = "#ff0000", widget = wibox.container.background }
            bar.widget = wibox.layout.fixed.horizontal(
                wibox.container.place(wibox.container.rotate(child, "east")),
                wibox.container.place(wibox.container.mirror(child, { horizontal = true })))
            return nil
        end
        local dump, log = nodes(), log_contents()
        local turned = dump:match("[^\n]*wibox.container.background transform 90 [^\n]*")
        local mirrored = dump:match("[^\n]*wibox.container.background transform flipped [^\n]*")
        assert(turned and select(3, box(turned)) == 10 and select(4, box(turned)) == 40,
            "the rotated background is not 10x40: " .. dump)
        assert(mirrored and select(3, box(mirrored)) == 40 and select(4, box(mirrored)) == 10,
            "the mirrored background is not 40x10: " .. dump)
        assert(not log:find("needs a rotation", 1, true) and not log:find("needs a reflection", 1, true),
            "the log still refuses a rotation or reflection")
        io.stderr:write("[PASS] rotation and reflection convert\n" .. turned .. "\n" .. mirrored .. "\n")
        return true
    end,
    function()
        bar.visible = false
        return true
    end,
}
