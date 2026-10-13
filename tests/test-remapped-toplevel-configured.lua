local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")

local pid, previous
local remaps = 0

local steps = {
    function(count)
        if count == 1 then
            pid = awful.spawn("./build-test/test-csd-state-client")
        end
        previous = utils.find_client_by_class("csd_test")
        if previous then return true end
    end,
}

for _ = 1, 3 do
    steps[#steps + 1] = function(count)
        if count == 1 then
            awesome.kill(pid, 14)
        end
        local current = utils.find_client_by_class("csd_test")
        if not current or current == previous then return end
        assert(not previous.valid, "unmapped client must be invalid")
        assert(current.valid, "remapped client must be valid")
        assert(#client.get() == 1, "remap must leave exactly one client")
        local geo = current:geometry()
        assert(geo.width > 0 and geo.height > 0, "configured client must have geometry")
        previous = current
        remaps = remaps + 1
        return true
    end
end

steps[#steps + 1] = function(count)
    assert(remaps == 3, "all remaps must receive a configure and map")
    if count == 1 then awesome.kill(pid, 15) end
    if #client.get() == 0 then
        assert(not previous.valid, "destroyed client must be invalid")
        return true
    end
end

runner.run_steps(steps, { kill_clients = false })
