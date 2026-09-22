local assert = require("luassert")
local base = require("wibox.widget.base")

local function test_container(container)
    local w1 = base.empty_widget()

    assert.is.same({}, container:get_children())

    container:set_widget(w1)
    assert.is.same({ w1 }, container:get_children())

    container:set_widget(nil)
    assert.is.same({}, container:get_children())

    container:set_widget(w1)
    assert.is.same({ w1 }, container:get_children())

    if container.reset then
        container:reset()
        assert.is.same({}, container:get_children())
    end
end

return { test_container = test_container }
