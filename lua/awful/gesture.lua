---------------------------------------------------------------------------
--- Touchpad gesture bindings for somewm.
--
-- @module awful.gesture
---------------------------------------------------------------------------

local gesture = {}

--- Direction detection threshold in pixels.
-- Swipe direction is committed once the accumulated displacement exceeds this.
-- @tfield number direction_threshold
gesture.direction_threshold = 30

-- Binding storage, keyed by gesture type
local bindings = {
    swipe = {},
    pinch = {},
    hold  = {},
}

-- Active gesture state (nil when no gesture is active)
local active = nil

-- Binding metatable
local Binding = {}
Binding.__index = Binding

--- Remove this gesture binding.
-- @method remove
function Binding:remove()
    local list = bindings[self.type]
    if not list then return end
    for i, b in ipairs(list) do
        if b == self then
            table.remove(list, i)
            return
        end
    end
end

--- Check if any binding matches type + fingers (for consume-eagerly).
-- @tparam string gtype Gesture type
-- @tparam number fingers Finger count
-- @treturn boolean True if at least one binding matches
local function has_candidates(gtype, fingers)
    local list = bindings[gtype]
    if not list then return false end
    for _, b in ipairs(list) do
        if b.fingers == fingers then
            return true
        end
    end
    return false
end

--- Find the first binding matching type + fingers + direction.
-- @tparam string gtype Gesture type
-- @tparam number fingers Finger count
-- @tparam string|nil direction Detected direction (swipe only)
-- @treturn table|nil The matched binding, or nil
local function find_binding(gtype, fingers, direction)
    local list = bindings[gtype]
    if not list then return nil end
    for _, b in ipairs(list) do
        if b.fingers == fingers then
            if gtype ~= "swipe" or b.direction == nil or b.direction == direction then
                return b
            end
        end
    end
    return nil
end

--- Build the gesture state table passed to callbacks.
-- @treturn table The gesture state
local function build_state()
    if not active then return {} end
    local s = {
        type      = active.type,
        fingers   = active.fingers,
        dx        = active.dx,
        dy        = active.dy,
        scale     = active.scale,
        rotation  = active.rotation,
        direction = active.direction,
        cancelled = active.cancelled or false,
        time      = active.time,
    }
    return s
end

--- Detect swipe direction from accumulated deltas.
-- @treturn string|nil Direction string or nil if threshold not reached
local function detect_direction(dx, dy)
    local abs_dx = math.abs(dx)
    local abs_dy = math.abs(dy)
    if math.max(abs_dx, abs_dy) < gesture.direction_threshold then
        return nil
    end
    if abs_dx >= abs_dy then
        return dx < 0 and "left" or "right"
    else
        return dy < 0 and "up" or "down"
    end
end

