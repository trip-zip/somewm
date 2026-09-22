---------------------------------------------------------------------------
-- Display percentage in a circle.
--
-- Note that this widget makes no attempts to prevent overlapping labels or
-- labels drawn outside of the widget boundaries.
--
--@DOC_wibox_widget_defaults_piechart_EXAMPLE@
-- @author Emmanuel Lepage Valle
-- @copyright 2012 Emmanuel Lepage Vallee
-- @widgetmod wibox.widget.piechart
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local base      = require( "wibox.widget.base" )
local beautiful = require( "beautiful"         )
local gtable    = require( "gears.table"       )
local pie       = require( "gears.shape"       ).pie

local clay = require("wibox.clay")

local module = {}

local piechart = {}


local function label_path(cr,angle,radius,center_x,center_y,text)
    local edge_x = center_x+(radius/2)*math.cos(angle)
    local edge_y = center_y+(radius/2)*math.sin(angle)

    cr:move_to(edge_x, edge_y)

    cr:rel_line_to(radius*math.cos(angle), radius*math.sin(angle))

    local x,y = cr:get_current_point()

    cr:rel_line_to(x > center_x and radius/2 or -radius/2, 0)

    local ext = cr:text_extents(text)

    cr:rel_move_to(
        (x>center_x and radius/2.5 or (-radius/2.5 - ext.width)),
        ext.height/2
    )

    cr:text_path(text)

    cr:arc(edge_x, edge_y,2,0,2*math.pi)
    cr:arc(x+(x>center_x and radius/2 or -radius/2),y,2,0,2*math.pi)
end

local function compute_sum(data)
    local ret = 0
    for _, entry in ipairs(data) do
        ret = ret + entry[2]
    end

    return ret
end



--- The pie chart data list.
--
-- @property data_list
-- @tparam[opt={}] table data_list
-- @tablerowtype Sorted list where each entry has a label as its
-- first value and a number as its second value.
-- @tablerowkey string 1 The label.
-- @tablerowkey number 2 The value.
-- @propemits false false

--- The pie chart data.
--
-- @property data
-- @tparam[opt={}] table data
-- @tablerowtype Key/value pair.
-- @tablerowkey string key The label.
-- @tablerowkey number value The value.
-- @propemits false false
-- @see data_list

--- The border color.
--
-- If none is set, it will use current foreground (text) color.
--
--@DOC_wibox_widget_piechart_border_color_EXAMPLE@
-- @property border_color
-- @tparam color|nil border_color
-- @propemits true false
-- @propbeautiful
-- @see gears.color

--- The pie elements border width.
--
--@DOC_wibox_widget_piechart_border_width_EXAMPLE@
-- @property border_width
-- @tparam[opt=1] number|nil border_width
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @propbeautiful

--- The pie chart colors.
--
-- If no color is set, only the border will be drawn. If less colors than
-- required are set, colors will be re-used in order.
--
-- @property colors
-- @tparam table|nil colors A table of colors, one for each elements.
-- @propertytype table List of colors (numerical keys).
-- @propemits true false
-- @propbeautiful
-- @see gears.color

--- The border color.
--
-- If none is set, it will use current foreground (text) color.
-- @beautiful beautiful.piechart_border_color
-- @param color
-- @see gears.color

--- If the pie chart has labels.
--
--@DOC_wibox_widget_piechart_label_EXAMPLE@
-- @property display_labels
-- @tparam[opt=true] boolean display_labels
-- @propemits true false

--- The pie elements border width.
--
-- @beautiful beautiful.piechart_border_width
-- @tparam[opt=1] number border_width

--- The pie chart colors.
--
-- If no color is set, only the border will be drawn. If less colors than
-- required are set, colors will be re-used in order.
-- @beautiful beautiful.piechart_colors
-- @tparam table colors A table of colors, one for each elements
-- @see gears.color

