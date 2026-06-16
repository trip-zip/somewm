---------------------------------------------------------------------------
--- Test: grid / rotate / mirror (and custom containers) are opaque leaves.
--
-- Widgets phase (#47 + the Prime-Directive guard). A container whose interior is
-- not a box layout (grid's 2D cell spanning, rotate / mirror's matrix transform)
-- resolves as a single leaf node in the screen solve via its `:layout_node`; its
-- interior is solved separately by `base.layout_widget` when drawn. A custom
-- container (no `:layout_node`) degrades to the same leaf, proving the per-widget
-- solver survives.
--
-- Each container is nested under an expressible `fixed` parent. The parent is
-- retained from the screen solve (its placement list exists), the container shows
-- up there as ONE node, and the container's interior child is absent from the
-- solve (it is a leaf) yet still renders (hit-testable).
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local base = require("wibox.widget.base")

local clay = require("awful.layout.clay")

local s = screen.primary
local tag = s.tags[1]
local bar
local tested = {}

-- A minimal custom container: a :layout that fills its child, NO :layout_node, so
-- widget_to_node degrades it to a leaf and base.layout_widget solves its interior.
local function make_custom_container(child)
    local w = base.make_widget()
    w._child = child
    function w:layout(_, width, height)
        return { base.place_widget_at(self._child, 0, 0, width, height) }
    end
    function w:fit(_, width, height)
        return width, height
    end
    return w
end

-- Scan the wibar surface for a hit on `target` (robust to transforms).
local function hit_anywhere(drawable, target, w, h)
    for x = 0, w, 4 do
        for y = 0, h, 2 do
            for _, e in ipairs(drawable:find_widgets(x, y)) do
                if e.widget == target then return true end
            end
        end
    end
    return false
end

-- Build a step that wraps `build(child)` in fixed.horizontal, mounts it, and
-- asserts the leaf contract.
local function leaf_step(name, build)
    local child, parent, phase = nil, nil, 0
    return function(count)
        if phase == 0 then
            child = wibox.widget.textbox("Xy")
            parent = wibox.layout.fixed.horizontal(build(child))
            bar.widget = parent
            awful.layout.arrange(s)
            phase = 1
            return nil
        end
        -- Wait for the hierarchy (draw) and the screen solve to retain the parent.
        local ok = bar._drawable and bar._drawable._widget_hierarchy
            and s._clay_widget_placements and s._clay_widget_placements[parent]
        if not ok then
            if count >= 40 then error(name .. ": parent never retained from the screen solve") end
            return nil
        end
        -- The expressible parent is retained and lists exactly one node (the leaf
        -- container), proving the container collapsed to a single node.
        local pls = s._clay_widget_placements[parent]
        assert(#pls == 1,
            string.format("%s: expressible parent should list one leaf node, got %d", name, #pls))
        -- The container's interior child is NOT in the screen solve: it is a leaf.
        assert(s._clay_widget_placements[child] == nil,
            name .. ": leaf container interior must NOT be in the screen solve")
        -- ...yet the interior still renders, solved by base.layout_widget.
        local g = bar:geometry()
        assert(hit_anywhere(bar._drawable, child, g.width, g.height),
            name .. ": leaf container child should render (interior solved by base.layout_widget)")
        io.stderr:write("[TEST] PASS: " .. name .. " is a single leaf with a rendered interior\n")
        tested[name] = true
        return true
    end
end

local steps = {
    function()
        tag:view_only()
        tag.layout = clay.tile
        tag.gap = 0
        bar = awful.wibar { position = "top", screen = s, height = 40,
            widget = wibox.widget.textbox("init") }
        return true
    end,

    leaf_step("grid", function(child)
        local g = wibox.layout.grid()
        g:add_widget_at(child, 1, 1, 1, 1)
        return g
    end),

    leaf_step("rotate", function(child)
        return wibox.container.rotate(child, "west")
    end),

    leaf_step("mirror", function(child)
        return wibox.container.mirror(child, { horizontal = true })
    end),

    leaf_step("custom-container", function(child)
        return make_custom_container(child)
    end),

    -- Prove every container was actually exercised (no vacuous pass).
    function()
        for _, name in ipairs({ "grid", "rotate", "mirror", "custom-container" }) do
            assert(tested[name], "leaf contract was not exercised for " .. name)
        end
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
