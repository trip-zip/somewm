---------------------------------------------------------------------------
-- @author somewm contributors
--
-- Test-mode keybind helper. Swaps Mod4 -> Mod1 in user-bound keys when
-- the outer Wayland compositor can't pass Mod4 combos through and the
-- user hasn't opted out via --keybinds=none|inhibit. Loaded by the C
-- startup hook only when SOMEWM_TEST_NAME is set.
---------------------------------------------------------------------------

local M = {}

-- Pure-function helper: takes a modifiers table, returns (new_table,
-- changed). Exposed for unit testing.
function M.substitute_modifiers(modifiers)
    local out = {}
    local changed = false
    for _, m in ipairs(modifiers) do
        if m == "Mod4" then
            table.insert(out, "Mod1")
            changed = true
        else
            table.insert(out, m)
        end
    end
    return out, changed
end

function M.apply()
    if not os.getenv("SOMEWM_TEST_NAME") then return end
    if os.getenv("SOMEWM_TEST_KEYBINDS_REMAP") ~= "1" then return end

    if not (root and root.keys) then return end
    local keys = root.keys()
    if not keys then return end
    local count = 0
    for _, k in ipairs(keys) do
        local mods = k.modifiers
        if mods then
            local new_mods, changed = M.substitute_modifiers(mods)
            if changed then
                k.modifiers = new_mods
                count = count + 1
            end
        end
    end
    if count > 0 then
        io.stderr:write(string.format(
            "[test_marker] remapped Mod4 -> Mod1 on %d keybinding(s) " ..
            "(outer compositor cannot forward shortcuts)\n", count))
    end
end

return M
