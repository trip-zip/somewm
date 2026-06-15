---------------------------------------------------------------------------
--- Test: the public layout.attach_to_root builder.
---
--- Two guarantees:
---   1. Byte-identity -- attach_to_root(node, opts) produces the same container
---      the fullscreen graft used to hand-roll (layout.row{ _attach_root=true,
---      ... }), so routing the graft through the builder cannot change the solve.
---   2. Lands where asked -- a root-attached child resolves at absolute
---      screen-solve coordinates, ignoring its parent's padding / flow (Clay
---      CLAY_ATTACH_TO_ROOT), unlike a normally-flowed sibling.
---
--- Pure layout solves (widget mode, no screen/apply), so this never touches the
--- live scene and cannot trip the tree==scene assertion.
---------------------------------------------------------------------------

local runner = require("_runner")
local layout = require("somewm.layout")

-- Widget mode stores the widget ref and returns it in placements; a distinct
-- token per leaf is enough to match results back to inputs (cf. test-clay-stack).
local function widget_token(label) return { _label = label } end

local function find_placement(placements, token)
    for _, p in ipairs(placements) do
        if p.widget == token then return p end
    end
    return nil
end

local function near(actual, expected, label)
    assert(math.abs(actual - expected) <= 1,
        string.format("%s: got %d, expected %d", label, actual, expected))
end

-- Two-way equality over primitive prop values. The child lives in `children`
-- (compared separately), so props carry no nested tables.
local function props_equal(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false, k end end
    for k, v in pairs(b) do if a[k] ~= v then return false, k end end
    return true
end

local steps = {
    -- 1. The builder reproduces the hand-rolled root-attached row exactly.
    function()
        local child = layout.widget(widget_token("c"), { width = 200, height = 150 })
        local built = layout.attach_to_root(child,
            { x = 50, y = 60, width = 200, height = 150 })
        local hand = layout.row {
            _attach_root = true,
            x = 50, y = 60, width = 200, height = 150, grow = false,
            child,
        }
        assert(built._type == "container", "builder must produce a container")
        local ok, badkey = props_equal(built.props, hand.props)
        assert(ok, "builder props diverge from the hand-rolled row at key: "
            .. tostring(badkey))
        assert(#built.children == 1 and built.children[1] == child,
            "builder must wrap exactly the given child")
        assert(built._slot == nil, "builder must not introduce a slot")
        assert(built.props.z == nil, "z must be omitted when no z is given")
        assert(built.props.direction == "row",
            "builder must stay a row (keeps the graft's auto-id stable)")
        io.stderr:write(
            "[TEST] PASS: attach_to_root builds the hand-rolled row byte-for-byte\n")
        return true
    end,

    -- 2. A root-attached child lands at absolute coords; a flowed sibling honors
    --    the parent padding. Same column, same solve: the only difference is the
    --    root attach.
    function()
        local flowed = widget_token("flowed")
        local rooted = widget_token("rooted")
        local result = layout.solve {
            width  = 1000,
            height = 800,
            source = "wibox",
            root = layout.column {
                padding = 100,
                layout.widget(flowed, { width = 200, height = 150 }),
                layout.attach_to_root(
                    layout.widget(rooted, { width = 200, height = 150 }),
                    { x = 50, y = 60, width = 200, height = 150 }),
            },
        }

        local pf = find_placement(result.placements, flowed)
        assert(pf, "flowed child placement missing")
        near(pf.x, 100, "flowed x honors the parent's 100px padding")
        near(pf.y, 100, "flowed y honors the parent's 100px padding")

        local pr = find_placement(result.placements, rooted)
        assert(pr, "root-attached child placement missing")
        near(pr.x, 50, "rooted x is absolute, ignores the parent padding")
        near(pr.y, 60, "rooted y is absolute, ignores the parent padding")
        near(pr.width, 200, "rooted width")
        near(pr.height, 150, "rooted height")
        io.stderr:write(
            "[TEST] PASS: attach_to_root lands at absolute coords, not parent flow\n")
        return true
    end,

    -- 3. Row-style args (positional node + props) wrap into the same kind of
    --    root-attached row WITHOUT mutating the caller's table.
    function()
        local child = layout.widget(widget_token("fb"), { width = 80, height = 40 })
        local spec = { child, x = 5, y = 6, width = 80, height = 40 }
        local node = layout.attach_to_root(spec)
        assert(node._type == "container" and node.props.direction == "row",
            "row-style form must produce a row container")
        assert(node.props._attach_root == true,
            "row-style form must set _attach_root")
        assert(node.children[1] == child,
            "row-style form must keep the positional child")
        assert(node.props.x == 5 and node.props.y == 6,
            "row-style form must carry the props")
        assert(spec._attach_root == nil,
            "row-style form must NOT mutate the caller's args table")
        io.stderr:write(
            "[TEST] PASS: attach_to_root row-style args wrap without mutating\n")
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
