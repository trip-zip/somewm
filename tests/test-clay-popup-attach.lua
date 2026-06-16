---------------------------------------------------------------------------
--- Test: the Clay attach-to-element binding (attach_to_element_id + attach_points).
---
--- A floating element with `attach_to_element_id = <ref>` attaches to the element
--- opened with `clay_ref = <ref>` (CLAY_ATTACH_TO_ELEMENT_WITH_ID, parentId = hash
--- of the same string) and is positioned by its `attach_points` relative to that
--- element's box. Two guarantees:
---   1. Id-equality -- the float follows the *named* anchor (one of two), proving
---      the parentId hash resolves to that anchor's stable id, not the other.
---   2. attach_points -- each {parent, element} pair lands the float at the
---      arithmetic Clay documents (parent corner minus element corner).
---
--- Pure layout solves (widget mode, no screen / apply), so this never touches the
--- live scene and cannot trip the tree==scene assertion. Runs headless.
---------------------------------------------------------------------------

local runner = require("_runner")
local layout = require("somewm.layout")

local function tok(label) return { _label = label } end

local function find(placements, token)
    for _, p in ipairs(placements) do
        if p.widget == token then return p end
    end
    return nil
end

local function near(actual, expected, label)
    assert(math.abs(actual - expected) <= 1,
        string.format("%s: got %s, expected %s", label, tostring(actual), tostring(expected)))
end

-- An anchor element at an absolute box, carrying a stable clay_ref. Built as a
-- root-attached widget leaf so its box is both known and returned to Lua.
local function anchor_node(token, x, y, w, h, ref)
    return layout.attach_to_root(
        layout.widget(token, { width = w, height = h, clay_ref = ref }),
        { x = x, y = y, width = w, height = h })
end

-- A floating popup widget attached to a named anchor by attach points.
local function popup_node(token, w, h, anchor_ref, parent_ap, element_ap)
    return { _type = "widget", widget = token, props = {
        width                = w,
        height               = h,
        attach_to_element_id = anchor_ref,
        attach_points        = { parent = parent_ap, element = element_ap },
    } }
end

local steps = {
    -- 1. Id-equality: a popup naming "anchorB" lands on B's box, not A's.
    function()
        local aA, aB, pop = tok("aA"), tok("aB"), tok("pop")
        local res = layout.solve {
            width = 1000, height = 800, source = "wibox",
            read_anchor_refs = true,
            root = layout.column {
                grow = true,
                anchor_node(aA, 100, 100, 80, 20, "anchorA"),
                anchor_node(aB, 500, 400, 80, 20, "anchorB"),
                popup_node(pop, 200, 50, "anchorB", "left_bottom", "left_top"),
            },
        }

        local pa, pb, pp = find(res.placements, aA), find(res.placements, aB),
                           find(res.placements, pop)
        assert(pa and pb and pp, "all three elements must resolve")
        near(pa.x, 100, "anchorA x"); near(pa.y, 100, "anchorA y")
        near(pb.x, 500, "anchorB x"); near(pb.y, 400, "anchorB y")

        -- left_bottom(of B) -> left_top(of popup): popup top-left at B bottom-left.
        near(pp.x, 500, "popup x = anchorB left edge")
        near(pp.y, 420, "popup y = anchorB bottom edge (400 + 20)")
        near(pp.width, 200, "popup width"); near(pp.height, 50, "popup height")
        io.stderr:write(
            "[TEST] PASS: popup attaches to the named anchor (parentId hash matches)\n")
        return true
    end,

    -- 2. attach_points pairs land at the documented Clay arithmetic.
    function()
        local a, p1, p2, p3 = tok("a"), tok("p1"), tok("p2"), tok("p3")
        local res = layout.solve {
            width = 1000, height = 800, source = "wibox",
            read_anchor_refs = true,
            root = layout.column {
                grow = true,
                anchor_node(a, 300, 300, 100, 40, "anchor"),
                -- below, centered: parent center_bottom -> element center_top
                popup_node(p1, 60, 20, "anchor", "center_bottom", "center_top"),
                -- right, top-aligned: parent right_top -> element left_top
                popup_node(p2, 60, 20, "anchor", "right_top", "left_top"),
                -- above, right-aligned: parent right_top -> element right_bottom
                popup_node(p3, 60, 20, "anchor", "right_top", "right_bottom"),
            },
        }

        -- anchor box (300, 300, 100, 40): center x = 350, bottom y = 340, right x = 400.
        local g1, g2, g3 = find(res.placements, p1), find(res.placements, p2),
                           find(res.placements, p3)
        assert(g1 and g2 and g3, "all popups must resolve")

        near(g1.x, 350 - 30, "p1 center_top at anchor center_bottom (centered)")
        near(g1.y, 340,      "p1 top at anchor bottom")
        near(g2.x, 400,      "p2 left at anchor right")
        near(g2.y, 300,      "p2 top at anchor top")
        near(g3.x, 400 - 60, "p3 right at anchor right")
        near(g3.y, 300 - 20, "p3 bottom at anchor top")
        io.stderr:write(
            "[TEST] PASS: attach_points pairs land at the documented positions\n")
        return true
    end,

    function()
        io.stderr:write("Test finished successfully.\n")
        awesome.quit()
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
