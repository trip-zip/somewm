local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local cairo = require("lgi").cairo

if not test_client.is_available() then
    return runner.skip("no terminal available for test clients")
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
        local _, warnings = text:gsub("client: shape_bounding, shape_clip and shape_input are not read", "")
        assert(warnings == 1, "expected one client warning, got " .. warnings)
        return true
    end,
    -- A rounded rectangle is kept; any other shape is kept too and warns
    -- once naming the client when the layout pass reads it.
    function()
        local c = utils.find_client_by_class("shape_warn_once")
        local gshape = require("gears.shape")
        c.shape = gshape.rounded_rect
        assert(c.shape == gshape.rounded_rect)
        c.shape = 12
        assert(c.shape == 12)
        c.shape = gshape.circle
        c.shape = gshape.circle
        assert(c.shape == gshape.circle)
        return true
    end,
    function(count)
        local c = utils.find_client_by_class("shape_warn_once")
        assert(c.shape == require("gears.shape").circle, "the shape stays what was set")
        io.stderr:flush()
        local f = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG"))))
        local text = f:read("*a")
        f:close()
        local _, warnings = text:gsub(
            "client: shape is not a rounded rectangle, the client stays square: shape_warn_once", "")
        if warnings == 0 then
            assert(count < 20, "a shape that is not a rounded rectangle warns")
            return nil
        end
        assert(warnings == 1, "expected one shape warning, got " .. warnings)
        return true
    end,
}
