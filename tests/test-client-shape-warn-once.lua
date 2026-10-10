local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local cairo = require("lgi").cairo

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

runner.run_steps {
    function(count)
        if count == 1 then test_client("shape_warn_once") end
        local c = utils.find_client_by_class("shape_warn_once")
        if not c then return nil end
        local surface = cairo.ImageSurface(cairo.Format.A1, 1, 1)
        for _, name in ipairs { "shape_bounding", "shape_clip", "shape_input" } do
            c[name] = surface
            assert(c[name] == nil)
            c[name] = nil
            assert(c[name] == nil)
            assert(c["client_" .. name] == nil)
        end
        io.stderr:flush()
        local f = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG"))))
        local text = f:read("*a")
        f:close()
        local _, warnings = text:gsub("client: shape masks are not read", "")
        assert(warnings == 1, "expected one client warning, got " .. warnings)
        return true
    end,
}
