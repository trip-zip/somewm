---------------------------------------------------------------------------
-- Unit tests for the Clay widget-anchor selection (awful.placement.next_to_attach
-- and the pure next_to_select extracted from next_to). These cover the fit/flip
-- policy that stays in Lua and the (position, anchor) -> Clay attachPoints map.
-- The numeric "does Clay place it there" check lives in the integration test
-- tests/test-clay-popup-attach.lua (it needs a real Clay solve).
---------------------------------------------------------------------------

-- Stub awful.screen before requiring placement (it indexes capi.screen at load,
-- which is absent under busted). Same hack as placement_spec.lua.
package.loaded["awful.screen"] = {}

local place = require("awful.placement")

-- A bounding rect large enough that the first preferred side always fits.
local BIG = { x = 0, y = 0, width = 2000, height = 2000 }

describe("awful.placement.next_to_attach", function()
    local anchor = { x = 500, y = 500, width = 80, height = 20 }
    local size   = { width = 100, height = 40 }

    it("places below-front and returns the documented attachPoints", function()
        local pos, anchor_name, ap = place.next_to_attach(anchor, size, {
            preferred_positions = "bottom",
            preferred_anchors   = "front",
            bounding_rect       = BIG,
        })
        assert.are.equal("bottom", pos)
        assert.are.equal("front", anchor_name)
        assert.are.same({ parent = "left_bottom", element = "left_top" }, ap)
    end)

    -- The full (position, anchor) -> attachPoints map, asserted end to end so a
    -- wrong pair (the region-shift vs raw-box risk) is caught here.
    local expected = {
        bottom = {
            front  = { parent = "left_bottom"  , element = "left_top"      },
            back   = { parent = "right_bottom" , element = "right_top"     },
            middle = { parent = "center_bottom", element = "center_top"    },
        },
        top = {
            front  = { parent = "left_top"     , element = "left_bottom"   },
            back   = { parent = "right_top"    , element = "right_bottom"  },
            middle = { parent = "center_top"   , element = "center_bottom" },
        },
        left = {
            front  = { parent = "left_top"     , element = "right_top"     },
            back   = { parent = "left_bottom"  , element = "right_bottom"  },
            middle = { parent = "left_center"  , element = "right_center"  },
        },
        right = {
            front  = { parent = "right_top"    , element = "left_top"      },
            back   = { parent = "right_bottom" , element = "left_bottom"   },
            middle = { parent = "right_center" , element = "left_center"   },
        },
    }

    for position, anchors in pairs(expected) do
        for anchor_name, ap in pairs(anchors) do
            it("maps "..position.."/"..anchor_name.." to its attachPoints", function()
                local p, a, got = place.next_to_attach(anchor, size, {
                    preferred_positions = position,
                    preferred_anchors   = anchor_name,
                    bounding_rect       = BIG,
                })
                assert.are.equal(position, p)
                assert.are.equal(anchor_name, a)
                assert.are.same(ap, got)
            end)
        end
    end

    it("flips to the next preferred position when the first does not fit", function()
        -- Anchor pinned to the bottom edge: a "bottom" popup would overflow, so
        -- the selection must flip to "top".
        local edge = { x = 100, y = 1980, width = 80, height = 20 }
        local pos, _, ap = place.next_to_attach(edge, { width = 200, height = 50 }, {
            preferred_positions = { "bottom", "top" },
            preferred_anchors   = "front",
            bounding_rect       = BIG,
        })
        assert.are.equal("top", pos)
        assert.are.same({ parent = "left_top", element = "left_bottom" }, ap)
    end)

    it("returns nil when the target fits on no side", function()
        -- Bounding barely larger than the anchor: a 400px popup fits nowhere.
        local tight = { x = 0, y = 0, width = 120, height = 60 }
        local pos = place.next_to_attach(
            { x = 40, y = 20, width = 40, height = 20 },
            { width = 400, height = 400 },
            { preferred_positions = { "bottom", "top", "left", "right" },
              preferred_anchors   = "front",
              bounding_rect       = tight }
        )
        assert.is_nil(pos)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
