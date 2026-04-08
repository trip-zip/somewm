---------------------------------------------------------------------------
-- The `align` layout has three slots for child widgets. On its main axis, it
-- will use as much space as is available to it and distribute that to its child
-- widgets by stretching or shrinking them based on the chosen @{expand}
-- strategy.
-- On its secondary axis, the biggest child widget determines the size of the
-- layout, but smaller widgets will not be stretched to match it.
--
-- In its default configuration, the layout will give the first and third
-- widgets only the minimum space they ask for and it aligns them to the outer
-- edges. The remaining space between them is made available to the widget in
-- slot two.
--
-- This layout is most commonly used to split content into left/top, center and
-- right/bottom sections. As such, it is usually seen as the root layout in
-- @{awful.wibar}.
--
-- You may also fill just one or two of the widget slots, the @{expand} algorithm
-- will adjust accordingly.
--
--@DOC_wibox_layout_defaults_align_EXAMPLE@
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @layoutmod wibox.layout.align
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local table = table
local pairs = pairs
local type = type
local floor = math.floor
local gtable = require("gears.table")
local base = require("wibox.widget.base")
local clay_backend = require("wibox.layout._clay")
local clay_c = _somewm_clay

local align = {}

-- Calculate the layout of an align layout using Clay.
-- @param context The context in which we are drawn.
-- @param width The available width.
-- @param height The available height.
function align:layout(context, width, height)
    if not clay_c then
        return {}
    end

    local dir = self._private.dir == "y" and "column" or "row"
    local is_y = self._private.dir == "y"
    local expand = self._private.expand
    local first = self._private.first
    local second = self._private.second
    local third = self._private.third

    if not first and not second and not third then
        return {}
    end

    return clay_backend.compute(width, height, function()
        clay_c.open_container({ direction = dir })

        if expand == "inside" then
            -- first=fit, second=grow, third=fit
            if first then
                local w, h = base.fit_widget(self, context, first, width, height)
                clay_c.widget_element(first, {
                    [is_y and "height_fixed" or "width_fixed"] = is_y and h or w,
                })
            end
            if second then
                clay_c.widget_element(second, { grow = true })
            end
            if third then
                local w, h = base.fit_widget(self, context, third, width, height)
                clay_c.widget_element(third, {
                    [is_y and "height_fixed" or "width_fixed"] = is_y and h or w,
                })
            end

        elseif expand == "outside" then
            -- first=grow, second=fit, third=grow
            if first then
                clay_c.widget_element(first, { grow = true })
            end
            if second then
                local w, h = base.fit_widget(self, context, second, width, height)
                clay_c.widget_element(second, {
                    [is_y and "height_fixed" or "width_fixed"] = is_y and h or w,
                })
            end
            if third then
                clay_c.widget_element(third, { grow = true })
            end

        else -- "none": all fit, second centered via spacers
            if first then
                local w, h = base.fit_widget(self, context, first, width, height)
                clay_c.widget_element(first, {
                    [is_y and "height_fixed" or "width_fixed"] = is_y and h or w,
                })
            end
            if second then
                -- Spacer to push second to center
                clay_c.open_container({ grow = true })
                clay_c.close_container()

                local w, h = base.fit_widget(self, context, second, width, height)
                clay_c.widget_element(second, {
                    [is_y and "height_fixed" or "width_fixed"] = is_y and h or w,
                })

                -- Spacer to push third to end
                clay_c.open_container({ grow = true })
                clay_c.close_container()
            end
            if third then
                local w, h = base.fit_widget(self, context, third, width, height)
                clay_c.widget_element(third, {
                    [is_y and "height_fixed" or "width_fixed"] = is_y and h or w,
                })
            end
        end

        clay_c.close_container()
    end)
end

--- The widget in slot one.
--
-- This is the widget that is at the left/top.
--
-- @property first
-- @tparam[opt=nil] widget|nil first
-- @propertytype nil This spot will be empty. Depending on how large the second
--  widget is an and the value of `expand`, it might mean it will leave an empty
--  area.
-- @propemits true false

function align:set_first(widget)
    if self._private.first == widget then
        return
    end
    self._private.first = widget
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::first", widget)
end

--- The widget in slot two.
--
-- This is the centered one.
--
-- @property second
-- @tparam[opt=nil] widget|nil second
-- @propertytype nil When this property is `nil`, then there will be an empty
--  area.
-- @propemits true false

function align:set_second(widget)
    if self._private.second == widget then
        return
    end
    self._private.second = widget
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::second", widget)
end

--- The widget in slot three.
--
-- This is the widget that is at the right/bottom.
--
-- @property third
-- @tparam[opt=nil] widget|nil third
-- @propertytype nil This spot will be empty. Depending on how large the second
--  widget is an and the value of `expand`, it might mean it will leave an empty
--  area.
-- @propemits true false

