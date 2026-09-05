---------------------------------------------------------------------------
--- Compile a drawable's widget tree into Clay declarations.
--
-- The declare pass (declare.c) draws a drawin from the tree this module
-- returns: one Clay element per widget the compile step can express, and one
-- raster leaf per subtree it cannot, drawn by cairo into the leaf's own
-- surface (widget.c) and shown at the box Clay solves for it. When nothing
-- converts the drawable paints itself whole, as it always did.
--
-- The walk descends the widget tree itself, not a laid-out hierarchy: Clay
-- is the only solver of a converted tree, and no box is computed here. A
-- node is pure description, and its sizing is Clay's own, one of the three
-- types clay.h names: `fit` wraps the content, which is Clay's default
-- (CLAY_SIZING_FIT), `grow` fills the parent (CLAY_SIZING_GROW), and a
-- number is told (CLAY_SIZING_FIXED). A container says which of the first
-- two each child gets, in place of the `:fit` question the layout engine
-- asked; a widget's own preference (a forced size, a place that fills)
-- refines fit and never overrides grow, since fit is the content size and
-- that preference is the content.
--
-- A raster leaf is the one node the walk sizes. Clay measures nothing but
-- text (Clay_SetMeasureTextFunction), and an image element is a bare
-- pointer (Clay_ImageElementConfig), so a leaf is declared as Clay's own
-- image examples declare one: sized by its caller. The size is the leaf
-- widget's `:fit` at the drawin's bound, and an axis on which the widget
-- takes all it is offered grows instead, which is what that answer means.
--
-- @module wibox.clay
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local margin_class = require("wibox.container.margin")
local background_class = require("wibox.container.background")
local place_class = require("wibox.container.place")
local fixed_class = require("wibox.layout.fixed")
local flex_class = require("wibox.layout.flex")
local align_class = require("wibox.layout.align")
local stack_class = require("wibox.layout.stack")

local clay = {}

--- The straight-alpha components of a solid color pattern, or nil for a
-- gradient, a surface pattern, or no color at all. A Clay color is one flat
-- fill; anything else has to keep painting itself.
local function solid_rgba(col)
    if not col then
        return nil
    end

    local pattern = gcolor(col)

    if pattern:get_type() ~= "SOLID" then
        return nil
    end

    local status, r, g, b, a = pattern:get_rgba()

    if status ~= "SUCCESS" then
        return nil
    end

    return { r, g, b, a }
end

--- Clay pads, gaps and border widths are whole uint16 pixels
-- (clay.h:330-335 padding, 344 childGap, 533-541 border widths).
local function whole(v)
    return type(v) == "number" and v >= 0 and v <= 65535 and v % 1 == 0
end

--- Properties every widget carries that a converted node cannot express:
-- `visible` and `opacity` are applied by `wibox.hierarchy`, which a converted
-- node no longer passes through. Each keeps the widget drawing itself.
local function common_convertible(w)
    local p = w._private

    return p.visible ~= false and (p.opacity == nil or p.opacity == 1)
end

--- The corner radius a shape function stands for, or nil for one Clay cannot
-- name. A shape is an arbitrary painter, so identity against the two shapes
-- that are rectangles is the whole test; `rounded_bar` and the rest keep
-- drawing themselves.
local function shape_radius(shape, args)
    if shape == nil or shape == gshape.rectangle then
        return 0
    end
    if shape == gshape.rounded_rect then
        local r = args and args[1] or 10

        return (type(r) == "number" and r >= 0) and r or nil
    end
    return nil
end

--- The spec for a container's only child: the whole padded box, which is
-- what `margin:layout` and `background:layout` place it at.
local function whole_box(widget)
    return widget and { { widget = widget, w = "grow", h = "grow" } } or {}
end

--- wibox.container.margin -> Clay padding, and the margin color -> a Clay
-- border of the same widths, which covers exactly the ring `margin:draw`
-- fills with the even-odd rule.
local function describe_margin(w)
    local p = w._private

    if w.layout ~= margin_class.layout or w.draw ~= margin_class.draw then
        return nil
    end
    -- draw_empty=false makes an empty margin no size at all, where Clay's
    -- fit wraps the padding.
    if p.draw_empty == false then
        return nil
    end

    local pad = { p.left or 0, p.right or 0, p.top or 0, p.bottom or 0 }

    for _, v in ipairs(pad) do
        if not whole(v) then
            return nil
        end
    end

    local node = { pad = pad, specs = whole_box(p.widget) }

    if p.color then
        local rgba = solid_rgba(p.color)

        if not rgba then
            return nil
        end
        node.border, node.bw = rgba, pad
    end

    return node
