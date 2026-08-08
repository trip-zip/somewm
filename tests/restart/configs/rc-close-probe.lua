-- tests/rc.lua plus a finalizer that can only run if the state is closed.
--
-- GC is stopped on the old state for the whole reload, and this probe is
-- reachable from _G, so nothing collects it. lua_close() runs finalizers
-- regardless, which makes the marker below proof that the reload closed the
-- state rather than abandoning it.

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

local function on_finalize()
    io.stderr:write("CLOSE_PROBE: state finalized\n")
end

-- Each interpreter needs its own mechanism, the way gears.object already splits
-- them. LuaJIT never finalizes a table, so the probe has to be a userdata. Lua
-- 5.2 and later dropped newproxy and only mark an object for finalization if
-- __gc is already in the metatable that setmetatable receives: assigning it
-- afterwards leaves the object unfinalized and this test silently vacuous.
if _VERSION <= "Lua 5.1" then
    -- luacheck: globals newproxy
    CLOSE_PROBE = newproxy(true)
    getmetatable(CLOSE_PROBE).__gc = on_finalize
else
    CLOSE_PROBE = setmetatable({}, { __gc = on_finalize })
end