function align:set_third(widget)
    if self._private.third == widget then
        return
    end
    self._private.third = widget
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::third", widget)
end

for _, prop in ipairs {"first", "second", "third", "expand" } do
    align["get_"..prop] = function(self)
        return self._private[prop]
    end
end

function align:get_children()
    return gtable.from_sparse {self._private.first, self._private.second, self._private.third}
end

function align:set_children(children)
    self:set_first(children[1])
    self:set_second(children[2])
    self:set_third(children[3])
end

-- Fit the align layout into the given space. The align layout will
-- ask for the sum of the sizes of its sub-widgets in its direction
-- and the largest sized sub widget in the other direction.
-- @param context The context in which we are fit.
-- @param orig_width The available width.
-- @param orig_height The available height.
function align:fit(context, orig_width, orig_height)
    local used_in_dir = 0
    local used_in_other = 0

    for _, v in pairs{self._private.first, self._private.second, self._private.third} do
        local w, h = base.fit_widget(self, context, v, orig_width, orig_height)

        local max = self._private.dir == "y" and w or h
        if max > used_in_other then
            used_in_other = max
        end

        used_in_dir = used_in_dir + (self._private.dir == "y" and h or w)
    end

    if self._private.dir == "y" then
        return used_in_other, used_in_dir
    end
    return used_in_dir, used_in_other
end

--- Set the expand mode, which determines how child widgets expand to take up
-- unused space.
--
-- Attempting to set any other value than one of those three will fall back to
-- `"inside"`.
--
-- @property expand
-- @tparam[opt="inside"] string expand How to use unused space.
-- @propertyvalue "inside" The widgets in slot one and three are set to their minimal
--   required size. The widget in slot two is then given the remaining space.
--   This is the default behaviour.
-- @propertyvalue "outside" The widget in slot two is set to its minimal required size and
--   placed in the center of the space available to the layout. The other
--   widgets are then given the remaining space on either side.
--   If the center widget requires all available space, the outer widgets are
--   not drawn at all.
-- @propertyvalue "none" All widgets are given their minimal required size or the
--   remaining space, whichever is smaller. The center widget gets priority.

function align:set_expand(mode)
    if mode == "none" or mode == "outside" then
        self._private.expand = mode
    else
        self._private.expand = "inside"
    end
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::expand", mode)
end

function align:reset()
    for _, v in pairs({ "first", "second", "third" }) do
        self[v] = nil
    end
    self:emit_signal("widget::layout_changed")
end

local function get_layout(dir, first, second, third)
    local ret = base.make_widget(nil, nil, {enable_properties = true})
    ret._private.dir = dir

    for k, v in pairs(align) do
        if type(v) == "function" then
            rawset(ret, k, v)
        end
    end

    ret:set_expand("inside")
    ret:set_first(first)
    ret:set_second(second)
    ret:set_third(third)

    -- An align layout allow set_children to have empty entries
    ret.allow_empty_widget = true

    return ret
end

--- Returns a new horizontal align layout.
--
-- The three widget slots are aligned left, center and right.
--
-- Additionally, this creates the aliases `set_left`, `set_middle` and
-- `set_right` to assign @{first}, @{second} and @{third} respectively.
-- @constructorfct wibox.layout.align.horizontal
-- @tparam[opt] widget left Widget to be put in slot one.
-- @tparam[opt] widget middle Widget to be put in slot two.
-- @tparam[opt] widget right Widget to be put in slot three.
function align.horizontal(left, middle, right)
    local ret = get_layout("x", left, middle, right)

    rawset(ret, "set_left"  , ret.set_first  )
    rawset(ret, "set_middle", ret.set_second )
    rawset(ret, "set_right" , ret.set_third  )

    return ret
end

--- Returns a new vertical align layout.
--
-- The three widget slots are aligned top, center and bottom.
--
-- Additionally, this creates the aliases `set_top`, `set_middle` and
-- `set_bottom` to assign @{first}, @{second} and @{third} respectively.
-- @constructorfct wibox.layout.align.vertical
-- @tparam[opt] widget top Widget to be put in slot one.
-- @tparam[opt] widget middle Widget to be put in slot two.
-- @tparam[opt] widget bottom Widget to be put in slot three.
function align.vertical(top, middle, bottom)
    local ret = get_layout("y", top, middle, bottom)

    rawset(ret, "set_top"   , ret.set_first  )
    rawset(ret, "set_middle", ret.set_second )
    rawset(ret, "set_bottom", ret.set_third  )

    return ret
end

--@DOC_fixed_COMMON@

return align

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
