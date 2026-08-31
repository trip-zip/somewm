---------------------------------------------------------------------------
--- Compile a drawable's widget tree into Clay declarations.
--
-- The declare pass (declare.c) draws a drawin as one image leaf holding the
-- whole drawable surface. This module peels containers off the front of that
-- leaf: walking down from the root, every widget whose class and properties
-- map onto a Clay declaration becomes one, and the first widget that does not
-- stops the walk. Whatever is left rasters into the same drawable surface it
-- always did and rides as the leaf, now declared inside the converted chain
-- instead of alone.
--
-- The walk descends the drawable's `wibox.hierarchy`, which is the structure
-- that will draw the leaf, so the chain can never name a widget the drawing
-- does not reach. It reads no box from it: a node is pure description, Clay
-- solves the chain, and `compile` only says what the chain is.
--
-- @module wibox.clay
---------------------------------------------------------------------------

local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local margin_class = require("wibox.container.margin")
local background_class = require("wibox.container.background")

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

--- Clay pads and border widths are whole uint16 pixels.
local function whole(v)
    return type(v) == "number" and v >= 0 and v <= 65535 and v % 1 == 0
end

local function padded(node)
    local pad = node.pad

    return pad ~= nil
        and (pad[1] > 0 or pad[2] > 0 or pad[3] > 0 or pad[4] > 0)
end

--- Properties every widget carries that a converted node cannot express.
--
-- `visible` and `opacity` are applied by `wibox.hierarchy`, which a converted
-- node no longer passes through, and a forced size is a `:fit` answer, which
-- a chain of grow-sized elements never asks for. Each stops the walk, so the
-- widget keeps drawing itself.
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
    -- fits to. The chain grows instead of fitting, so it has no answer.
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
    -- equivalent short of rastering it, which is what the leaf already does.
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
    -- alongside the node rather than in it: the leaf takes the innermost one.
    return node, p.foreground
end

--- Whether a widget is one of the classes the chain knows at all. Cheap, and
-- separate from `describe` so a tree that can never convert costs two table
-- lookups rather than a walk.
local function convertible_class(w)
    return w.fit == margin_class.fit or w.fit == background_class.fit
end

--- The node a widget compiles to, plus any foreground it puts in force, or
-- nil for a widget that keeps drawing itself.
local function describe(w)
    if not common_convertible(w) then
        return nil
    end
    if w.fit == margin_class.fit then
        return describe_margin(w)
    end
    return describe_background(w)
end

--- Compile the front of a drawable's laid-out widget tree.
--
-- Returns the node chain outermost first, always ending in the raster leaf,
-- plus the hierarchy the leaf draws (nil when the chain consumed the whole
-- tree), that hierarchy's parent, and the foreground in force where the leaf
-- starts. Returns nil when nothing converts, which leaves the drawable on the
-- path it has always taken: one leaf, painted whole.
--
-- A node is a table with any of `pad`, `bg`, `border`, `bw`, `radius`; the
-- last one is `{ raster = true }`, the leaf.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.hierarchy|nil root The drawable's laid-out widget tree.
-- @treturn[1] table The node chain.
-- @treturn[1] wibox.hierarchy The hierarchy the raster leaf draws.
-- @treturn[1] wibox.hierarchy The leaf's parent, whose transform places it.
-- @treturn[1] cairo.Pattern The foreground in force at the leaf.
-- @treturn[2] nil Nothing converted.
function clay.compile(self, root)
    -- A background image is a painter over the whole drawable, with no Clay
    -- equivalent short of rastering it, which is what the leaf already does.
    if not root or self.background_image
            or not convertible_class(root:get_widget()) then
        return nil
    end

    -- The drawable's own background becomes the outermost rectangle, so it
    -- has to be one Clay can name before anything inside it can convert.
    local base = solid_rgba(self.background_color)

    if not base then
        return nil
    end

    local chain, h, parent = { { bg = base, radius = 0 } }, root, nil
    local fg = self.foreground_color
    -- A rounded background clips its children to its shape. The leaf carries
    -- that radius instead, which is the same clip only while the leaf's box
    -- is the rounded element's box, so padding on either side of one ends the
    -- walk.
    local radius, padding = 0, false

    while h do
        local node, node_fg = describe(h:get_widget())

        if not node then
            break
        end
        if (radius > 0 and padded(node))
                or ((node.radius or 0) > 0 and padding) then
            break
        end

        padding = padding or padded(node)
        radius = math.max(radius, node.radius or 0)
        fg = node_fg or fg
        chain[#chain + 1] = node
        parent, h = h, h:get_children()[1]
    end

    -- The root's class matched but its properties did not: the leaf still
    -- covers every pixel it did, so there is nothing to gain and a whole
    -- path to keep off.
    if #chain == 1 then
        return nil
    end

    chain[#chain + 1] = { raster = true, radius = radius }

    return chain, h, parent, fg
end

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
