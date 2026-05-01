---------------------------------------------------------------------------
--- Test: awful.layout.suit.* identity-aliased to awful.layout.clay.*
--
-- Verifies that the soft-alias from suit.* to clay.* preserves table
-- identity (so user code comparing tag.layout == awful.layout.suit.tile
-- still matches) and that the public API surface (mouse_resize_handler,
-- resize_jump_to_corner, sub-variants) survives the alias.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local clay = require("awful.layout.clay")
local suit = require("awful.layout.suit")

local steps = {
    function()
        assert(suit.tile     == clay.tile,     "suit.tile identity")
        assert(suit.fair     == clay.fair,     "suit.fair identity")
        assert(suit.max      == clay.max,      "suit.max identity")
        assert(suit.corner   == clay.corner,   "suit.corner identity")
        assert(suit.spiral   == clay.spiral,   "suit.spiral identity")
        assert(suit.floating == clay.floating, "suit.floating identity")

        assert(suit.tile.left   == clay.tile.left,   "suit.tile.left identity")
        assert(suit.tile.right  == clay.tile,        "suit.tile.right == suit.tile")
        assert(suit.tile.bottom == clay.tile.bottom, "suit.tile.bottom identity")
        assert(suit.tile.top    == clay.tile.top,    "suit.tile.top identity")

        assert(suit.fair.horizontal   == clay.fair.horizontal,   "suit.fair.horizontal identity")
        assert(suit.spiral.dwindle    == clay.spiral.dwindle,    "suit.spiral.dwindle identity")

        assert(type(suit.tile.mouse_resize_handler)        == "function", "tile.mouse_resize_handler exists")
        assert(type(suit.tile.left.mouse_resize_handler)   == "function", "tile.left.mouse_resize_handler exists")
        assert(type(suit.tile.bottom.mouse_resize_handler) == "function", "tile.bottom.mouse_resize_handler exists")
        assert(type(suit.tile.top.mouse_resize_handler)    == "function", "tile.top.mouse_resize_handler exists")
        assert(type(suit.floating.mouse_resize_handler)    == "function", "floating.mouse_resize_handler exists")

        assert(suit.tile.resize_jump_to_corner == true, "tile.resize_jump_to_corner")
        assert(suit.floating.resize_jump_to_corner == true, "floating.resize_jump_to_corner")

        assert(type(suit.max.fullscreen) == "table", "max.fullscreen variant exists")
        assert(type(suit.tile.skip_gap) == "function", "tile.skip_gap exists")
        assert(type(suit.corner.nw) == "table", "corner.nw exists")
        assert(type(suit.corner.ne) == "table", "corner.ne exists")
        assert(type(suit.corner.sw) == "table", "corner.sw exists")
        assert(type(suit.corner.se) == "table", "corner.se exists")

        return true
    end,

    function()
        local custom = {
            name = "custom_legacy",
            arrange = function(p)
                if not p.clients[1] then return end
                p.geometries[p.clients[1]] = {
                    x = p.workarea.x,
                    y = p.workarea.y,
                    width  = math.floor(p.workarea.width / 2),
                    height = p.workarea.height,
                }
            end,
        }
        local tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = custom
        return true
    end,
}

runner.run_steps(steps)
