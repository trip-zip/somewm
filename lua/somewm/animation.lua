local beautiful = require("beautiful")
local capi = {mousegrabber = mousegrabber}
local enabled = true
local animation = setmetatable({layout_duration = 0}, {
    __index = function(_, key) if key == "enabled" then return enabled end end,
    __newindex = function(self, key, value)
        if key ~= "enabled" then rawset(self, key, value); return end
        assert(type(value) == "boolean", "animation.enabled must be a boolean")
        if enabled == value then return end
        enabled = value
        if awesome and awesome._clay_dirty then awesome._clay_dirty() end
    end,
})
local seen = setmetatable({}, {__mode = "k"})
--- The duration for every trigger that has none of its own, in seconds.
-- Applies to layout too. With no duration configured, nothing animates; 0 snaps.
-- @beautiful beautiful.animation_duration
-- @tparam[opt=nil] number animation_duration

--- Tiled clients moving between slots, in seconds; 0 snaps.
-- Requiring the deprecated `somewm.layout_animation` sets 0.15.
-- @beautiful beautiful.animation_layout_duration
-- @tparam[opt=0] number animation_layout_duration

--- A client maximizing or going fullscreen, in seconds.
-- @beautiful beautiful.animation_maximize_duration
-- @tparam[opt=nil] number animation_maximize_duration

--- A client toggling floating, in seconds.
-- @beautiful beautiful.animation_floating_duration
-- @tparam[opt=nil] number animation_floating_duration

--- A client mapping, in seconds; needs an entrance from
-- `animation_appear` or `c.animation.appear`.
-- @beautiful beautiful.animation_appear_duration
-- @tparam[opt=nil] number animation_appear_duration

--- A client closing, in seconds; needs an entrance from
-- `animation_disappear` or `c.animation.disappear`.
-- @beautiful beautiful.animation_disappear_duration
-- @tparam[opt=nil] number animation_disappear_duration

--- A tag switch, in seconds. Clients grow in and out unless
-- `c.animation.tag` or `animation_tag` names another entrance.
-- @beautiful beautiful.animation_tag_duration
-- @tparam[opt=nil] number animation_tag_duration

--- The border colour easing on a focus change, in seconds.
-- @beautiful beautiful.animation_focus_duration
-- @tparam[opt=nil] number animation_focus_duration

--- The entrance every client maps with: `grow`, `scale`, `scale_top`,
-- `scale_bottom`, `scale_left`, `scale_right`, `slide_left`, `slide_right`,
-- `slide_up`, `slide_down` or `fade`. A list combines effects simultaneously,
-- with at most one slide, one size effect (`grow` or a scale word) and `fade`.
-- @beautiful beautiful.animation_appear
-- @tparam[opt=nil] string|table animation_appear

--- The exit every client closes with, same words as `animation_appear`.
-- @beautiful beautiful.animation_disappear
-- @tparam[opt=nil] string|table animation_disappear

--- The entrance and exit on a tag switch, same words as `animation_appear`.
-- Defaults to `grow`; `c.animation.tag` can override it.
-- @beautiful beautiful.animation_tag
-- @tparam[opt="grow"] string|table animation_tag

local theme_keys = {
    layout = "animation_layout_duration",
    maximize = "animation_maximize_duration",
    floating = "animation_floating_duration",
    focus = "animation_focus_duration",
    appear = "animation_appear_duration",
    disappear = "animation_disappear_duration",
    tag = "animation_tag_duration",
}

local function object_field(object) return object.animation end

local function one_shot(_object, trigger, policy)
    return policy and policy.once and policy.once[trigger]
end
local function ancestor_off(_object, policy)
    if policy and policy.off then return 0 end
end

function animation.duration(object, trigger, policy)
    local field = policy and policy.field or object_field(object)
    if policy and policy.field == false then field = false end
    local duration = one_shot(object, trigger, policy)
    if duration == nil then
        if field == false then duration = 0
        elseif type(field) == "table" then duration = field[trigger] end
    end
    if type(duration) ~= "number" then duration = ancestor_off(object, policy) end
    if type(duration) ~= "number" then duration = beautiful[theme_keys[trigger] or "animation_" .. trigger .. "_duration"] end
    if type(duration) ~= "number" then duration = beautiful.animation_duration end
    if type(duration) == "number" then return duration end
    return trigger == "layout" and animation.layout_duration or 0
end

local entrances = setmetatable({}, {__mode = "k"})

