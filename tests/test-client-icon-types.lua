local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")
local surface = require("gears.surface")
local cairo = require("lgi").cairo

local function pixels(image)
    local width, height = image:get_width(), image:get_height()
    local copy = cairo.ImageSurface.create(cairo.Format.ARGB32, width, height)
    local cr = cairo.Context(copy)
    cr:set_source_surface(image, 0, 0)
    cr:paint()
    local path = os.tmpname()
    copy:write_to_png(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    assert(os.remove(path))
    return data
end

assert(test_client.is_available(), "no terminal available for test clients")

local image = surface.load_uncached(
    "tests/xdg/icons/hicolor/16x16/apps/somewm-test-app-icon.png")
local managed, accepted, rejection
local function manage(c)
    if c.class ~= "icon_types_test" then return end
    accepted, rejection = pcall(function() c.icon = image end)
    if not accepted then
        c.icon = image._native
    end
    managed = c
end

client.connect_signal("request::manage", manage)

runner.run_async(function()
    test_client("icon_types_test")
    local c = async.wait_for_client("icon_types_test", 5)
    client.disconnect_signal("request::manage", manage)
    assert(c and managed == c, "request::manage did not receive the client")
    assert(accepted == false, "LGI surface assignment must raise a Lua error")
    assert(rejection:find("client.icon", 1, true), rejection)
    assert(rejection:find("light userdata", 1, true), rejection)
    assert(rejection:find("userdata", 1, true), rejection)

    local width, height = image:get_width(), image:get_height()
    local expected = pixels(image)
    local function check_icon()
        assert(c.icon, "native surface assignment did not produce an icon")
        local icon = surface.load_uncached(c.icon)
        assert(icon:get_width() == width and icon:get_height() == height)
        assert(pixels(icon) == expected,
            "icon pixels differ from the assigned surface")
    end
    check_icon()

    local userdata = assert(io.tmpfile())
    for _, value in ipairs({ image, userdata, {}, 42, true, "icon",
            function() end }) do
        local ok, err = pcall(function() c.icon = value end)
        assert(not ok, "invalid icon assignment must raise a Lua error")
        assert(err:find("got " .. type(value), 1, true), err)
        check_icon()
    end
    userdata:close()

    c.icon = nil
    assert(c.icon == nil, "nil must clear the icon")
    runner.done()
end)
