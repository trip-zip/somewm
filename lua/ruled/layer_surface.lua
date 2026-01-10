---------------------------------------------------------------------------
--- Apply properties to layer surfaces based on rules.
--
-- This module applies rules to layer shell surfaces (panels, launchers, etc.)
-- when they are created, similar to how ruled.client works for clients.
--
-- Example usage:
--
--    ruled.layer_surface.append_rule {
--        rule = { namespace = "waybar" },
--        properties = {
--            has_keyboard_focus = false,  -- Don't auto-grant keyboard focus
--        },
--    }
--
--    ruled.layer_surface.append_rule {
--        rule = { namespace = "rofi", layer = "top" },
--        properties = {
--            has_keyboard_focus = true,
--        },
--        callback = function(l)
--            -- Custom handling for rofi
--        end,
--    }
--
-- Matching properties available:
--   namespace, layer, keyboard_interactive, screen, pid, focusable
--
-- @author SomeWM
-- @copyright 2026 SomeWM
-- @ruleslib ruled.layer_surface
---------------------------------------------------------------------------

local capi = { layer_surface = layer_surface }
local gmatcher = require("gears.matcher")
local gtable = require("gears.table")
local protected_call = require("gears.protected_call")

local module = {}

-- The matcher instance for layer surface rules
local lrules = gmatcher()

--- Check if a layer surface matches a rule.
-- @tparam layer_surface l The layer surface.
-- @tparam table rule The rule to check.
-- @treturn bool True if it matches, false otherwise.
-- @staticfct ruled.layer_surface.match
function module.match(l, rule)
    return lrules:_match(l, rule)
end

--- Check if a layer surface matches any part of a rule.
-- @tparam layer_surface l The layer surface.
-- @tparam table rule The rule to check.
-- @treturn bool True if at least one rule is matched, false otherwise.
-- @staticfct ruled.layer_surface.match_any
function module.match_any(l, rule)
    return lrules:_match_any(l, rule)
end

--- Does a given rule entry match a layer surface?
-- @tparam layer_surface l The layer surface.
-- @tparam table entry Rule entry (with keys `rule`, `rule_any`, `except` and/or
--   `except_any`).
-- @treturn bool
-- @staticfct ruled.layer_surface.matches
function module.matches(l, entry)
    return lrules:matches_rule(l, entry)
end

--- Get list of matching rules for a layer surface.
-- @tparam layer_surface l The layer surface.
-- @tparam table rules The rules to check.
-- @treturn table The list of matched rules.
-- @staticfct ruled.layer_surface.matching_rules
function module.matching_rules(l, rules)
    return lrules:matching_rules(l, rules)
end

--- Apply ruled.layer_surface.rules to a layer surface.
-- @tparam layer_surface l The layer surface.
-- @noreturn
-- @staticfct ruled.layer_surface.apply
function module.apply(l)
    lrules:apply(l)
end

--- Add a new rule to the default set.
-- @tparam table rule A valid rule.
-- @staticfct ruled.layer_surface.append_rule
function module.append_rule(rule)
    lrules:append_rule("ruled.layer_surface", rule)
end

--- Add new rules to the default set.
-- @tparam table rules A table with rules.
-- @staticfct ruled.layer_surface.append_rules
function module.append_rules(rules)
    lrules:append_rules("ruled.layer_surface", rules)
end

--- Remove a rule from the default set by its id.
-- @tparam string id The rule id.
-- @treturn boolean If the rule was removed.
-- @staticfct ruled.layer_surface.remove_rule
function module.remove_rule(id)
    return lrules:remove_rule("ruled.layer_surface", id)
end

-- Add the default rule source that applies properties
lrules:add_matching_rules("ruled.layer_surface", {}, {}, {
    -- Apply properties from matching rules
    properties = function(l, props)
        for property, value in pairs(props) do
            if type(value) == "function" then
                value = value(l)
            end
            if value ~= nil then
                l[property] = value
            end
        end
    end,
    -- Execute callbacks from matching rules
    callback = function(l, callbacks)
        for _, callback in ipairs(callbacks) do
            protected_call(callback, l)
        end
    end,
})

-- Connect to layer_surface request::manage to apply rules
if capi.layer_surface then
    capi.layer_surface.connect_signal("request::manage", function(l)
        module.apply(l)
    end)
end

return module