end

--- wibox.container.background -> a rectangle color, a corner radius and a
-- border.
--
-- Clay draws a border inside the element box without moving its children,
-- which is what `border_strategy = "none"` does; "inner" adds the padding
-- that shrinks them.
local function describe_background(w)
    local p = w._private

    if w.layout ~= background_class.layout
            or w.before_draw_children ~= background_class.before_draw_children
            or w.after_draw_children ~= background_class.after_draw_children then
        return nil
    end
    -- A background image is a painter over the whole box, with no Clay
    -- equivalent short of rastering it, which is what a leaf does.
    if p.bgimage then
        return nil
    end

    local bw = p.shape_border_width or 0

    if not whole(bw) then
        return nil
    end

    local radius = shape_radius(p.shape, p.shape_args)

    if not radius then
        return nil
    end
    -- A rounded shape and a border together do not draw the ring Clay draws:
    -- the cairo path is inset by the border width, so the visible outer
    -- corner is rounder than the shape names. Rather than approximate it,
    -- the container keeps drawing itself.
    if radius > 0 and bw > 0 then
        return nil
    end

    local node = { radius = radius, specs = whole_box(p.widget) }

    if p.background then
        node.bg = solid_rgba(p.background)
        if not node.bg then
            return nil
        end
    end

    if bw > 0 then
        node.border = solid_rgba(p.shape_border_color or p.foreground
            or beautiful.fg_normal)
        if not node.border then
            return nil
        end
        node.bw = { bw, bw, bw, bw }
        if p.border_strategy == "inner" then
            node.pad = { bw, bw, bw, bw }
        end
    end

    -- A background's fg is the source its children draw with, so it rides
    -- alongside the node rather than in it: a leaf takes the innermost one.
    return node, p.foreground
end

--- What wibox.layout.fixed and flex share: a layout direction and a child
-- gap, which Clay's childGap (clay.h:344) carries only when the spacing is
-- whole, not negative, and not a spacing widget, which is a widget placed
-- between the children rather than a gap.
-- Returns the node and the axis names along and across the direction, or
-- nil when the layout keeps drawing itself.
local function describe_linear(w, class)
    local p = w._private
    local spacing = p.spacing or 0

    if w.layout ~= class.layout or not whole(spacing)
            or (spacing ~= 0 and p.spacing_widget) then
        return nil
    end
    if p.dir == "y" then
        return { dir = "y", gap = spacing, specs = {} }, "h", "w"
    end
    return { dir = "x", gap = spacing, specs = {} }, "w", "h"
end

--- wibox.layout.fixed: every child at its content size along the direction,
-- which is the `:fit` the engine asked it for, and the whole size across.
-- The last child grows along too when `fill_space` is set.
--
-- Clay's childGap is added between every pair of children whatever their
-- size (clay.h:3080-3082), where the engine skipped the spacing of a child
-- whose `:fit` was zero.
local function describe_fixed(w)
    local node, along, across = describe_linear(w, fixed_class)

    if not node then
        return nil
    end

    local p = w._private

    for i, child in ipairs(p.widgets) do
        local spec = { widget = child, [across] = "grow" }

        if i == #p.widgets and p.fill_space then
            spec[along] = "grow"
        end
        node.specs[i] = spec
    end
    return node
end

--- wibox.layout.flex: every child grows along the direction, with
-- `max_widget_size` as the ceiling, and across. Clay grows the smallest
-- children first until they are all equal and then all together
-- (clay.h:2357-2391), so children of one size share the space evenly; the
-- engine gives every child the same share whatever its content, so a child
-- whose converted content is wider than its share keeps that width here and
-- takes it from the others.
local function describe_flex(w)
    local node, along = describe_linear(w, flex_class)

    if not node then
        return nil
    end

    local p = w._private

    for i, child in ipairs(p.widgets) do
        node.specs[i] = { widget = child, w = "grow", h = "grow",
            [along .. "max"] = p.max_widget_size }
    end
    return node