for _, prop in ipairs {"data_list", "border_color", "border_width", "colors",
    "display_labels"
  } do
    piechart["set_"..prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("property::"..prop)
        if prop == "data_list" then
            self:emit_signal("property::data")
        else
            self:emit_signal("property::"..prop, value)
        end
        self:emit_signal("widget::redraw_needed")
    end
    piechart["get_"..prop] = function(self)
        return self._private[prop] or beautiful["piechart_"..prop]
    end
end

function piechart:set_data(value)
    local list = {}
    for k, v in pairs(value) do
        table.insert(list, { k, v })
    end
    self:set_data_list(list)
end

function piechart:get_data()
    local list = {}
    for _, entry in ipairs(self:get_data_list()) do
        list[entry[1]] = entry[2]
    end
    return list
end

--- Create a new piechart.
--
-- @constructorfct wibox.widget.piechart
-- @tparam table data_list The data.

local function new(data_list)

    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    gtable.crush(ret, piechart)


    ret:set_data_list(data_list)

    return ret
end

local function describe_piechart(w, fg)
    local data = w._private.data_list
    if not data then return { w = "grow", h = "grow" } end
    local sum = compute_sum(data)
    if sum ~= sum or sum <= 0 then return { w = "grow", h = "grow" } end
    local has_label = w._private.display_labels ~= false
    local border_width = w:get_border_width() or 1
    local border_color = w:get_border_color()
    local colors = w:get_colors()
    local col_count = colors and #colors or 0
    local border = clay.solid_rgba(border_color)
    if border_color and not border then
        clay.ignore(w, "border_color", "is not solid and is transparent")
    end
    local foreground
    if has_label or (border_width > 0 and not border_color) then
        foreground = clay.solid_rgba(fg)
        if not foreground then
            clay.ignore(w, "fg", "is not solid and the labels are not drawn")
            has_label = false
        end
    end
    local stroke = border_width > 0 and (border or (not border_color and foreground)) or nil
    -- Floating GROW takes the parent box (third_party/clay.h:2224-2237),
    -- anchored to it (third_party/clay.h:2634-2636); equal zIndex roots
    -- paint in declaration order (third_party/clay.h:2603-2615).
    local node = { w = "grow", h = "grow", specs = {} }
    local specs, labels = node.specs, {}
    local start, count = 0, 0
    for _, entry in ipairs(data) do
        local k, v = entry[1], entry[2]
        local start_angle = start
        local end_angle = start + 2 * math.pi * (v / sum)
        local col = colors and colors[math.fmod(count, col_count) + 1]
        local fill = clay.solid_rgba(col)
        if col and not fill then
            clay.ignore(w, "colors", "holds a colour that is not solid, drawn transparent")
        elseif fill or stroke then
            specs[#specs + 1] = {
                float = true, w = "grow", h = "grow", fill = fill,
                stroke = stroke, stroke_width = border_width,
                shape = function(width, height)
                    local radius = (height > width and width or height) / 4
                    return clay.shape_ops(pie, width, height, 0, 0,
                        start_angle, end_angle, radius)
                end,
            }
        end
        if has_label then
            labels[#labels + 1] = { start + (end_angle - start) / 2, k }
        end
        start, count = end_angle, count + 1
    end
    for _, label in ipairs(labels) do
        local angle, text = label[1], label[2]
        specs[#specs + 1] = {
            float = true, w = "grow", h = "grow", stroke = foreground,
            -- The shape recorder starts with the cairo default line width;
            -- draw_label strokes with cairo's default after the outer restore.
            stroke_width = 2,
            shape = function(width, height)
                local radius = (height > width and width or height) / 4
                local center_x, center_y = width / 2, height / 2
                return clay.shape_ops(function(cr)
                    local edge_x = center_x + (radius / 2) * math.cos(angle)
                    local edge_y = center_y + (radius / 2) * math.sin(angle)
                    cr:move_to(edge_x, edge_y)
                    cr:rel_line_to(radius * math.cos(angle), radius * math.sin(angle))
                    local x = cr:get_current_point()
                    cr:rel_line_to(x > center_x and radius / 2 or -radius / 2, 0)
                end, width, height)
            end,
        }
        specs[#specs + 1] = {
            float = true, w = "grow", h = "grow", fill = foreground,
            shape = function(width, height)
                local radius = (height > width and width or height) / 4
                local center_x, center_y = width / 2, height / 2
                return clay.shape_ops(function(cr)
                    label_path(cr, angle, radius, center_x, center_y, text)
                end, width, height)
            end,
        }
    end
    return node
end

piechart._clay = { describe = describe_piechart }

return setmetatable(module, { __call = function(_, ...) return new(...) end })
-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
