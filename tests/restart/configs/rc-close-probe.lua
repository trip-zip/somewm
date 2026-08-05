-- tests/rc.lua plus a finalizer that can only run if the state is closed.
--
-- GC is stopped on the old state for the whole reload, and this userdata is
-- reachable from _G, so nothing collects it. lua_close() runs finalizers for
-- every live userdata regardless, which makes the marker below proof that the
-- reload closed the state rather than abandoning it.

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

CLOSE_PROBE = newproxy(true)
getmetatable(CLOSE_PROBE).__gc = function()
    io.stderr:write("CLOSE_PROBE: state finalized\n")
end
