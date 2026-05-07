---------------------------------------------------------------------------
--- Smoke test for client.content at non-unit screen scale.
---
--- Regression guard for issue #533: at scale != 1, the client buffer is at
--- physical pixel resolution while c.content must still return a Cairo
--- surface at logical client-content dimensions. The fix in
--- objects/client.c:luaA_client_get_content composites the physical buffer
--- into a logical-sized surface with cairo_scale.
---
--- Dimensions don't change with the fix - this test guards against c.content
--- crashing or returning nil at non-unit scale, not against the cropping
--- regression itself (verifying pixel content would require a controllable
--- test client rendering a known pattern).
---
--- Run: make test-one TEST=tests/test-client-content-scale.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local test_client = require("_client")
local gears  = require("gears")

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function cleanup(c_to_kill)
    if c_to_kill and c_to_kill.valid then
        c_to_kill:kill()
    end
    for _, pid in ipairs(test_client.get_spawned_pids()) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    return async.wait_for_no_clients(5)
end

runner.run_async(function()
    local s = screen[1]
    local original_scale = s.scale

    s.scale = 1.5
    async.sleep(0.2)

    test_client("content_scale_1")
    local c = async.wait_for_client("content_scale_1", 5)
    assert(c, "Client did not appear")

    async.sleep(0.3)

    local raw = c.content
    assert(raw ~= nil, "c.content must return a surface at scale " .. s.scale)

    local img = gears.surface(raw)
    assert(img, "gears.surface() must wrap the lightuserdata")

    local got_w = img:get_width()
    local got_h = img:get_height()

    local geo = c:geometry()
    local _, top    = c:titlebar_top()
    local _, right  = c:titlebar_right()
    local _, bottom = c:titlebar_bottom()
    local _, left   = c:titlebar_left()
    local expect_w  = geo.width  - left - right
    local expect_h  = geo.height - top  - bottom

    assert(got_w == expect_w,
        string.format("c.content width %d should equal logical content width %d (geo %dx%d, scale %s)",
            got_w, expect_w, geo.width, geo.height, tostring(s.scale)))
    assert(got_h == expect_h,
        string.format("c.content height %d should equal logical content height %d (geo %dx%d, scale %s)",
            got_h, expect_h, geo.width, geo.height, tostring(s.scale)))

    io.stderr:write(string.format(
        "[content-scale] PASS - scale=%s geo=%dx%d content=%dx%d\n",
        tostring(s.scale), geo.width, geo.height, got_w, got_h))

    s.scale = original_scale
    assert(cleanup(c), "Cleanup: client did not close")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
