local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    return runner.skip("no terminal available for test clients")
end

-- A rule's shape replaces a shape function the client already holds; the
-- held function is never called with the rule's value.
runner.run_steps {
    function(count)
        if count == 1 then test_client("ruled_shape_rule") end
        local c = utils.find_client_by_class("ruled_shape_rule")
        if not c then return nil end
        local gshape = require("gears.shape")
        c.shape = gshape.rectangle
        require("ruled.client").execute(c, { shape = gshape.rounded_rect })
        assert(c.shape == gshape.rounded_rect, "the rule's shape is set")
        io.stderr:flush()
        local f = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG"))))
        local text = f:read("*a")
        f:close()
        assert(not text:find("attempt to call method", 1, true), "the log has no method call error")
        return true
    end,
}
