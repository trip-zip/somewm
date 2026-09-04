---------------------------------------------------------------------------
--- Compile a drawable's widget tree into Clay declarations.
--
-- The declare pass (declare.c) draws a drawin from the tree this module
-- returns: one Clay element per widget the compile step can express, and one
-- raster leaf per subtree it cannot, drawn by cairo into the leaf's own
-- surface (widget.c) and shown at the box Clay solves for it. When nothing
-- converts the drawable paints itself whole, as it always did.
--
-- The walk descends the drawable's `wibox.hierarchy`, which is the structure
-- that draws the leaves, so the tree can never name a widget the drawing does
-- not reach. It reads no position or size for a node from it: a node is pure
-- description, Clay solves the tree, and `compile` only says what the tree
-- is. A raster leaf is described by its preferred size, which is the `:fit`
-- answer of the widget at the top of the degraded subtree, asked with the
-- bound its parent's layout would have offered; that bound is the only box
-- the walk takes from the hierarchy, and only because the engine took the
-- same one from its own parent.
--
-- @module wibox.clay
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local gtable = require("gears.table")
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

--- Properties every widget carries that a converted node cannot express.
--
-- `visible` and `opacity` are applied by `wibox.hierarchy`, which a converted
-- node no longer passes through, and a forced size is a `:fit` answer, which
-- a node sized by its parent's rule never asks for. Each keeps the widget
-- drawing itself.
local function common_convertible(w)
    local p = w._private

    return p.visible ~= false
        and (p.opacity == nil or p.opacity == 1)
        and p.forced_width == nil
        and p.forced_height == nil
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

--- wibox.container.margin -> Clay padding, and the margin color -> a Clay
-- border of the same widths, which covers exactly the ring `margin:draw`
-- fills with the even-odd rule.
local function describe_margin(w)
    local p = w._private

    if w.layout ~= margin_class.layout or w.draw ~= margin_class.draw then
        return nil
    end
    -- draw_empty=false makes the margin's own size depend on what the child
    -- fits to, which is a :fit answer the node never gives.
    if p.draw_empty == false then
        return nil
    end

    local pad = { p.left or 0, p.right or 0, p.top or 0, p.bottom or 0 }

    for _, v in ipairs(pad) do
        if not whole(v) then
            return nil
        end
    end

    local node = { pad = pad }

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

    local node = { radius = radius }

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

--- The hierarchy children of a layout that places its widgets in order, or
-- nil when they are not the first widgets of the list: a layout that stopped
-- early still matches, one whose `:layout` is not the class's own does not.
local function children_in_order(hier, widgets)
    local children = hier:get_children()

    for i, child in ipairs(children) do
        if child:get_widget() ~= widgets[i] then
            return nil
        end
    end
    return children
end

--- What wibox.layout.fixed and flex share: a layout direction and a child
-- gap, which Clay's childGap (clay.h:344) carries only when the spacing is
-- whole, not negative, and not a spacing widget, which is a widget placed
-- between the children rather than a gap.
-- Returns the node, the placed children and whether the direction is
-- vertical, or nil when the layout keeps drawing itself.
local function describe_linear(w, hier, class)
    local p = w._private
    local spacing = p.spacing or 0

    if w.layout ~= class.layout or not whole(spacing)
            or (spacing ~= 0 and p.spacing_widget) then
        return nil
    end

    local children = children_in_order(hier, p.widgets)

    if not children then
        return nil
    end
    return { dir = p.dir, gap = spacing, specs = {} }, children, p.dir == "y"
end