end

--- wibox.layout.align -> three children along the direction, sized as the
-- `expand` mode says: fit for the slots the engine asked `:fit`, grow for
-- the ones it gave what was left. Empty elements stand in where the engine
-- leaves space: a grow spacer where a missing second widget would have
-- been, and in "none" mode a grow wrapper around each outer widget, aligned
-- to its edge, so the second centers in the whole width as the engine
-- centers it.
--
-- A slot that grows starts at the size of what it holds and is only ever
-- given more (clay.h:1815-1827 sums a child's content, 2357-2391 grows),
-- and the compress pass will not take it below that content
-- (clay.h:2334-2338). So a grown slot whose own subtree converted keeps a
-- content width larger than the share the engine would have given it, and
-- takes that width from the slots beside it.
local function describe_align(w)
    local p = w._private

    if w.layout ~= align_class.layout then
        return nil
    end

    local along, across = "w", "h"

    if p.dir == "y" then
        along, across = "h", "w"
    end

    local function slot(widget, sizing)
        return { widget = widget, [along] = sizing, [across] = "grow" }
    end

    local specs = {}
    local node = { dir = p.dir, specs = specs }

    -- "outside" with no second widget gives both outer widgets the whole
    -- length, one over the other, which two elements in a row cannot say.
    if p.expand == "outside" and not p.second then
        if p.first or p.third then
            return nil
        end
        return node
    end

    if p.expand == "inside" or not p.second then
        -- The outer widgets at their fit; the second grows between. With
        -- no second widget the third still sits at the far edge.
        if p.first then
            specs[#specs + 1] = slot(p.first, "fit")
        end
        if p.second then
            specs[#specs + 1] = slot(p.second, "grow")
        elseif p.third then
            specs[#specs + 1] = { [along] = "grow" }
        end
        if p.third then
            specs[#specs + 1] = slot(p.third, "fit")
        end
        return node
    end

    if p.expand == "outside" then
        -- The second at its fit; the outer widgets take what it leaves,
        -- splitting it evenly unless one of them holds converted content
        -- wider than its half. A missing one leaves its half empty.
        specs[1] = p.first and slot(p.first, "grow") or { [along] = "grow" }
        specs[2] = slot(p.second, "fit")
        specs[3] = p.third and slot(p.third, "grow") or { [along] = "grow" }
        return node
    end

    -- "none": the second at its fit, the outer widgets at theirs, each
    -- pinned to its edge of a half that grows.
    specs[1] = { [along] = "grow", [across] = "grow",
        align = { x = "left", y = "top" },
        children = { p.first and slot(p.first, "fit") } }
    specs[2] = slot(p.second, "fit")
    specs[3] = { [along] = "grow", [across] = "grow",
        align = p.dir == "y" and { x = "left", y = "bottom" }
            or { x = "right", y = "top" },
        children = { p.third and slot(p.third, "fit") } }
    return node
end

--- wibox.layout.stack -> one floating element per child, attached to the
-- stack's top left and sized to it (clay.h:2230-2234 sizes a floating root
-- with grow sizing to its parent), each drawn over the one before (equal
-- zIndex, declaration order, clay.h:2603-2615). The stack's spacing and the
-- accumulated offsets are that element's padding around the child, which is
-- how the engine shrinks each child: by twice the spacing and by the offset
-- times the child count. A negative offset would need negative padding, so
-- it keeps the stack drawing itself.
local function describe_stack(w)
    local p = w._private
    local spacing, ho, vo = p.spacing or 0, p.h_offset or 0, p.v_offset or 0

    if w.layout ~= stack_class.layout
            or not whole(spacing) or not whole(ho) or not whole(vo) then
        return nil
    end

    local n = #p.widgets
    local specs = {}

    for i, child in ipairs(p.widgets) do
        local k = i - 1

        specs[i] = {
            float = true, w = "grow", h = "grow",
            pad = { spacing + k * ho, spacing + (n - k) * ho,
                spacing + k * vo, spacing + (n - k) * vo },
            children = whole_box(child),
        }
        if p.top_only then
            break
        end
    end

    return { specs = specs }
end

--- wibox.container.place -> child alignment, with the child at its content
-- size on each axis unless `content_fill_*` makes it grow there. The place
-- itself fills the axes `fill_*` names, which is what its own `:fit`
-- answered.
local function describe_place(w)
    local p = w._private

    if w.layout ~= place_class.layout then
        return nil
    end

    local node = { specs = {},
        align = { x = p.halign or "center", y = p.valign or "center" },
        w = p.fill_horizontal and "grow" or nil,
        h = p.fill_vertical and "grow" or nil }

    if p.widget then
        node.specs[1] = { widget = p.widget,
            w = p.content_fill_horizontal and "grow" or "fit",
            h = p.content_fill_vertical and "grow" or "fit" }
    end
    return node
end

--- The classes the tree knows, by the `:fit` they share with every instance.
-- A subclass that overrides `:fit` is not in here, and one that overrides
-- `:layout` or a draw callback fails its class's own identity check, which
-- is why no describer checks `:fit` itself.
local classes = {
    [margin_class.fit] = describe_margin,
    [background_class.fit] = describe_background,
    [fixed_class.fit] = describe_fixed,
    [flex_class.fit] = describe_flex,
    [align_class.fit] = describe_align,
    [stack_class.fit] = describe_stack,
    [place_class.fit] = describe_place,
}

--- The node a widget compiles to, plus any foreground it puts in force, or
-- nil for a widget that keeps drawing itself. `node.specs` is how the widget
-- sizes its children. A forced size is the widget's own `:fit` answer,
-- whatever its class would have said.
local function describe(w)
    local describe_class = classes[w.fit]

    if not describe_class or not common_convertible(w) then
        return nil
    end

    local node, fg = describe_class(w)

    if node then
        node.w = w._private.forced_width or node.w
        node.h = w._private.forced_height or node.h
    end
    return node, fg
end

--- Classes whose instances do not carry their own name.
--
-- `wibox.layout.stack` and `wibox.layout.flex` are both built by calling
-- `wibox.layout.fixed.horizontal`, so `widget_name` is set from fixed's
-- source path and all three report the same name. Each defines its own
-- `:fit`, which is what tells them apart here and in the `classes` table
-- below.
local named_classes = {
    [stack_class.fit] = "wibox.layout.stack",
    [flex_class.fit] = "wibox.layout.flex",
}

--- The widget's class, for the `somewm-client clay tree` dump.
--
-- `gears.object.modulename` derives `widget_name` from the source path and
-- only trims it at a `lib/` directory; somewm installs its library under
-- `lua/`, so the name arrives with the path still in front of it.
local function class_name(w)
    local name = named_classes[w.fit] or w.widget_name

    if not name then
        return nil
    end
    return (name:gsub("^.*%.lua%.", ""):gsub("^[^%a]+", ""))
end

--- A raster leaf for the subtree at `widget`: the widget draws itself, with
-- `fg` as its source, at its `:fit` within the drawin. An axis it takes
-- whole grows, so Clay gives it what the drawin's layout leaves, which is
-- the bound the engine would have asked it with.
local function leaf(st, widget, parent, fg)
    local fw, fh = base.fit_widget(parent, st.context, widget,
        st.width, st.height)
    local node = { raster = true, class = class_name(widget),
        widget = widget, leaf = #st.leaves + 1,
        w = fw < st.width and math.ceil(fw) or "grow",
        h = fh < st.height and math.ceil(fh) or "grow" }

    st.leaves[node.leaf] = { widget = widget, fg = fg, node = node }
    return node
end

--- The parent's sizing for a child, over the child's own. Grow stands, and
-- a size the child gave becomes its floor (Clay_SizingMinMax.min): the
-- child fills what it is given, and a parent that wraps its content still
-- counts that size, as the engine's `:fit` counted it through a container
-- that hands its child the whole box. Fit gives way to what the child said.
local function merge_sizing(node, spec)
    for _, k in ipairs { "w", "h" } do
        if spec[k] == "grow" then
            if type(node[k]) == "number" then
                node[k .. "min"] = node[k]
            end
            node[k] = "grow"
        elseif node[k] == nil then
            node[k] = spec[k]
        end
    end
    node.wmax, node.hmax = spec.wmax, spec.hmax
end

local compile_node

--- The nodes for a list of child specs: a widget's node with the sizing its
-- parent decided, or an empty element the parent asked for, which stands for
-- no widget and is left out of the box readback.
local function compile_specs(st, specs, parent, fg)
    local nodes = {}

    for i, spec in ipairs(specs) do
        local node

        if spec.widget then
            node = compile_node(st, spec.widget, parent, fg)
            merge_sizing(node, spec)
        else
            node = spec
            node.spacer = true
            node.children = spec.children
                and compile_specs(st, spec.children, parent, fg) or nil
        end
        nodes[i] = node
    end
    return nodes
end

--- The node tree for `widget`.
function compile_node(st, widget, parent, fg)
    local node, node_fg = describe(widget)

    if not node then
        return leaf(st, widget, parent, fg)
    end

    local mark = #st.leaves
    local children = compile_specs(st, node.specs, widget, node_fg or fg)

    node.specs = nil

    -- A rounded background clips its children to its shape, and Clay clips
    -- to rectangles: a SCISSOR command carries a box and nothing else
    -- (clay.h:2806-2807). A leaf at the same box can carry the radius;
    -- anything else under a rounded corner keeps the whole widget drawing
    -- itself, so the leaves its subtree produced go too.
    if (node.radius or 0) > 0 and #children > 0 then
        if #children == 1 and children[1].raster and not node.pad then
            children[1].radius = node.radius
        else
            for i = #st.leaves, mark + 1, -1 do
                st.leaves[i] = nil
            end
            return leaf(st, widget, parent, fg)
        end
    end

    node.children = children
    node.class = class_name(widget)
    node.widget = widget
    return node
end

--- Compile a drawable's widget tree.
--
-- Returns the node tree, rooted at the drawable's own background, and the
-- raster leaves in the tree's preorder, each with the widget it draws, the
-- foreground in force and its node. Returns nil when nothing converts, which
-- leaves the drawable on the path it has always taken: painted whole.
--
-- A node is a table with any of `pad`, `bg`, `border`, `bw`, `radius`, the
-- sizing `w` and `h` (`"fit"` or absent, `"grow"`, or a fixed number) with
-- `wmin`, `hmin`, `wmax` and `hmax` as the floor and ceiling of fit and
-- grow, `dir` ("y" for top to bottom), `gap`,
-- `align` (`x` and `y`, as wibox.container.place names them), `float`
-- (attached to the parent's top left, off the flow), `raster` for a leaf
-- with `leaf` as its index, `spacer` for an element that stands for no
-- widget, `class` (the widget's `widget_name`, for the `somewm-client clay
-- tree` dump), `widget`, and `children`. The C side reads the description
-- and ignores `widget` and `leaf`, which are the drawable's.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.widget|nil root The drawable's widget.
-- @tparam table context The widget context.
-- @tparam number width The drawable's width, the bound every leaf is fit in.
-- @tparam number height The drawable's height.
-- @treturn[1] table The node tree.
-- @treturn[1] table The raster leaves, in preorder.
-- @treturn[2] nil Nothing converted.
function clay.compile(self, root, context, width, height)
    -- A background image is a painter over the whole drawable, with no Clay
    -- equivalent short of rastering it, which is what painting whole does.
    if not root or self.background_image or not classes[root.fit] then
        return nil
    end

    -- The drawable's own background becomes the outermost rectangle, so it
    -- has to be one Clay can name before anything inside it can convert.
    -- It also has to draw: the pointer over a gap between leaves lands on
    -- it, and a fully transparent rectangle is no element at all.
    local base_rgba = solid_rgba(self.background_color)

    if not base_rgba or base_rgba[4] <= 0 then
        return nil
    end

    local st = { leaves = {}, context = context, width = width, height = height }
    local node = compile_node(st, root, base.no_parent_I_know_what_I_am_doing,
        self.foreground_color)

    -- The root's class matched but its properties did not: the leaf still
    -- covers every pixel it did, so there is nothing to gain and a whole
    -- path to keep off.
    if node.raster then
        return nil
    end

    -- The widget gets the whole drawin, as the engine gave it.
    merge_sizing(node, { w = "grow", h = "grow" })
    return { bg = base_rgba, radius = 0, class = "drawable",
        children = { node } }, st.leaves
end

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
