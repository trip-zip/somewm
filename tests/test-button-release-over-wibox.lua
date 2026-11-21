---------------------------------------------------------------------------
--- Regression test: a press delivered to a client gets its release, even
--- when the release lands on a wibox that has a release binding.
---
--- buttonpress() returned early when a drawin binding matched the release,
--- so wlroots kept the button held. A later drag never ended, and every
--- following click was swallowed, until the client was killed.
---
--- The release belongs to the client that got the press: the client's
--- button::release fires and the wibox's binding does not.
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local wibox  = require("wibox")
local utils  = require("_utils")

local CLIENT  = utils.binary_or_skip("./build-test/test-pointer-logger")
local POINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
local APP_ID  = "release_over_wibox"

if not CLIENT or not POINTER then
    return runner.skip("test helpers not built")
end

local marker = string.format("/tmp/somewm-release-%d.log", os.time() * 1000 + math.random(0, 999))
os.remove(marker)

local function buttons()
    local f = io.open(marker, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do
        local button, state = line:match("^button (%d+) (%d+)$")
        if button then out[#out + 1] = button .. " " .. state end
    end
    f:close()
    return out
end

local function pointer(...)
    local done, status, err
    awful.spawn.easy_async({ POINTER, ... }, function(_, stderr, _, code)
        done, status, err = true, code, stderr
    end)
    assert(async.wait_for_condition(function() return done end, 5, 0.01),
        "virtual pointer timed out")
    assert(status == 0, "virtual pointer failed: " .. tostring(err))
end

local spawn_pid

runner.run_async(function()
    spawn_pid = awful.spawn(string.format("%s --app-id %s --marker %s", CLIENT, APP_ID, marker))
    local c = async.wait_for_client(APP_ID, 5)
    assert(c, "pointer-logger client did not appear")
    c.floating = true
    c:geometry({ x = 100, y = 200, width = 400, height = 300 })

    local released, client_released = 0, 0
    c:connect_signal("button::release", function() client_released = client_released + 1 end)
    local box = wibox { x = 800, y = 300, width = 200, height = 100, visible = true, ontop = true }
    box:buttons { awful.button({}, 1, nil, function() released = released + 1 end) }
    async.sleep(0.2)

    -- Press on the client, release on the wibox.
    local g = c:geometry()
    local cx, cy = g.x + math.floor(g.width / 2), g.y + math.floor(g.height / 2)
    pointer("move", tostring(cx), tostring(cy), "1280", "720")
    pointer("drag", tostring(cx), tostring(cy), "900", "350", "1280", "720", "50")
    assert(async.wait_for_condition(function() return client_released == 1 end, 2),
        "the client's button::release did not fire")
    async.sleep(0.2)
    assert(released == 0, "the wibox release binding ran for a press that was the client's")
    local seen = table.concat(buttons(), ", ")
    assert(seen == "272 1, 272 0", "client should get its press and release, got: " .. seen)

    -- A later click on the client arrives as a whole.
    pointer("click", tostring(cx), tostring(cy), "1280", "720", "left")
    assert(async.wait_for_condition(function() return #buttons() == 4 end, 2),
        "second click did not reach the client: " .. table.concat(buttons(), ", "))
    seen = table.concat(buttons(), ", ")
    assert(seen == "272 1, 272 0, 272 1, 272 0", "unexpected button events: " .. seen)

    box.visible = false
    if c.valid then c:kill() end
    if spawn_pid then os.execute("kill -9 " .. spawn_pid .. " 2>/dev/null") end
    async.wait_for_no_clients(5)
    os.remove(marker)
    runner.done()
end)