--- wibox.layout.fixed: every child fixed at its `:fit` along the direction,
-- asked with the space left after the children and gaps before it, and
-- growing across. The last child grows along too when `fill_space` is set.
--
-- A child whose `:fit` is zero along the direction is left out: the engine
-- places it at zero size and skips its spacing, and Clay's childGap is
-- added between every pair of children whatever their size
-- (clay.h:3080-3082). The engine also stops placing children once one
-- starts past the edge; those are not in the hierarchy, so they are not
-- here either.
local function describe_fixed(w, hier, ctx)
    local node, children, is_y = describe_linear(w, hier, fixed_class)

    if not node then
        return nil
    end

    local p = w._private
    local width, height = hier:get_size()
    local pos = 0

    for i, child in ipairs(children) do
        if i == #p.widgets and p.fill_space then
            node.specs[#node.specs + 1] = { hier = child }
        else
            local fw, fh = base.fit_widget(w, ctx, child:get_widget(),
                is_y and width or width - pos, is_y and height - pos or height)
            local along = is_y and fh or fw

            if along > 0 then
                node.specs[#node.specs + 1] =
                    { hier = child, [is_y and "h" or "w"] = along }
                pos = pos + along + node.gap
            end
        end
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
local function describe_flex(w, hier)
    local node, children, is_y = describe_linear(w, hier, flex_class)
    local p = w._private

    if not node or #children ~= #p.widgets then
        return nil
    end
    for i, child in ipairs(children) do
        node.specs[i] =
            { hier = child, [is_y and "hmax" or "wmax"] = p.max_widget_size }
    end
    return node
end

--- wibox.layout.align -> three children along the direction, sized as the
-- `expand` mode says. Empty elements stand in where the engine leaves space:
-- a grow spacer where a missing second widget would have been, and in
-- "none" mode a grow wrapper around each outer widget, aligned to its edge,
-- so the second centers in the whole width as the engine centers it.
--
-- A slot that grows starts at the size of what it holds and is only ever
-- given more (clay.h:1815-1827 sums a child's content, 2357-2391 grows),
-- and the compress pass will not take it below that content
-- (clay.h:2334-2338). So a grown slot whose own subtree converted, and
-- therefore carries fixed children, keeps a content width larger than the
-- share the engine would have given it, and takes that width from the
-- slots beside it. A slot holding a raster leaf has no content of its own
-- and takes exactly its share.
local function describe_align(w, hier, ctx)
    local p = w._private

    if w.layout ~= align_class.layout then
        return nil
    end

    local is_y = p.dir == "y"
    local width, height = hier:get_size()
    local total = is_y and height or width
    local along = is_y and "h" or "w"
    local slots = {}

    for _, child in ipairs(hier:get_children()) do
        local cw = child:get_widget()
        local slot = cw == p.first and "first" or cw == p.second and "second"
            or cw == p.third and "third"

        if not slot or slots[slot] then
            return nil
        end
        slots[slot] = child
    end

    local function fit_along(widget, bound)
        local fw, fh = base.fit_widget(w, ctx, widget,
            is_y and width or bound, is_y and bound or height)

        return is_y and fh or fw
    end

    local specs = {}
    local node = { dir = p.dir, specs = specs }

    -- "outside" with no second widget gives both outer widgets the whole
    -- length, one over the other, which two elements in a row cannot say.
    if p.expand == "outside" and not p.second then
        if slots.first or slots.third then
            return nil
        end
        return node
    end

    if p.expand == "inside" or not p.second then
        -- The outer widgets at their fit, the first bounded by the whole and
        -- the third by what the first left; the second grows between. With
        -- no second widget the third still sits at the far edge.
        local remains = total

        if slots.first then
            local size = fit_along(p.first, remains)

            remains = remains - size
            specs[#specs + 1] = { hier = slots.first, [along] = size }
        end
        if slots.second then
            specs[#specs + 1] = { hier = slots.second }
        elseif not p.second and slots.third then
            specs[#specs + 1] = {}
        end
        if slots.third then
            specs[#specs + 1] = { hier = slots.third,
                [along] = fit_along(p.third, remains) }
        end
        return node
    end

    -- "outside" and "none" size the second first, at its fit within the
    -- whole; a second that wants it all is placed alone at full size.
    local second = fit_along(p.second, total)

    if second >= total then
        if slots.second then
            specs[1] = { hier = slots.second }
        end
        return node
    end

    if p.expand == "outside" then
        -- The outer widgets take what the second leaves, splitting it
        -- evenly unless one of them holds converted content wider than its
        -- half; a missing one leaves its half empty.
        specs[1] = slots.first and { hier = slots.first } or {}
        specs[2] = { hier = slots.second, [along] = second }
        specs[3] = slots.third and { hier = slots.third } or {}
        return node
    end

    -- "none": the outer widgets at their fit within half of what the second
    -- leaves, each pinned to its edge of a half that grows.
    local half = math.floor((total - second) / 2)
    local first = slots.first and { hier = slots.first,
        [along] = fit_along(p.first, half) } or nil
    local third = slots.third and { hier = slots.third,
        [along] = fit_along(p.third, half) } or nil

    specs[1] = { children = { first }, align = { x = "left", y = "top" } }
    specs[2] = { hier = slots.second, [along] = second }
    specs[3] = { children = { third }, align = is_y
        and { x = "left", y = "bottom" } or { x = "right", y = "top" } }
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
local function describe_stack(w, hier)
    local p = w._private
    local spacing, ho, vo = p.spacing or 0, p.h_offset or 0, p.v_offset or 0

    if w.layout ~= stack_class.layout
            or not whole(spacing) or not whole(ho) or not whole(vo) then
        return nil
    end

    local children = children_in_order(hier, p.widgets)

    if not children then
        return nil
    end

    local n = #p.widgets
    local specs = {}

    for i, child in ipairs(children) do
        local k = i - 1

        specs[i] = {
            float = true,
            pad = { spacing + k * ho, spacing + (n - k) * ho,
                spacing + k * vo, spacing + (n - k) * vo },
            children = { { hier = child } },
        }
    end

    return { specs = specs }
end

--- wibox.container.place -> child alignment, with the child fixed at its
-- `:fit` on each axis unless `content_fill_*` makes it grow there.
-- `fill_horizontal` and `fill_vertical` only change the place's own `:fit`,
-- which is the parent's to ask.
local function describe_place(w, hier, ctx)
    local p = w._private

    if w.layout ~= place_class.layout then
        return nil
    end

    local node = { specs = {},
        align = { x = p.halign or "center", y = p.valign or "center" } }
    local children = hier:get_children()

    if #children == 0 then
        return node
    end
    if #children ~= 1 or children[1]:get_widget() ~= p.widget then
        return nil
    end

    local fw, fh = base.fit_widget(w, ctx, p.widget, hier:get_size())

    node.specs[1] = {
        hier = children[1],
        w = not p.content_fill_horizontal and fw or nil,
        h = not p.content_fill_vertical and fh or nil,
    }
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
-- nil for a widget that keeps drawing itself. `node.specs`, when set, is how
-- the widget sizes its children; a container without it gives its children
-- the whole padded box.
local function describe(w, hier, ctx)
    local describe_class = classes[w.fit]

    if not describe_class or not common_convertible(w) then
        return nil
    end
    return describe_class(w, hier, ctx)
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

--- A raster leaf for the subtree at `hier`: the widget draws itself, with
-- its parent's transform placing it and `fg` as its source.
local function leaf(st, hier, parent, fg)
    st.leaves[#st.leaves + 1] = { hierarchy = hier, parent = parent, fg = fg }
    return { raster = true, class = class_name(hier:get_widget()) }
end

local compile_node

--- The nodes for a list of child specs: a widget's node with the sizing its
-- parent decided, or an empty element the parent asked for, which stands for
-- no widget and is left out of the box readback.
local function compile_specs(st, specs, hier, fg)
    local nodes = {}

    for i, spec in ipairs(specs) do
        local node

        if spec.hier then
            node = compile_node(st, spec.hier, hier, fg)
            spec.hier = nil
            gtable.crush(node, spec)
        else
            node = spec
            node.spacer = true
            node.children = spec.children
                and compile_specs(st, spec.children, hier, fg) or nil
        end
        nodes[i] = node
    end
    return nodes
end

--- The node tree for the widget at `hier`.
function compile_node(st, hier, parent, fg)
    local node, node_fg = describe(hier:get_widget(), hier, st.context)

    if not node then
        return leaf(st, hier, parent, fg)
    end

    local specs = node.specs
    local mark, children = #st.leaves, {}

    node.specs = nil
    if specs then
        children = compile_specs(st, specs, hier, node_fg or fg)
    else
        -- A container with no sizing rule of its own gives every child the
        -- whole padded box, which is what a node grows into by default.
        for i, child in ipairs(hier:get_children()) do
            children[i] = compile_node(st, child, hier, node_fg or fg)
        end
    end

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
            return leaf(st, hier, parent, fg)
        end
    end

    node.children = children
    node.class = class_name(hier:get_widget())
    return node
end

--- Compile a drawable's laid-out widget tree.
--
-- Returns the node tree, rooted at the drawable's own background, and the
-- raster leaves in the tree's preorder, each with the hierarchy it draws,
-- that hierarchy's parent and the foreground in force. Returns nil when
-- nothing converts, which leaves the drawable on the path it has always
-- taken: painted whole.
--
-- A node is a table with any of `pad`, `bg`, `border`, `bw`, `radius`, the
-- sizing `w` and `h` (a fixed number, else the node grows) with `wmax` and
-- `hmax` as grow ceilings, `dir` ("y" for top to bottom), `gap`, `align`
-- (`x` and `y`, as wibox.container.place names them), `float` (attached to
-- the parent's top left, off the flow), `raster` for a leaf, `spacer` for an
-- element that stands for no widget, `class` (the widget's `widget_name`, for
-- the `somewm-client clay tree` dump), and `children`.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.hierarchy|nil root The drawable's laid-out widget tree.
-- @tparam table context The widget context the tree was laid out in.
-- @treturn[1] table The node tree.
-- @treturn[1] table The raster leaves, in preorder.
-- @treturn[2] nil Nothing converted.
function clay.compile(self, root, context)
    -- A background image is a painter over the whole drawable, with no Clay
    -- equivalent short of rastering it, which is what painting whole does.
    if not root or self.background_image
            or not classes[root:get_widget().fit] then
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

    local st = { leaves = {}, context = context }
    local node = compile_node(st, root, nil, self.foreground_color)

    -- The root's class matched but its properties did not: the leaf still
    -- covers every pixel it did, so there is nothing to gain and a whole
    -- path to keep off.
    if node.raster then
        return nil
    end

    return { bg = base_rgba, radius = 0, class = "drawable",
        children = { node } }, st.leaves
end

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
