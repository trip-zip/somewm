---------------------------------------------------------------------------
-- Test: the output is a column of bars around the workarea
--
-- Bars on all four edges: the top and bottom span OUTPUT, the left and
-- right sit inside the middle row with WORKAREA between them. A bar's height
-- moves the workarea, read from the WORKAREA element's solved box. A wibar
-- that does not stretch keeps its width and aligns along its edge. The
-- three align expand modes give the three fit/grow patterns. An ontop wibar
-- floats over OUTPUT at band 60.
--
-- Run: make test-one TEST=tests/test-clay-output-bars.lua
---------------------------------------------------------------------------
local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bars = {}

local function lines()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

-- The record line for a bar at its dump indent, and its child lines.
local function block(bar, indent)
    local d = bar.drawin
    local want = string.format("%sWIBAR screen %d %dx%d+%d+%d ", indent,
        s.index, d.width, d.height, d.x, d.y)
    local head, nodes = nil, {}
    for _, line in ipairs(lines()) do
        if head then
            if not line:match("^    %x+ ") then break end
            nodes[#nodes + 1] = line
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, nodes
end

local function find(pattern, plain)
    for _, line in ipairs(lines()) do
        if line:find(pattern, 1, plain) then return line end
    end
    return nil
end

local function settled(bar)
    local d = bar.drawin
    return find(string.format("WIBAR screen %d %dx%d+%d+%d converted", s.index,
        d.width, d.height, d.x, d.y), true) ~= nil
end

local function text(t)
    return { widget = wibox.widget.textbox, text = t }
end

local steps = {
    -- Four edges.
    function(count)
        if count == 1 then
            for _, position in ipairs { "top", "bottom", "left", "right" } do
                local args = { position = position, screen = s }
                if position == "top" or position == "bottom" then
                    args.height = 20
                else
                    args.width = 30
                end
                local bar = awful.wibar(args)
                bar:setup(text(position))
                bars[position] = bar
            end
            return nil
        end
        for _, bar in pairs(bars) do
            if not settled(bar) then
                assert(count < 30, "a bar never settled:\n" .. awesome._clay_tree(s))
                return nil
            end
        end
        local top = block(bars.top, "    ")
        local bottom = block(bars.bottom, "    ")
        local middle = find("^    MIDDLE %- w=grow h=grow row")
        local left = block(bars.left, "      ")
        local right = block(bars.right, "      ")
        local workarea = find("^      WORKAREA %- w=grow h=grow row")
        assert(top and top:find(" w=grow h=fixed(20) theme row", 1, true), "top: " .. tostring(top))
        assert(bottom and bottom:find(" w=grow h=fixed(20) theme row", 1, true), "bottom: " .. tostring(bottom))
        assert(middle, "no middle row:\n" .. awesome._clay_tree(s))
        assert(left and left:find(" w=fixed(30) h=grow theme column", 1, true), "left: " .. tostring(left))
        assert(right and right:find(" w=fixed(30) h=grow theme column", 1, true), "right: " .. tostring(right))
        assert(workarea, "no workarea in the middle row:\n" .. awesome._clay_tree(s))
        local tg, bg, lg, rg = bars.top:geometry(), bars.bottom:geometry(),
            bars.left:geometry(), bars.right:geometry()
        assert(tg.width == geo.width and tg.y == geo.y, "top spans: " .. tg.width)
        assert(bg.width == geo.width and bg.y == geo.y + geo.height - 20, "bottom spans: " .. bg.y)
        assert(lg.x == geo.x and lg.y == geo.y + 20 and lg.height == geo.height - 40,
            string.format("left: %dx%d+%d+%d", lg.width, lg.height, lg.x, lg.y))
        assert(rg.x == geo.x + geo.width - 30 and rg.height == geo.height - 40,
            string.format("right: %dx%d+%d+%d", rg.width, rg.height, rg.x, rg.y))
        local wa = s.workarea
        assert(wa.x == geo.x + 30 and wa.y == geo.y + 20
            and wa.width == geo.width - 60 and wa.height == geo.height - 40,
            string.format("workarea %dx%d+%d+%d", wa.width, wa.height, wa.x, wa.y))
        io.stderr:write("[PASS] bars on four edges around the workarea\n")
        return true
    end,

    -- The bar height moves the workarea.
    function(count)
        if count == 1 then
            bars.top.height = 44
            return nil
        end
        local wa = s.workarea
        if wa.y ~= geo.y + 44 then
            assert(count < 30, "the workarea never moved: y=" .. wa.y)
            return nil
        end
        assert(wa.height == geo.height - 64, "workarea height " .. wa.height)
        assert(bars.left:geometry().y == geo.y + 44, "the left bar did not reflow")
        assert(find("^    WIBAR screen %d+ %d+x44%+%d+%+%d+ .* w=grow h=fixed%(44%) theme row"),
            "the top bar is not 44 high in the dump")
        io.stderr:write("[PASS] a bar height change reflows the workarea\n")
        return true
    end,

    -- A bar that does not stretch keeps its width, aligned along the edge.
    function(count)
        if count == 1 then
            for _, bar in pairs(bars) do bar.visible = false end
            bars = {}
            bars.narrow = awful.wibar { position = "top", screen = s, height = 20,
                width = 300, align = "right" }
            bars.narrow:setup(text("narrow"))
            return nil
        end
        if not settled(bars.narrow) then
            assert(count < 30, "the narrow bar never settled")
            return nil
        end
        local g = bars.narrow:geometry()
        assert(g.width == 300 and g.x == geo.x + geo.width - 300,
            string.format("narrow bar at %dx%d+%d+%d", g.width, g.height, g.x, g.y))
        local _, nodes = block(bars.narrow, "    ")
        assert(nodes[1] and nodes[1]:find(" drawable clip w=fixed(300) h=grow", 1, true),
            "the root is not told its width: " .. tostring(nodes[1]))
        assert(s.workarea.y == geo.y + 20, "the narrow bar reserves its height")
        io.stderr:write("[PASS] a bar that does not stretch keeps its width\n")
        return true
    end,

    -- Margins are the slot's padding.
    function(count)
        if count == 1 then
            bars.narrow.visible = false
            bars.margins = awful.wibar { position = "top", screen = s, height = 20,
                margins = { left = 4, right = 6, top = 8, bottom = 2 } }
            bars.margins:setup(text("margins"))
            return nil
        end
        if not settled(bars.margins) then
            assert(count < 30, "the margins bar never settled")
            return nil
        end
        local head = block(bars.margins, "    ")
        assert(head:find(" w=grow h=fixed(30) theme row pad 4,6,8,2", 1, true),
            "the slot is not padded by the margins: " .. head)
        local g = bars.margins:geometry()
        assert(g.x == geo.x + 4 and g.y == geo.y + 8 and g.width == geo.width - 10
            and g.height == 20,
            string.format("margins bar at %dx%d+%d+%d", g.width, g.height, g.x, g.y))
        assert(s.workarea.y == geo.y + 30, "the workarea starts at " .. s.workarea.y)
        io.stderr:write("[PASS] margins are padding\n")
        return true
    end,

    -- The three align expand modes.
    function(count)
        if count == 1 then
            bars.margins.visible = false
            for _, mode in ipairs { "inside", "outside", "none" } do
                local bar = awful.wibar { position = "top", screen = s, height = 20 }
                bar:setup({
                    layout = wibox.layout.align.horizontal,
                    expand = mode,
                    text("a"), text("b"), text("c"),
                })
                bars[mode] = bar
            end
            return nil
        end
        for _, mode in ipairs { "inside", "outside", "none" } do
            if not settled(bars[mode]) then
                assert(count < 30, "the " .. mode .. " bar never settled")
                return nil
            end
        end
        local want = {
            inside = { "w=fit h=grow", "w=grow h=grow", "w=fit h=grow" },
            outside = { "w=grow h=grow", "w=fit h=grow", "w=grow h=grow" },
            none = { "w=grow h=grow", "w=fit h=grow", "w=grow h=grow" },
        }
        for mode, sizes in pairs(want) do
            local _, nodes = block(bars[mode], "    ")
            local got = {}
            for _, line in ipairs(nodes) do
                -- The align's own children sit two levels under the root:
                -- the separator space, then two per level from depth 2.
                if #line:match("^    %x+( *)") == 9 then
                    got[#got + 1] = line:match(" (w=%S+ h=%S+)")
                end
            end
            for i = 1, 3 do
                assert(got[i] == sizes[i], string.format(
                    "%s child %d is %s, want %s\n%s", mode, i, tostring(got[i]),
                    sizes[i], table.concat(nodes, "\n")))
            end
        end
        io.stderr:write("[PASS] the three align expand modes\n")
        return true
    end,

    -- An ontop wibar floats over OUTPUT at band 60 and reserves nothing.
    function(count)
        if count == 1 then
            for _, bar in pairs(bars) do bar.visible = false end
            bars = {}
            bars.ontop = awful.wibar { position = "bottom", screen = s, height = 20,
                ontop = true }
            bars.ontop:setup(text("ontop"))
            return nil
        end
        if not settled(bars.ontop) then
            assert(count < 30, "the ontop bar never settled")
            return nil
        end
        local head = block(bars.ontop, "    ")
        assert(head:find(" w=grow h=fixed(20) theme row attach PARENT offset 0,0 band 60", 1, true),
            "the ontop bar does not float at band 60: " .. head)
        local g = bars.ontop:geometry()
        assert(g.y == geo.y + geo.height - 20 and g.width == geo.width,
            string.format("ontop bar at %dx%d+%d+%d", g.width, g.height, g.x, g.y))
        assert(s.workarea.height == geo.height, "the ontop bar reserved space")
        io.stderr:write("[PASS] an ontop wibar is a float at band 60\n")
        return true
    end,

    function()
        for _, bar in pairs(bars) do bar.visible = false end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