local function entrance_value(object, name)
    local field = object_field(object)
    if field == false then return nil end
    local value
    if type(field) == "table" then value = field[name] end
    if value == false then return nil end
    if type(value) == "string" or type(value) == "table" then return value end
    value = beautiful["animation_" .. name]
    return (type(value) == "string" or type(value) == "table") and value or name == "tag" and "grow" or nil
end

local function entrance(object, name)
    local value = entrance_value(object, name)
    if type(value) ~= "table" then return value end
    local cached = entrances[object] or {}
    entrances[object] = cached
    local previous = cached[name]
    local same = previous ~= nil
    for key, word in pairs(value) do same = same and previous[key] == word end
    for key, word in pairs(previous or {}) do same = same and value[key] == word end
    if not same then
        previous = {}
        for key, word in pairs(value) do previous[key] = word end
        cached[name] = previous
    end
    return previous
end

function animation.has_effect(value, effect)
    if type(value) ~= "table" then value = {value} end
    if value[1] == "none" then return effect == "none" end
    local slide, size
    for _, word in ipairs(value) do
        if word == "collapse" then word = "grow" end
        if word == "slide_left" or word == "slide_right" or word == "slide_up" or word == "slide_down" then
            slide = slide or word
            if slide ~= word then word = nil end
        end
        if word == "grow" or word == "scale" or word == "scale_top" or word == "scale_bottom"
            or word == "scale_left" or word == "scale_right" then
            size = size or word
            if size ~= word then word = nil end
        end
        if word ~= "none" and word == effect then return true end
    end
    return false
end

function animation.word(object, trigger)
    local configured = object_field(object) ~= nil or animation.layout_duration > 0
        or type(beautiful.animation_duration) == "number"
        or entrance(object, "appear") ~= nil or entrance(object, "disappear") ~= nil
    for _, key in pairs(theme_keys) do
        configured = configured or type(beautiful[key]) == "number"
    end
    if not configured and not seen[object] then return nil end
    local duration, enter, arriving = 0, nil, false
    for _, name in ipairs(type(trigger) == "table" and trigger or {trigger}) do
        -- One element has one duration, so simultaneous box and border changes use the larger.
        duration = math.max(duration, animation.duration(object, name))
        if name == "appear" or name == "tag" then
            arriving, enter = true, entrance(object, name)
        end
    end
    -- Installing a transition on an existing node starts from an empty box.
    -- Only an authored entrance may animate the first declaration.
    if (arriving and not enter) or (not seen[object] and not enter) or not animation.enabled or capi.mousegrabber.isrunning() then
        duration = 0
    end
    seen[object] = true
    local word = {properties = (animation.duration(object, "focus") > 0)
        and {"box", "border_color"} or "box", duration = duration}
    if enter then word.enter = enter end
    local exit = entrance(object, "disappear")
    if exit then word.exit, word.exit_duration = exit, animation.duration(object, "disappear") end
    if animation.duration(object, "tag") > 0 then
        word.tag_exit, word.tag_duration = entrance(object, "tag"), animation.duration(object, "tag")
    end
    if not animation.enabled or capi.mousegrabber.isrunning() then
        if word.exit then word.exit_duration = 0 end
        if word.tag_exit then word.tag_duration = 0 end
    end
    return word
end

local widget_seen = setmetatable({}, {__mode = "k"})

function animation.widget_word(object, mapping, policy)
    local properties, values, duration, configured = {}, {}, 0, false
    for property, word in pairs(mapping) do
        local field = policy.field
        local chosen = policy.once and policy.once[property]
        if chosen == nil and type(field) == "table" then chosen = field[property] end
        local named = chosen ~= nil and chosen ~= false
        configured = configured or named
        if named then
            properties[#properties + 1] = word
            values[property] = {object[property]}
            duration = math.max(duration, animation.duration(object, property, policy))
        end
    end
    local keys = {}
    for property in pairs(mapping) do keys[#keys + 1] = property end
    table.sort(keys)
    local key = table.concat(keys, ",")
    local states = widget_seen[policy.item] or {}
    widget_seen[policy.item] = states
    local previous = states[key]
    if not configured and (not previous or not previous.configured) then
        states[key] = {configured = false}
        return nil
    end
    if #properties == 0 then
        properties, values = previous.properties, previous.values
        duration = previous.duration
        for property, value in pairs(values) do
            if object[property] ~= value[1] then duration = 0 end
        end
    end
    if not previous or policy.off or not animation.enabled or capi.mousegrabber.isrunning() then duration = 0 end
    local word = {properties = properties, duration = duration}
    states[key] = {properties = properties, values = values, duration = duration, configured = true}
    return word
end

return animation
