local awful = require("awful")
local runner = require("_runner")

local physical = screen.primary
local g = physical.geometry
local third = math.floor(g.width / 3)
local left, right
local physical_bar, left_bar, right_bar

local steps = {
    function()
        assert(third > 0, "physical output is too narrow to split")
        physical:fake_resize(g.x, g.y, third, g.height)
        left = screen.fake_add(g.x + third, g.y, third, g.height)
        right = screen.fake_add(g.x + 2 * third, g.y, g.width - 2 * third, g.height)
        physical_bar = awful.wibar { position = "top", screen = physical, height = 24 }
        left_bar = awful.wibar { position = "top", screen = left, height = 24 }
        right_bar = awful.wibar { position = "top", screen = right, height = 40 }
        return true
    end,

    function(count)
        local ok, err = pcall(function()
            assert(left.workarea.x == left.geometry.x and left.workarea.y == left.geometry.y + 24
                and left.workarea.width == left.geometry.width and left.workarea.height == left.geometry.height - 24)
            assert(right.workarea.x == right.geometry.x and right.workarea.y == right.geometry.y + 40
                and right.workarea.width == right.geometry.width and right.workarea.height == right.geometry.height - 40)
            assert(physical.workarea.y == g.y + 24 and physical.workarea.width == third)
            local tree = awesome._clay_tree(physical)
            for _, s in ipairs { physical, left, right } do
                local gg = s.geometry
                assert(tree:find(string.format("SCREEN %d w=fixed(%d) h=fixed(%d)", s.index, gg.width, gg.height), 1, true))
            end
            assert(select(2, tree:gsub("\n%s*SCREEN %d+ ", "")) == 3)
            assert(select(2, tree:gsub("\n%s*WORKAREA ", "")) == 3)
        end)
        if not ok and count < 20 then return nil end
        assert(ok, err)
        return true
    end,

    function()
        right:fake_remove()
        left:fake_remove()
        physical:fake_resize(g.x, g.y, g.width, g.height)
        return true
    end,

    function(count)
        local tree = awesome._clay_tree(physical)
        local restored = tree and not tree:match("\n%s*SCREEN %d+ ")
            and physical.workarea.y == g.y + 24
        if not restored and count < 20 then return nil end
        assert(tree and not tree:match("\n%s*SCREEN %d+ "),
            "restored physical output still has a SCREEN subtree")
        assert(physical.workarea.y == g.y + 24,
            "restored physical workarea does not reserve its top wibar")
        right_bar.visible = false
        left_bar.visible = false
        physical_bar.visible = false
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
