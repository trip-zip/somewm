local focused = require("awful.screen").focused
local construct = node._box
local beautiful = require("beautiful")

local ui = {}
local animation = require("somewm.animation")
local animation_policy = require("somewm.animation_policy")
local pending = setmetatable({}, {__mode = "k"})
local mapping = {x = "x", y = "y", width = "width", height = "height",
    bg = "background", border_color = "border_color", border_width = "border_width"}

function ui._animation_policy(value)
    assert(value == nil or value == false or type(value) == "table",
        "ui.box animation must be a table or false")
    if type(value) == "table" then
        assert(getmetatable(value) == nil, "ui.box animation requires a plain table")
        for key, setting in pairs(value) do
            assert(mapping[key] or key == "visible", "ui.box animation: unknown word " .. tostring(key))
            if key == "visible" then
                assert(animation_policy.drawin {visible = setting}, "ui.box animation.visible: invalid transition")
            else
                assert(type(setting) == "number" and setting >= 0,
                    "ui.box animation." .. key .. ": invalid duration")
            end
        end
    end
    return animation_policy.copy(value)
end

function ui._animation_copy(value)
    return animation_policy.copy(value)
end

function ui._animate(box, values)
    assert(type(values) == "table" and type(values.duration) == "number"
        and values.duration >= 0,
        "animate requires a nonnegative duration")
    local once = {}
    for key, value in pairs(values) do
        if key ~= "duration" then
            box[key] = value
            once[key] = values.duration
        end
    end
    pending[box] = once
end

function ui._get_animation(box) return box.animation end
function ui._set_animation(box, value) box.animation = value end

function ui._animation_word(args)
    local box = args.box
    local once = pending[box]
    pending[box] = nil
    local word = animation.widget_word(box, mapping,
        {field = box.animation, once = once, off = args.off, item = box})
    local result = {transition = word}
    if word then
        local properties = {}
        for _, property in ipairs(word.properties) do
            if property == "x" or property == "y" then
                result[property] = true
                properties[#properties + 1] = "position"
            else
                properties[#properties + 1] = property
            end
        end
        word.properties = properties
    end
    return result
end

function ui.box(args)
    return construct(args, focused(), {fg = beautiful.fg_normal, font = beautiful.font})
end

function ui._font(name)
    local desc = beautiful.get_font(name):copy()
    if not desc:get_size_is_absolute() then
        desc:set_absolute_size(desc:get_size() * beautiful.xresources.get_dpi() / 72)
    end
    return desc:to_string()
end

function ui._image(value)
    local object, vector
    if type(value) == "string" and value:find("<svg", 1, true) then
        object = require("wibox.widget.imagebox")._load_rsvg_handle(value)
        vector = true
    else
        object = require("gears.surface").load_uncached(value)
    end
    assert(object, "ui.box image: could not load image")
    local dim = vector and object:get_dimensions() or object
    assert(dim.width > 0 and dim.height > 0, "ui.box image: empty image")
    return {object = object, native = object._native, vector = vector,
        width = dim.width, height = dim.height}
end

return ui