--- Main event handler called from C via _gesture.set_handler().
-- @tparam table event Event table from C
-- @treturn boolean True if consumed
local function handler(event)
    local etype = event.type

    -- SWIPE
    if etype == "swipe_begin" then
        local consumed = has_candidates("swipe", event.fingers)
        if consumed then
            active = {
                type = "swipe",
                fingers = event.fingers,
                dx = 0, dy = 0,
                scale = 1.0, rotation = 0.0,
                direction = nil,
                matched = nil,
                time = event.time,
            }
            -- Fire on_trigger immediately for non-direction bindings
            local b = find_binding("swipe", event.fingers, nil)
            if b and not b.direction then
                active.matched = b
                if b.on_trigger then
                    b.on_trigger(build_state())
                end
            end
        end
        return consumed

    elseif etype == "swipe_update" then
        if not active or active.type ~= "swipe" then return false end
        active.dx = active.dx + event.dx
        active.dy = active.dy + event.dy
        active.time = event.time

        -- Detect direction if not yet committed
        if not active.direction then
            active.direction = detect_direction(active.dx, active.dy)
            if active.direction and not active.matched then
                -- Try matching a direction binding now
                local b = find_binding("swipe", active.fingers, active.direction)
                if b then
                    active.matched = b
                end
            end
        end

        -- Fire on_update for matched binding
        if active.matched and active.matched.on_update then
            active.matched.on_update(build_state())
        end
        return true

    elseif etype == "swipe_end" then
        if not active or active.type ~= "swipe" then return false end
        active.cancelled = event.cancelled
        active.time = event.time

        -- For direction bindings, on_trigger fires on end (if matched and not cancelled)
        if active.matched and active.matched.direction and not event.cancelled then
            if active.matched.on_trigger then
                active.matched.on_trigger(build_state())
            end
        end

        -- Fire on_end for matched binding
        if active.matched and active.matched.on_end then
            active.matched.on_end(build_state())
        end

        active = nil
        return true

    -- PINCH
    elseif etype == "pinch_begin" then
        local consumed = has_candidates("pinch", event.fingers)
        if consumed then
            active = {
                type = "pinch",
                fingers = event.fingers,
                dx = 0, dy = 0,
                scale = 1.0, rotation = 0.0,
                direction = nil,
                matched = nil,
                time = event.time,
            }
            local b = find_binding("pinch", event.fingers)
            if b then
                active.matched = b
                if b.on_trigger then
                    b.on_trigger(build_state())
                end
            end
        end
        return consumed

    elseif etype == "pinch_update" then
        if not active or active.type ~= "pinch" then return false end
        active.dx = active.dx + event.dx
        active.dy = active.dy + event.dy
        active.scale = event.scale
        active.rotation = active.rotation + event.rotation
        active.time = event.time

        if active.matched and active.matched.on_update then
            active.matched.on_update(build_state())
        end
        return true

    elseif etype == "pinch_end" then
        if not active or active.type ~= "pinch" then return false end
        active.cancelled = event.cancelled
        active.time = event.time

        if active.matched and active.matched.on_end then
            active.matched.on_end(build_state())
        end

        active = nil
        return true

    -- HOLD
    elseif etype == "hold_begin" then
        local consumed = has_candidates("hold", event.fingers)
        if consumed then
            active = {
                type = "hold",
                fingers = event.fingers,
                dx = 0, dy = 0,
                scale = 1.0, rotation = 0.0,
                direction = nil,
                matched = nil,
                time = event.time,
            }
            local b = find_binding("hold", event.fingers)
            if b then
                active.matched = b
                if b.on_trigger then
                    b.on_trigger(build_state())
                end
            end
        end
        return consumed

    elseif etype == "hold_end" then
        if not active or active.type ~= "hold" then return false end
        active.cancelled = event.cancelled
        active.time = event.time

        if active.matched and active.matched.on_end then
            active.matched.on_end(build_state())
        end

        active = nil
        return true
    end

    return false
end

-- Register handler with C bridge
_gesture.set_handler(handler)

-- Constructor metamethod
setmetatable(gesture, {
    __call = function(_, args)
        assert(type(args) == "table", "awful.gesture: argument must be a table")
        assert(args.type == "swipe" or args.type == "pinch" or args.type == "hold",
            "awful.gesture: type must be 'swipe', 'pinch', or 'hold'")
        assert(type(args.fingers) == "number" and args.fingers >= 1,
            "awful.gesture: fingers must be a positive number")
        if args.direction then
            assert(args.type == "swipe",
                "awful.gesture: direction is only valid for swipe gestures")
            assert(args.direction == "left" or args.direction == "right"
                or args.direction == "up" or args.direction == "down",
                "awful.gesture: direction must be 'left', 'right', 'up', or 'down'")
        end

        local binding = setmetatable({
            type        = args.type,
            fingers     = args.fingers,
            direction   = args.direction,
            on_trigger  = args.on_trigger,
            on_update   = args.on_update,
            on_end      = args.on_end,
            description = args.description,
            group       = args.group,
        }, Binding)

        table.insert(bindings[args.type], binding)
        return binding
    end,
})

return gesture

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
